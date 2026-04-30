import Foundation
import CryptoKit

/// On-disk LRU cache for decoded image bytes. Sits behind the
/// in-memory `ImageCache` so cover thumbnails survive app launches
/// and free up the recommendation feed from re-fetching every time
/// the user backgrounds the app. Mirrors what `cached_network_image`
/// gives the upstream Flutter build, so cold-start scrolling feels
/// identical between the two clients.
///
/// Threading: all filesystem mutations run on a serial dispatch
/// queue. Reads are synchronous and cheap (a single `Data` load
/// from disk). Eviction runs opportunistically after each write
/// once the directory exceeds `maxBytes`.
final class ImageDiskCache: @unchecked Sendable {
    static let shared = ImageDiskCache()

    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "ibili.image.disk.cache", qos: .utility)
    private let directory: URL
    /// Default cap. Overridden at runtime by `AppSettings.imageCacheMaxMB`.
    /// 256 MB is enough for ~2k typical cover thumbnails.
    private let defaultMaxBytes: Int64 = 256 * 1024 * 1024
    private let maxBytesKey = "ibili.cache.imageMaxBytes"

    private init() {
        let caches = (try? fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = caches.appendingPathComponent("ibili/images", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var maxBytes: Int64 {
        get {
            let v = UserDefaults.standard.object(forKey: maxBytesKey) as? Int64
            return v ?? defaultMaxBytes
        }
        set {
            UserDefaults.standard.set(NSNumber(value: max(newValue, 16 * 1024 * 1024)),
                                      forKey: maxBytesKey)
            queue.async { [weak self] in self?.evictIfNeededLocked() }
        }
    }

    // MARK: - Read / write

    func read(_ url: URL) -> Data? {
        let path = filePath(for: url)
        guard fm.fileExists(atPath: path.path) else { return nil }
        // Touch the file's modification date so eviction's LRU stays
        // accurate. The actual file write hop is cheap because APFS
        // only updates the inode metadata, not the data blocks.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
        return try? Data(contentsOf: path)
    }

    func write(_ url: URL, data: Data) {
        // Bound the per-file size at 1/8 of the cap so a single huge
        // image can never displace the entire cache.
        let perFileLimit = max(maxBytes / 8, 4 * 1024 * 1024)
        guard data.count <= perFileLimit else { return }
        let path = filePath(for: url)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.fm.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: path, options: .atomic)
            } catch {
                return
            }
            self.evictIfNeededLocked()
        }
    }

    // MARK: - Bookkeeping

    /// Reports the on-disk footprint in bytes. Synchronous; callers
    /// should hop to a background queue before invoking on hot
    /// paths.
    func currentBytes() -> Int64 {
        let entries = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var total: Int64 = 0
        for url in entries {
            total += sumBytes(in: url)
        }
        return total
    }

    /// Wipe the whole cache. Used by Settings → "清除图片缓存".
    func clearAll(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { completion?(); return }
            try? self.fm.removeItem(at: self.directory)
            try? self.fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
            DispatchQueue.main.async { completion?() }
        }
    }

    // MARK: - Internals

    private func filePath(for url: URL) -> URL {
        let key = sha256Hex(url.absoluteString)
        let prefix = String(key.prefix(2))
        return directory
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(key, isDirectory: false)
    }

    private func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func sumBytes(in url: URL) -> Int64 {
        if let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
           resourceValues.isRegularFile == true {
            return Int64(resourceValues.fileSize ?? 0)
        }
        // Recurse into subdirectories.
        let children = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var total: Int64 = 0
        for child in children { total += sumBytes(in: child) }
        return total
    }

    private func evictIfNeededLocked() {
        let cap = maxBytes
        var entries: [(url: URL, size: Int64, mtime: Date)] = []
        let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard let r = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey
            ]) else { continue }
            if r.isRegularFile != true { continue }
            entries.append((url, Int64(r.fileSize ?? 0), r.contentModificationDate ?? .distantPast))
        }
        var total = entries.reduce(into: Int64(0)) { $0 += $1.size }
        if total <= cap { return }
        // Oldest first.
        entries.sort { $0.mtime < $1.mtime }
        for entry in entries {
            if total <= cap { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
