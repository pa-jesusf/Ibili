import Foundation

actor SponsorBlockRepository {
    typealias Fetch = @Sendable (SponsorVideoKey, Bool) async throws -> [SponsorSegment]
    static let shared = SponsorBlockRepository(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ibili/SponsorSegments", isDirectory: true),
        fetch: { key, force in
            try await CoreClient.shared.fetchSponsorSegments(bvid: key.bvid, cid: key.cid, forceRefresh: force,
                                                            version: AppVersion.current.marketingVersion)
        }
    )
    static let offlineFileName = "sponsor_segments.json"
    private let store: SponsorCacheStore
    private let fetch: Fetch
    private var memory: [SponsorVideoKey: SponsorSnapshot] = [:]
    private var flights: [SponsorVideoKey: (id: UUID, task: Task<SponsorSnapshot, Error>)] = [:]
    private var epoch = 0

    init(directory: URL, fetch: @escaping Fetch) {
        store = SponsorCacheStore(directory: directory)
        self.fetch = fetch
    }

    func cached(_ key: SponsorVideoKey, offlineDirectory: URL? = nil) async -> SponsorSnapshot? {
        guard key.isValid else { return nil }
        if offlineDirectory == nil, let value = memory[key] { return value }
        let expected = epoch
        let disk = await store.read(key, offlineDirectory: offlineDirectory)
        guard epoch == expected else { return nil }
        if offlineDirectory == nil, let current = memory[key] { return current }
        if offlineDirectory == nil, let disk { memory[key] = disk }
        return disk
    }

    func refresh(_ key: SponsorVideoKey, force: Bool = false) async throws -> SponsorSnapshot {
        guard key.isValid else { throw CoreError(category: "invalid_argument", message: "无效的视频标识", code: nil) }
        if let flight = flights[key] { return try await flight.task.value }
        let expected = epoch
        let id = UUID()
        let fetch = self.fetch
        let task = Task {
            let segments = try await fetch(key, force)
            return SponsorSnapshot(schemaVersion: 1, key: key, fetchedAt: Date(), segments: segments)
        }
        flights[key] = (id, task)
        do {
            let result = try await task.value
            if expected == epoch, flights[key]?.id == id {
                memory[key] = result
                flights[key] = nil
                // Cache capacity is bounded independently of the number of played videos.
                if memory.count > 500 {
                    let oldest = memory.min { $0.value.fetchedAt < $1.value.fetchedAt }?.key
                    if let oldest { memory[oldest] = nil }
                }
                await store.write(result, epoch: expected)
            }
            return result
        } catch {
            if flights[key]?.id == id { flights[key] = nil }
            throw error
        }
    }

    func pin(_ snapshot: SponsorSnapshot, to directory: URL) async {
        await store.pin(snapshot, to: directory)
    }

    func cachedInMemory(_ key: SponsorVideoKey) -> SponsorSnapshot? { memory[key] }

    func clear() async {
        epoch += 1
        memory.removeAll()
        // Old readers may still finish, but cannot restore the cleared cache.
        flights.removeAll()
        store.invalidate(to: epoch)
        await store.clear()
    }
}

/// File IO stays off the main actor. The lock also protects clear/write ordering
/// across actor suspension points; stale in-flight results cannot resurrect files.
private final class SponsorCacheStore: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var epoch = 0
    private var writesSincePrune = 0
    init(directory: URL) { self.directory = directory }
    func invalidate(to value: Int) { lock.lock(); epoch = value; lock.unlock() }

    func read(_ key: SponsorVideoKey, offlineDirectory: URL?) async -> SponsorSnapshot? {
        let url = offlineDirectory?.appendingPathComponent(SponsorBlockRepository.offlineFileName)
            ?? directory.appendingPathComponent(key.fileName)
        return try? await BlockingWorkQueue.files.run(priority: .utility) {
            let data = try Data(contentsOf: url)
            guard data.count <= 2_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            let snapshot = try JSONDecoder().decode(SponsorSnapshot.self, from: data)
            guard snapshot.schemaVersion == 1, snapshot.key == key else { throw CocoaError(.fileReadCorruptFile) }
            return snapshot
        }
    }

    func write(_ snapshot: SponsorSnapshot, epoch expected: Int) async {
        _ = try? await BlockingWorkQueue.files.run(priority: .utility) { [self] in
            lock.lock(); defer { lock.unlock() }
            guard epoch == expected else { return }
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent(snapshot.key.fileName), options: .atomic)
            writesSincePrune += 1
            if writesSincePrune >= 32 {
                writesSincePrune = 0
                let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                    .filter { $0.pathExtension == "json" }
                if urls.count > 500 {
                    let ordered = urls.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                        .sorted { $0.1 < $1.1 }
                    for (url, _) in ordered.prefix(urls.count - 500) { try? fm.removeItem(at: url) }
                }
            }
        }
    }

    func pin(_ snapshot: SponsorSnapshot, to target: URL) async {
        _ = try? await BlockingWorkQueue.files.run(priority: .utility) {
            // A deleted offline download must not be recreated by a late response.
            guard FileManager.default.fileExists(atPath: target.appendingPathComponent("metadata.json").path) else { return }
            try JSONEncoder().encode(snapshot).write(to: target.appendingPathComponent(SponsorBlockRepository.offlineFileName), options: .atomic)
        }
    }

    func clear() async {
        _ = try? await BlockingWorkQueue.files.run(priority: .utility) { [self] in
            lock.lock(); defer { lock.unlock() }
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
    }
}
