import Foundation

/// One actual request per media/settings/session key. Queued work without demand
/// is skipped; a blocking FFI call already in progress keeps its slot and may be
/// rejoined. Cancelling a consumer never pretends that HTTP has stopped.
@MainActor
final class PlayUrlPrefetcher {
    static let shared = PlayUrlPrefetcher()
    enum WorkSkipped: Error { case noDemand }

    struct Request: Hashable {
        let generation: UUID
        let aid: Int64
        let bvid: String
        let cid: Int64
        let qn: Int64
        let audioQn: Int64
        let cdn: String
        let codecPreference: String
    }
    private struct Cached {
        let info: PlayUrlDTO
        let timestamp: Date
    }
    private final class Demand: @unchecked Sendable {
        private let lock = NSLock()
        private var needed = true
        func set(_ value: Bool) { lock.lock(); needed = value; lock.unlock() }
        func isNeeded() -> Bool { lock.lock(); defer { lock.unlock() }; return needed }
    }
    private struct Flight {
        let id: UUID
        let demand: Demand
        var prefetchInterest: Bool
        var consumers: [UUID: CheckedContinuation<PlayUrlDTO, Error>] = [:]
        var consumed = false
    }
    private var cache: [Request: Cached] = [:]
    private var recency: [Request] = []
    private var inflight: [Request: Flight] = [:]
    private var activePrefetches = 0
    private var pendingPrefetch: Request?
    private let generation: () -> UUID
    private let load: (Request, TaskPriority, @escaping @Sendable () -> Bool) async throws -> PlayUrlDTO

    init(generation: @escaping () -> UUID = { CoreClient.shared.sessionGeneration },
         load: @escaping (Request, TaskPriority, @escaping @Sendable () -> Bool) async throws -> PlayUrlDTO = { request, priority, needed in
             try await CoreClient.shared.perform(priority: priority) { core in
                 guard needed() else { throw WorkSkipped.noDemand }
                 return try core.playUrl(aid: request.aid, bvid: request.bvid, cid: request.cid,
                                         qn: request.qn, audioQn: request.audioQn,
                                         cdn: request.cdn, codecPreference: request.codecPreference)
             }
         }) {
        self.generation = generation
        self.load = load
    }

    func prefetch(item: FeedItemDTO, qn: Int64, audioQn: Int64, cdn: String) {
        guard !item.isPGC, item.aid > 0, item.cid > 0 else { return }
        let key = Request(generation: generation(), aid: item.aid, bvid: item.bvid,
                          cid: item.cid, qn: qn, audioQn: audioQn, cdn: cdn, codecPreference: "auto")
        pruneCache()
        if cache[key] != nil { return }
        if inflight[key] != nil {
            inflight[key]?.prefetchInterest = true
            inflight[key]?.demand.set(true)
            return
        }
        guard activePrefetches == 0 else { pendingPrefetch = key; return }
        start(key, prefetch: true)
    }

    func value(aid: Int64, bvid: String, cid: Int64, qn: Int64, audioQn: Int64,
               cdn: String, codecPreference: String) async throws -> PlayUrlDTO {
        try Task.checkCancellation()
        let key = Request(generation: generation(), aid: aid, bvid: bvid, cid: cid,
                          qn: qn, audioQn: audioQn, cdn: cdn, codecPreference: codecPreference)
        if pendingPrefetch == key { pendingPrefetch = nil }
        pruneCache()
        if let cached = cache.removeValue(forKey: key) {
            recency.removeAll { $0 == key }
            return cached.info
        }
        let consumer = UUID()
        let info = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PlayUrlDTO, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if inflight[key] == nil { start(key, prefetch: false) }
                inflight[key]?.consumers[consumer] = continuation
                inflight[key]?.consumed = true
                inflight[key]?.demand.set(true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(consumer, key: key) }
        }
        try Task.checkCancellation()
        guard generation() == key.generation else { throw CancellationError() }
        return info
    }

    private func start(_ key: Request, prefetch: Bool) {
        let id = UUID()
        let demand = Demand()
        if prefetch { activePrefetches += 1 }
        inflight[key] = Flight(id: id, demand: demand, prefetchInterest: prefetch)
        Task { [load, generation] in
            let result: Result<PlayUrlDTO, Error>
            do {
                guard generation() == key.generation else { throw CancellationError() }
                result = .success(try await load(key, prefetch ? .utility : .userInitiated, { demand.isNeeded() }))
            } catch { result = .failure(error) }
            finish(key, id: id, wasPrefetch: prefetch, result: result)
        }
    }

    private func finish(_ key: Request, id: UUID, wasPrefetch: Bool, result: Result<PlayUrlDTO, Error>) {
        if wasPrefetch { activePrefetches -= 1 }
        if let flight = inflight[key], flight.id == id {
            inflight[key] = nil
            let current = generation() == key.generation
            if current, case .failure(let error) = result, error is WorkSkipped,
               flight.prefetchInterest || !flight.consumers.isEmpty {
                start(key, prefetch: flight.consumers.isEmpty)
                inflight[key]?.consumers = flight.consumers
                inflight[key]?.consumed = flight.consumed
                inflight[key]?.prefetchInterest = flight.prefetchInterest
                return
            }
            if current, flight.prefetchInterest, !flight.consumed, case .success(let info) = result {
                cache[key] = Cached(info: info, timestamp: Date())
                recency.removeAll { $0 == key }
                recency.append(key)
                while recency.count > 5 { cache.removeValue(forKey: recency.removeFirst()) }
            }
            flight.consumers.values.forEach {
                $0.resume(with: current ? result : .failure(CancellationError()))
            }
        }
        if activePrefetches == 0, let pending = pendingPrefetch {
            pendingPrefetch = nil
            if pending.generation == generation(), cache[pending] == nil {
                if inflight[pending] != nil {
                    inflight[pending]?.prefetchInterest = true
                    inflight[pending]?.demand.set(true)
                } else { start(pending, prefetch: true) }
            }
        }
    }

    private func release(_ consumer: UUID, key: Request) {
        inflight[key]?.consumers.removeValue(forKey: consumer)?.resume(throwing: CancellationError())
        updateDemand(key)
    }

    private func updateDemand(_ key: Request) {
        guard let flight = inflight[key] else { return }
        flight.demand.set(flight.prefetchInterest || !flight.consumers.isEmpty)
    }

    func retain(visibleKeys: Set<FeedItemDTO.ID>) {
        if let pending = pendingPrefetch,
           !visibleKeys.contains(pending.aid) || pending.generation != generation() { pendingPrefetch = nil }
        for key in Array(inflight.keys) where !visibleKeys.contains(key.aid) || key.generation != generation() {
            inflight[key]?.prefetchInterest = false
            updateDemand(key)
        }
    }

    func clear() {
        pendingPrefetch = nil
        cache.removeAll()
        recency.removeAll()
        for key in Array(inflight.keys) {
            inflight[key]?.prefetchInterest = false
            updateDemand(key)
        }
    }

    private func pruneCache() {
        let current = generation()
        let now = Date()
        cache = cache.filter { $0.key.generation == current && now.timeIntervalSince($0.value.timestamp) < 300 }
        recency.removeAll { cache[$0] == nil }
    }
}
