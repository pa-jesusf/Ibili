import Foundation
import CryptoKit

/// Compressed image bytes on disk. A serial lazy index accounts for mutations.
/// Synchronous reads belong on the image IO queue, not the main thread.
final class ImageDiskCache: @unchecked Sendable {
    static let shared = ImageDiskCache()
    private struct Entry {
        var bytes: Int64
        var accessed: Date
        var persistedAccess: Date
    }
    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "ibili.image.disk.cache", qos: .utility)
    private let directory: URL
    private let defaults: UserDefaults
    private let maxBytesKey = "ibili.cache.imageMaxBytes"
    private var entries: [URL: Entry] = [:]
    private var total: Int64 = 0
    private var indexed = false
    private var cleanupScheduled = false
    private(set) var indexScanCount = 0

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ibili/images", isDirectory: true)
    }

    var maxBytes: Int64 {
        get { (defaults.object(forKey: maxBytesKey) as? NSNumber)?.int64Value ?? 256 * 1024 * 1024 }
        set {
            defaults.set(NSNumber(value: max(newValue, 16 * 1024 * 1024)), forKey: maxBytesKey)
            queue.async { self.loadIndex(); self.scheduleCleanup() }
        }
    }

    func read(_ url: URL) -> Data? {
        let path = filePath(for: url)
        guard let data = try? Data(contentsOf: path) else { return nil }
        queue.async {
            self.loadIndex()
            guard var entry = self.entries[path] else { return }
            let now = Date()
            entry.accessed = now
            // Keep precise in-memory LRU without an inode write for every hit.
            if now.timeIntervalSince(entry.persistedAccess) >= 300 {
                do {
                    try self.fm.setAttributes([.modificationDate: now], ofItemAtPath: path.path)
                    entry.persistedAccess = now
                } catch { }
            }
            self.entries[path] = entry
        }
        return data
    }

    func write(_ url: URL, data: Data) {
        let path = filePath(for: url)
        queue.async {
            guard data.count <= max(self.maxBytes / 8, 4 * 1024 * 1024) else { return }
            self.loadIndex()
            do {
                try self.fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: path, options: .atomic)
                self.total += Int64(data.count) - (self.entries[path]?.bytes ?? 0)
                let now = Date()
                self.entries[path] = Entry(bytes: Int64(data.count), accessed: now, persistedAccess: now)
                self.scheduleCleanup()
            } catch { return }
        }
    }

    /// Settings calls this off-main; also a barrier after queued IO.
    func currentBytes() -> Int64 {
        queue.sync { loadIndex(); return total }
    }

    func clearAll(completion: (() -> Void)? = nil) {
        queue.async {
            do {
                if self.fm.fileExists(atPath: self.directory.path) { try self.fm.removeItem(at: self.directory) }
                self.entries.removeAll()
                self.total = 0
                self.indexed = true
            } catch {
                self.indexed = false
                self.loadIndex()
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    private func filePath(for url: URL) -> URL {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(key.prefix(2)), isDirectory: true).appendingPathComponent(key)
    }

    private func loadIndex() {
        guard !indexed else { return }
        indexed = true
        indexScanCount += 1
        entries.removeAll()
        total = 0
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            let date = values.contentModificationDate ?? .distantPast
            entries[url] = Entry(bytes: bytes, accessed: date, persistedAccess: date)
            total += bytes
        }
    }

    private func scheduleCleanup() {
        guard total > maxBytes, !cleanupScheduled else { return }
        cleanupScheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) {
            self.cleanupScheduled = false
            let cap = self.maxBytes
            guard self.total > cap else { return }
            for (url, entry) in self.entries.sorted(by: { $0.value.accessed < $1.value.accessed }) {
                guard self.total > cap else { break }
                do {
                    if self.fm.fileExists(atPath: url.path) { try self.fm.removeItem(at: url) }
                    self.entries[url] = nil
                    self.total -= entry.bytes
                } catch { continue }
            }
        }
    }
}
