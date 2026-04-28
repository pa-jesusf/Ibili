import Foundation

/// Smart pre-fetcher that warms up `video.playurl` responses for feed
/// items the user is most likely to tap next. Designed around five
/// constraints from the product spec:
///
/// 1. **Viewport bounded.** Only the 1–2 fully visible cells at the top
///    of the feed are eligible — the coordinator above us decides which.
/// 2. **Settle gated.** Triggered ≥500 ms after the user stops scrolling
///    so we never prefetch through a fling.
/// 3. **Tier-1 minimal.** We fetch only the playurl JSON. The HLS proxy
///    already does a tight 256 KiB head probe on demand, so saving the
///    playurl round-trip (~300–500 ms) is the bulk of the win without
///    the bandwidth cost of a true media head fetch.
/// 4. **LRU bounded.** At most `capacity` entries are retained; the
///    least-recently-used is evicted when we exceed it.
/// 5. **Touch-down friendly.** The `prefetch(...)` API is idempotent and
///    safe to call from any gesture, including the synchronous Touch
///    Down event of `NavigationLink`. A second call while a fetch is in
///    flight no-ops; once cached, repeat calls just refresh LRU order.
@MainActor
final class PlayUrlPrefetcher {
    static let shared = PlayUrlPrefetcher()

    struct Cached {
        let info: PlayUrlDTO
        let qn: Int64
        let playurlMode: PlayerViewModel.PlayurlMode
        let timestamp: Date
    }

    private struct Key: Hashable {
        let aid: Int64
        let cid: Int64
        let qn: Int64
        let mode: PlayerViewModel.PlayurlMode
    }

    private var cache: [Key: Cached] = [:]
    /// LRU recency order; the head is the most recently used.
    private var recency: [Key] = []
    private var inflight: [Key: Task<Void, Never>] = [:]
    private let capacity = 5
    /// Beyond this age the entry is considered cold and discarded on
    /// take. Bilibili playurls are valid for tens of minutes but local
    /// staleness keeps memory bounded if the user idles on the feed.
    private let maxAge: TimeInterval = 5 * 60

    private init() {}

    /// Fire-and-forget warm-up. Safe to call repeatedly; reschedules at
    /// most one in-flight fetch per (aid, cid, qn, mode).
    func prefetch(item: FeedItemDTO,
                  qn: Int64,
                  playurlMode: PlayerViewModel.PlayurlMode) {
        let key = Key(aid: item.aid, cid: item.cid, qn: qn, mode: playurlMode)
        if let cached = cache[key], Date().timeIntervalSince(cached.timestamp) < maxAge {
            touch(key)
            return
        }
        if inflight[key] != nil { return }
        AppLog.debug("prefetch", "playurl 预取启动", metadata: [
            "aid": String(item.aid),
            "cid": String(item.cid),
            "qn": String(qn),
            "mode": playurlMode.rawValue,
        ])
        let started = CFAbsoluteTimeGetCurrent()
        let task = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.inflight[key] = nil } }
            do {
                let info: PlayUrlDTO = try await Task.detached {
                    switch playurlMode {
                    case .autoWeb:
                        return try CoreClient.shared.playUrl(aid: item.aid, cid: item.cid, qn: qn)
                    case .forceTV:
                        return try CoreClient.shared.playUrlTV(aid: item.aid, cid: item.cid, qn: qn)
                    }
                }.value
                let elapsed = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                await MainActor.run {
                    guard let self else { return }
                    let entry = Cached(info: info,
                                       qn: qn,
                                       playurlMode: playurlMode,
                                       timestamp: Date())
                    self.cache[key] = entry
                    self.touch(key)
                    self.evictIfNeeded()
                    AppLog.debug("prefetch", "playurl 预取命中缓存", metadata: [
                        "aid": String(item.aid),
                        "cid": String(item.cid),
                        "qn": String(qn),
                        "elapsedMs": String(elapsed),
                        "size": String(self.cache.count),
                    ])
                }
            } catch {
                AppLog.warning("prefetch", "playurl 预取失败", metadata: [
                    "aid": String(item.aid),
                    "cid": String(item.cid),
                    "error": error.localizedDescription,
                ])
            }
        }
        inflight[key] = task
    }

    /// Consume a previously prefetched playurl, returning it only if
    /// fresh. The entry is removed on take so a stale URL cannot be
    /// reused after a navigation cycle.
    func take(aid: Int64,
              cid: Int64,
              qn: Int64,
              playurlMode: PlayerViewModel.PlayurlMode) -> PlayUrlDTO? {
        let key = Key(aid: aid, cid: cid, qn: qn, mode: playurlMode)
        guard let cached = cache.removeValue(forKey: key) else { return nil }
        recency.removeAll { $0 == key }
        guard Date().timeIntervalSince(cached.timestamp) < maxAge else { return nil }
        AppLog.debug("prefetch", "playurl 缓存命中", metadata: [
            "aid": String(aid),
            "cid": String(cid),
            "qn": String(qn),
            "ageMs": String(Int(Date().timeIntervalSince(cached.timestamp) * 1000)),
        ])
        return cached.info
    }

    /// Cancel any in-flight prefetches that are no longer needed (the
    /// feed coordinator calls this when the visible window changes).
    func retain(visibleKeys: Set<FeedItemDTO.ID>) {
        for (key, task) in inflight where !visibleKeys.contains(key.aid) {
            task.cancel()
            inflight[key] = nil
        }
    }

    func clear() {
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
        cache.removeAll()
        recency.removeAll()
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.insert(key, at: 0)
    }

    private func evictIfNeeded() {
        while recency.count > capacity {
            let evicted = recency.removeLast()
            cache.removeValue(forKey: evicted)
        }
    }
}
