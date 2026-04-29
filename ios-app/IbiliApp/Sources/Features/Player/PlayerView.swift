import SwiftUI
import AVKit
import AVFoundation
import UIKit
import os

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var isLoading = true
    @Published var errorText: String?
    @Published private(set) var player: AVPlayer?
    /// `true` once the active `AVPlayerItem` has reached `.readyToPlay`.
    /// The view shows a loading spinner until this flips, so users never
    /// see AVKit's empty native chrome with a phantom pause icon while
    /// the master playlist + init segment are still loading from the
    /// local proxy.
    @Published private(set) var isVideoReady = false
    @Published private(set) var availableQualities: [(qn: Int64, label: String)] = []
    @Published var currentQn: Int64 = 0
    @Published private(set) var availableAudioQualities: [(qn: Int64, label: String)] = []
    @Published var currentAudioQn: Int64 = 0
    @Published var rate: Float = 1.0 { didSet { applyRate() } }
    /// Lightweight handle the SwiftUI player container hands us so we
    /// can drive a snapshot crossfade across an AVPlayer identity swap
    /// without forcing the view-model to know about UIKit views.
    weak var playerSwapOverlay: PlayerSwapOverlay?

    private var aid: Int64 = 0
    private var cid: Int64 = 0
    private var loadGeneration: UInt64 = 0
    private let discoveryQn: Int64 = 120
    private let engine: PlaybackEngine = HLSProxyEngine.shared
    private var sourceByQn: [Int64: PlayUrlDTO] = [:]
    private var remuxFallbackAttemptedQns: Set<Int64> = []
    private var isUsingRemuxFallback = false
    private var itemStatusObservation: NSKeyValueObservation?
    /// Snapshot of the most recent `load(...)` arguments, used by
    /// `reload()` to recover after the local proxy has been killed by
    /// iOS in the background.
    private var lastLoadedItem: FeedItemDTO?
    private var lastPreferredQn: Int64 = 0
    private var lastFastLoad: Bool = false
    /// Number of automatic recovery attempts the view-model has issued
    /// for the current `(aid, cid)`. Reset to zero in `load(...)`.
    /// Cap of 1 keeps us from looping when the upstream playurl itself
    /// is genuinely broken.
    private var autoReloadAttempts: Int = 0
    /// qns that AVPlayer has refused for the current `(aid, cid)` since
    /// the last fresh `load(...)`. When an item fails playback we drop
    /// its qn into this set and reload at the next-highest available
    /// qn instead of looping on the same broken variant. Reset on a
    /// fresh load so a future video starts with a clean slate.
    private var blockedQns: Set<Int64> = []
    /// Preparation backing the currently visible player. Stored so a
    /// later low->high upgrade can release the old proxy token without
    /// tearing down the newly-promoted stream.
    private var activePreparation: EnginePreparation?
    /// Pending fast-load warm-player task for the higher quality.
    /// Cancelled on teardown / manual quality switch / next load so a
    /// stale upgrade cannot resurrect a closed player.
    private var pendingReadyTask: Task<WarmPlayer, Error>?
    /// Coordination task that awaits `pendingReadyTask` and promotes it
    /// once the high-quality player is actually playing.
    private var pendingUpgradeTask: Task<Void, Never>?

    deinit {
        MainActor.assumeIsolated {
            player?.pause()
            itemStatusObservation = nil
            activePreparation?.release()
            activePreparation = nil
            pendingUpgradeTask?.cancel()
            pendingReadyTask?.cancel()
        }
    }

    func load(item: FeedItemDTO, preferredQn: Int64, preferredAudioQn: Int64 = 0, fastLoad: Bool) async {
        // Some entry points (notably the search results grid) hand us
        // a `FeedItemDTO` with `cid == 0` because the upstream
        // search-by-type endpoint omits cids. Resolve it via the view
        // API before doing anything player-related — otherwise both
        // the web and TV playurl calls hit "请求错误 / 啥都木有".
        var item = item
        if item.cid == 0 {
            do {
                let resolvedCid: Int64 = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.videoViewCid(bvid: item.bvid)
                }.value
                item = FeedItemDTO(
                    aid: item.aid,
                    bvid: item.bvid,
                    cid: resolvedCid,
                    title: item.title,
                    cover: item.cover,
                    author: item.author,
                    durationSec: item.durationSec,
                    play: item.play,
                    danmaku: item.danmaku
                )
            } catch {
                isLoading = false
                errorText = "无法解析视频信息: \((error as NSError).localizedDescription)"
                return
            }
        }
        if player != nil, aid == item.aid, cid == item.cid {
            AppLog.debug("player", "跳过重复播放器加载", metadata: [
                "aid": String(item.aid),
                "cid": String(item.cid),
            ])
            return
        }
        let startedAt = CFAbsoluteTimeGetCurrent()
        loadGeneration &+= 1
        let generation = loadGeneration
        // Treat a `reload()` of the same video (which zeroes aid/cid)
        // as the same load context so we keep the blocked-qn set; only
        // a fresh navigation to a different (aid,cid) wipes it.
        let isSameVideo = (lastLoadedItem?.aid == item.aid && lastLoadedItem?.cid == item.cid)
        aid = item.aid; cid = item.cid
        lastLoadedItem = item
        lastPreferredQn = preferredQn
        lastFastLoad = fastLoad
        autoReloadAttempts = 0
        if !isSameVideo {
            blockedQns.removeAll()
            remuxFallbackAttemptedQns.removeAll()
            sourceByQn.removeAll()
        }
        isUsingRemuxFallback = false
        if preferredAudioQn > 0 { currentAudioQn = preferredAudioQn }
        isLoading = true; errorText = nil; isVideoReady = false
        itemStatusObservation = nil
        cancelPendingUpgrade()
        AppLog.info("player", "开始加载播放器", metadata: [
            "aid": String(item.aid),
            "cid": String(item.cid),
            "preferredQn": String(preferredQn),
            "fastLoad": String(fastLoad),
        ])
        do {
            let discoveryQnTarget = max(preferredQn, discoveryQn)
            let initial: PlayUrlDTO
            if let warm = PlayUrlPrefetcher.shared.take(aid: item.aid,
                                                       cid: item.cid,
                                                       qn: discoveryQnTarget) {
                initial = warm
            } else {
                initial = try await fetchPlayUrl(aid: item.aid,
                                                 cid: item.cid,
                                                 qn: discoveryQnTarget)
            }
            guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else { return }
            let qualities = normalizedQualities(from: initial)
            let targetQn = resolveTargetQn(preferredQn: preferredQn, qualities: qualities, fallback: initial.quality)
            let info: PlayUrlDTO
            if targetQn == initial.quality {
                info = initial
            } else if let warm = PlayUrlPrefetcher.shared.take(aid: item.aid,
                                                                cid: item.cid,
                                                                qn: targetQn) {
                info = warm
            } else {
                info = try await fetchPlayUrl(aid: item.aid,
                                              cid: item.cid,
                                              qn: targetQn)
            }
            guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else { return }
            let finalQualities = normalizedQualities(from: info).isEmpty ? qualities : normalizedQualities(from: info)
            self.availableQualities = finalQualities
            self.sourceByQn[info.quality] = info
            self.availableAudioQualities = normalizedAudioQualities(from: info)
            self.currentAudioQn = info.audioQuality

            // Decide whether to race the lowest variant against the
            // preferred one. We only do it when the user opted in AND
            // there's actually something cheaper to race — picking the
            // lowest qn that is strictly less than the preferred one.
            let lowestQn = finalQualities.map(\.qn).min() ?? info.quality
            let runFastLoad = fastLoad && lowestQn < info.quality
            if runFastLoad {
                let loInfo: PlayUrlDTO
                if let warm = PlayUrlPrefetcher.shared.take(aid: item.aid,
                                                            cid: item.cid,
                                                            qn: lowestQn) {
                    loInfo = warm
                } else {
                    loInfo = try await fetchPlayUrl(aid: item.aid,
                                                    cid: item.cid,
                                                    qn: lowestQn)
                }
                guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else { return }
                self.sourceByQn[loInfo.quality] = loInfo
                // Race on hidden players reaching actual playback, not
                // on `makeItem` completion. That keeps the feature true
                // to its purpose: first picture wins, not first asset
                // construction.
                let hiTask = Task { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.makeWarmPlayer(for: info, presenting: item)
                }
                let loTask = Task { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.makeWarmPlayer(for: loInfo, presenting: item)
                }
                let winner = try await Self.raceFirstWarmPlayer(hi: hiTask, lo: loTask)
                guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else {
                    discardWarmPlayerTask(hiTask)
                    discardWarmPlayerTask(loTask)
                    AppLog.debug("player", "丢弃过期播放器加载结果", metadata: [
                        "aid": String(item.aid),
                        "cid": String(item.cid),
                    ])
                    return
                }
                let startupMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                switch winner {
                case .hi(let hiWarm):
                    discardWarmPlayerTask(loTask)
                    await showWarmPlayer(hiWarm,
                                         qn: info.quality,
                                         generation: generation)
                    var meta = hiWarm.preparation.logSummary
                    meta["aid"] = String(item.aid)
                    meta["cid"] = String(item.cid)
                    meta["quality"] = String(info.quality)
                    meta["available"] = finalQualities.map { String($0.qn) }.joined(separator: ",")
                    meta["streamType"] = info.streamType
                    meta["videoCodec"] = info.videoCodec.isEmpty ? "-" : info.videoCodec
                    meta["audioCodec"] = info.audioCodec.isEmpty ? "-" : info.audioCodec
                    meta["separateAudio"] = info.audioUrl == nil ? "false" : "true"
                    meta["prepMs"] = String(hiWarm.preparation.totalElapsedMs)
                    meta["startupMs"] = String(startupMs)
                    meta["fastLoad"] = "true"
                    meta["raceWinner"] = "hi"
                    meta["winnerBasis"] = "timeControlStatus.playing"
                    AppLog.info("player", "快速加载已就绪(高画质先达到可播)", metadata: meta)
                case .lo(let loWarm):
                    await showWarmPlayer(loWarm,
                                         qn: loInfo.quality,
                                         generation: generation)
                    var meta = loWarm.preparation.logSummary
                    meta["aid"] = String(item.aid)
                    meta["cid"] = String(item.cid)
                    meta["quality"] = String(loInfo.quality)
                    meta["available"] = finalQualities.map { String($0.qn) }.joined(separator: ",")
                    meta["streamType"] = loInfo.streamType
                    meta["videoCodec"] = loInfo.videoCodec.isEmpty ? "-" : loInfo.videoCodec
                    meta["audioCodec"] = loInfo.audioCodec.isEmpty ? "-" : loInfo.audioCodec
                    meta["separateAudio"] = loInfo.audioUrl == nil ? "false" : "true"
                    meta["prepMs"] = String(loWarm.preparation.totalElapsedMs)
                    meta["startupMs"] = String(startupMs)
                    meta["targetQn"] = String(info.quality)
                    meta["fastLoad"] = "true"
                    meta["raceWinner"] = "lo"
                    meta["winnerBasis"] = "timeControlStatus.playing"
                    AppLog.info("player", "快速加载已就绪(低画质先达到可播)", metadata: meta)
                    self.pendingReadyTask = hiTask
                    self.pendingUpgradeTask = Task { @MainActor [weak self] in
                        do {
                            let hiWarm = try await hiTask.value
                            guard let self else {
                                hiWarm.stop()
                                return
                            }
                            guard !Task.isCancelled,
                                  self.loadGeneration == generation else {
                                hiWarm.stop()
                                return
                            }
                            await self.applyFastLoadUpgrade(hiWarm: hiWarm,
                                                            hiInfo: info,
                                                            generation: generation)
                        } catch {
                            if !(error is CancellationError) {
                                AppLog.warning("player", "高画质预加载失败，保留低画质", metadata: [
                                    "detail": error.localizedDescription,
                                ])
                            }
                        }
                    }
                }
                if let msg = info.debugMessage {
                    AppLog.warning("player", "core 返回调试信息", metadata: ["detail": msg])
                }
            } else {
                let prep = try await engine.makeItem(for: info)
                guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else {
                    AppLog.debug("player", "丢弃过期播放器加载结果", metadata: [
                        "aid": String(item.aid),
                        "cid": String(item.cid),
                    ])
                    return
                }
                applyPresentationMetadata(to: prep.item, for: item)
                self.currentQn = info.quality
                let player = AVPlayer(playerItem: prep.item)
                // Leave `automaticallyWaitsToMinimizeStalling` at its
                // default (`true`). With our HLS proxy AVPlayer needs to
                // fetch the master + media playlists and the init
                // segment before it can emit frames; forcing the flag
                // off makes it call `play()` before there is anything
                // to render and the playback gets stuck at rate=1 with
                // no frames (the user has to tap once to unstick it).
                self.activePreparation = prep
                observeItemStatus(prep.item, generation: generation)
                self.player = player
                self.player?.play()
                applyRate()
                let startupMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                var meta = prep.logSummary
                meta["aid"] = String(item.aid)
                meta["cid"] = String(item.cid)
                meta["quality"] = String(info.quality)
                meta["available"] = finalQualities.map { String($0.qn) }.joined(separator: ",")
                meta["streamType"] = info.streamType
                meta["videoCodec"] = info.videoCodec.isEmpty ? "-" : info.videoCodec
                meta["audioCodec"] = info.audioCodec.isEmpty ? "-" : info.audioCodec
                meta["separateAudio"] = info.audioUrl == nil ? "false" : "true"
                meta["prepMs"] = String(prep.totalElapsedMs)
                meta["startupMs"] = String(startupMs)
                AppLog.info("player", "播放器已就绪", metadata: meta)
                if let msg = info.debugMessage {
                    AppLog.warning("player", "core 返回调试信息", metadata: ["detail": msg])
                }
            }
        } catch {
            errorText = error.localizedDescription
            AppLog.error("player", "播放器加载失败", error: error, metadata: [
                "aid": String(item.aid),
                "cid": String(item.cid),
            ])
        }
        if isCurrentLoad(generation, aid: item.aid, cid: item.cid) {
            isLoading = false
        }
    }

    /// Re-runs `load(...)` for the most recently loaded item. Used by
    /// scene-phase recovery when the local HLS proxy has been killed in
    /// the background and the existing AVPlayer can no longer pull from
    /// `127.0.0.1:<dead port>`.
    func reload() async {
        guard let item = lastLoadedItem else { return }
        AppLog.info("player", "检测到本地代理失效，重新加载", metadata: [
            "aid": String(item.aid),
            "cid": String(item.cid),
        ])
        // Force `load` past its idempotency check by clearing the
        // currently-loaded coordinates and tearing down the player.
        let priorAttempts = autoReloadAttempts
        player?.pause()
        player = nil
        itemStatusObservation = nil
        activePreparation?.release()
        activePreparation = nil
        cancelPendingUpgrade()
        isUsingRemuxFallback = false
        aid = 0; cid = 0
        await load(item: item, preferredQn: lastPreferredQn, fastLoad: lastFastLoad)
        // `load(...)` zeroes the counter; preserve our caller's tally
        // so a chain of failed reloads cannot loop indefinitely.
        autoReloadAttempts = max(autoReloadAttempts, priorAttempts)
    }

    /// Whether the engine still owns a live proxy stream. False after
    /// iOS suspends the app long enough to kill the listener.
    var isEngineAlive: Bool { HLSProxyEngine.shared.isAlive }

    func activatePlayback() {
        PlayerPlaybackCoordinator.shared.activate(self)
        player?.play()
        applyRate()
    }

    func pauseForDeactivation() {
        player?.pause()
    }

    func switchQuality(to qn: Int64) async {
        guard let player else { return }
        let generation = loadGeneration
        let resumeAt = player.currentTime()
        let wasPlaying = player.timeControlStatus == .playing
        // A pending fast-load upgrade is now obsolete — user is
        // explicitly choosing a different quality.
        cancelPendingUpgrade()
        AppLog.info("player", "开始切换清晰度", metadata: [
            "aid": String(aid),
            "cid": String(cid),
            "fromQn": String(currentQn),
            "toQn": String(qn),
        ])
        do {
            // Detach the active item and its KVO BEFORE tearing the
            // proxy down. Otherwise the old item's resource loader
            // starts getting 404s the instant the token is gone, the
            // item flips to `.failed`, and our `observeItemStatus`
            // auto-reload kicks in mid-switch and races the new
            // `makeItem` we are about to await.
            isVideoReady = false
            itemStatusObservation = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            activePreparation?.release()
            activePreparation = nil
            // Releasing the previous source before allocating the new
            // one keeps the proxy token table from growing across
            // switches without tearing down other tab's retained players.
            isUsingRemuxFallback = false
            let info = try await fetchPlayUrl(aid: aid, cid: cid, qn: qn)
            self.sourceByQn[info.quality] = info
            guard isCurrentLoad(generation, aid: aid, cid: cid) else { return }
            let prep = try await engine.makeItem(for: info)
            guard isCurrentLoad(generation, aid: aid, cid: cid) else { return }
            if let item = lastLoadedItem {
                applyPresentationMetadata(to: prep.item, for: item)
            }
            activePreparation = prep
            observeItemStatus(prep.item, generation: generation)
            player.replaceCurrentItem(with: prep.item)
            await player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
            applyRate()
            self.availableQualities = normalizedQualities(from: info)
            self.currentQn = info.quality
            self.availableAudioQualities = normalizedAudioQualities(from: info)
            self.currentAudioQn = info.audioQuality
            var meta = prep.logSummary
            meta["aid"] = String(aid)
            meta["cid"] = String(cid)
            meta["quality"] = String(info.quality)
            meta["resumeSec"] = String(format: "%.3f", resumeAt.seconds)
            meta["streamType"] = info.streamType
            meta["videoCodec"] = info.videoCodec.isEmpty ? "-" : info.videoCodec
            meta["audioCodec"] = info.audioCodec.isEmpty ? "-" : info.audioCodec
            meta["separateAudio"] = info.audioUrl == nil ? "false" : "true"
            meta["prepMs"] = String(prep.totalElapsedMs)
            AppLog.info("player", "清晰度切换成功", metadata: meta)
            if let msg = info.debugMessage {
                AppLog.warning("player", "core 返回调试信息", metadata: ["detail": msg])
            }
        } catch {
            errorText = error.localizedDescription
            AppLog.error("player", "清晰度切换失败", error: error, metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "toQn": String(qn),
            ])
        }
    }

    func teardown() {
        PlayerPlaybackCoordinator.shared.unregister(self)
        loadGeneration &+= 1
        AppLog.debug("player", "销毁播放器", metadata: [
            "aid": String(aid),
            "cid": String(cid),
        ])
        player?.pause()
        player = nil
        itemStatusObservation = nil
        activePreparation?.release()
        activePreparation = nil
        cancelPendingUpgrade()
        isVideoReady = false
        isUsingRemuxFallback = false
    }

    /// Cancel any in-flight fast-load upgrade. Safe to call when no
    /// upgrade is pending.
    private func cancelPendingUpgrade() {
        pendingUpgradeTask?.cancel()
        pendingUpgradeTask = nil
        let readyTask = pendingReadyTask
        pendingReadyTask = nil
        discardWarmPlayerTask(readyTask)
    }

    /// Cancel and reap a hidden warm-player task. If the task already
    /// completed we synchronously stop its muted player and release its
    /// proxy token.
    private func discardWarmPlayerTask(_ task: Task<WarmPlayer, Error>?) {
        guard let task else { return }
        task.cancel()
        Task { @MainActor in
            guard let warm = try? await task.value else { return }
            warm.stop()
        }
    }

    /// Build a muted hidden player and wait until it is actually
    /// playing. This gives the fast-load race a meaningful winner:
    /// whichever stream is first to render progress, not whichever
    /// finished `makeItem` first.
    private func makeWarmPlayer(for source: PlayUrlDTO, presenting item: FeedItemDTO) async throws -> WarmPlayer {
        var preparation: EnginePreparation?
        var hiddenPlayer: AVPlayer?
        do {
            let prep = try await engine.makeItem(for: source)
            preparation = prep
            try Task.checkCancellation()
            applyPresentationMetadata(to: prep.item, for: item)

            let player = AVPlayer(playerItem: prep.item)
            hiddenPlayer = player
            player.isMuted = true
            applyRate(to: player)
            player.play()

            try await Self.waitUntilActuallyPlaying(player: player, item: prep.item)
            try Task.checkCancellation()
            return WarmPlayer(player: player, preparation: prep)
        } catch {
            hiddenPlayer?.pause()
            hiddenPlayer?.replaceCurrentItem(with: nil)
            preparation?.release()
            throw error
        }
    }

    /// Race two hidden players and return whichever reaches actual
    /// playback first.
    private static func raceFirstWarmPlayer(
        hi: Task<WarmPlayer, Error>,
        lo: Task<WarmPlayer, Error>
    ) async throws -> FastLoadWinner {
        try await withCheckedThrowingContinuation { continuation in
            let state = OSAllocatedUnfairLock<RaceState>(initialState: .pending(hiError: nil, loError: nil))
            Task {
                do {
                    let warm = try await hi.value
                    state.withLock { current in
                        if case .resolved = current { return }
                        current = .resolved
                        continuation.resume(returning: .hi(warm))
                    }
                } catch {
                    state.withLock { current in
                        guard case .pending(_, let loErr) = current else { return }
                        if let loErr {
                            current = .resolved
                            continuation.resume(throwing: loErr)
                        } else {
                            current = .pending(hiError: error, loError: nil)
                        }
                    }
                }
            }
            Task {
                do {
                    let warm = try await lo.value
                    state.withLock { current in
                        if case .resolved = current { return }
                        current = .resolved
                        continuation.resume(returning: .lo(warm))
                    }
                } catch {
                    state.withLock { current in
                        guard case .pending(let hiErr, _) = current else { return }
                        if let hiErr {
                            current = .resolved
                            continuation.resume(throwing: hiErr)
                        } else {
                            current = .pending(hiError: nil, loError: error)
                        }
                    }
                }
            }
        }
    }

    /// Wait until a hidden player has genuinely started playback.
    private static func waitUntilActuallyPlaying(player: AVPlayer,
                                                 item: AVPlayerItem) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let state = OSAllocatedUnfairLock<ObservationState>(initialState: .pending)
            var itemObservation: NSKeyValueObservation?
            var playerObservation: NSKeyValueObservation?

            let finish: (Result<Void, Error>) -> Void = { result in
                let shouldResume = state.withLock { current -> Bool in
                    guard case .pending = current else { return false }
                    current = .resolved
                    return true
                }
                guard shouldResume else { return }
                itemObservation?.invalidate()
                playerObservation?.invalidate()
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            itemObservation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                switch item.status {
                case .failed:
                    finish(.failure(item.error ?? WarmPlayerError.unexpectedFailure))
                case .readyToPlay:
                    if player.timeControlStatus == .playing {
                        finish(.success(()))
                    }
                default:
                    break
                }
            }
            playerObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
                if player.timeControlStatus == .playing {
                    finish(.success(()))
                }
            }
        }
    }

    /// Make a warmed hidden player visible as the initial winner.
    private func showWarmPlayer(_ warm: WarmPlayer,
                                qn: Int64,
                                generation: UInt64) async {
        warm.player.pause()
        await warm.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        guard loadGeneration == generation else {
            warm.stop()
            return
        }
        warm.player.isMuted = false
        itemStatusObservation = nil
        observeItemStatus(warm.preparation.item, generation: generation)
        activePreparation = warm.preparation
        player = warm.player
        currentQn = qn
        isVideoReady = true
        warm.player.play()
        applyRate(to: warm.player)
    }

    /// Hot-swap the visible player to the warmed high-quality player.
    /// Each `AVPlayerItem` stays with its original `AVPlayer`, so we
    /// avoid AVFoundation's one-item-per-player assertion entirely.
    private func applyFastLoadUpgrade(hiWarm: WarmPlayer,
                                      hiInfo: PlayUrlDTO,
                                      generation: UInt64) async {
        guard let activePlayer = self.player else {
            hiWarm.stop()
            return
        }
        let resumeAt = activePlayer.currentTime()
        let wasPlaying = activePlayer.timeControlStatus == .playing
        let previousPreparation = activePreparation
        AppLog.info("player", "快速加载无缝升级", metadata: [
            "fromQn": String(self.currentQn),
            "toQn": String(hiInfo.quality),
            "videoCodec": hiInfo.videoCodec.isEmpty ? "-" : hiInfo.videoCodec,
            "audioCodec": hiInfo.audioCodec.isEmpty ? "-" : hiInfo.audioCodec,
            "resumeSec": String(format: "%.3f", resumeAt.seconds),
            "prepMs": String(hiWarm.preparation.totalElapsedMs),
        ])
        // Pause the warm player but use a default-tolerance seek so
        // AVPlayer can resume from the closest sync sample. A
        // zero-tolerance exact seek would force a re-buffer at the
        // hand-off point and turn the swap into a noticeable stall.
        hiWarm.player.pause()
        await hiWarm.player.seek(to: resumeAt)
        guard loadGeneration == generation else {
            hiWarm.stop()
            return
        }
        // Pre-fade audio: muting the outgoing player just before AVKit
        // tears its AVPlayerLayer down hides the click that otherwise
        // happens at the swap moment.
        activePlayer.isMuted = true
        // Snapshot the current AVPlayerLayer contents and crossfade
        // over the swap so users don't see AVKit's brief black frame
        // while it rebuilds the layer for the new AVPlayer instance.
        playerSwapOverlay?.beginCrossfade()
        itemStatusObservation = nil
        hiWarm.player.isMuted = false
        observeItemStatus(hiWarm.preparation.item, generation: generation)
        activePreparation = hiWarm.preparation
        player = hiWarm.player
        self.currentQn = hiInfo.quality
        isVideoReady = true
        if wasPlaying { hiWarm.player.play() }
        applyRate(to: hiWarm.player)
        activePlayer.pause()
        activePlayer.replaceCurrentItem(with: nil)
        previousPreparation?.release()
        pendingReadyTask = nil
        pendingUpgradeTask = nil
    }


    /// item has buffered enough to render its first frame. The earlier
    /// generation guard ensures stale loads (rapid quality switches /
    /// dismissals) cannot resurrect a closed player.
    private func observeItemStatus(_ item: AVPlayerItem, generation: UInt64) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.loadGeneration == generation else { return }
                switch item.status {
                case .readyToPlay:
                    self.isVideoReady = true
                case .failed:
                    let detail = item.error?.localizedDescription ?? "unknown"
                    AppLog.error("player", "AVPlayerItem 失败", error: item.error, metadata: [
                        "detail": detail,
                    ])
                    await self.exportActiveDiagnostics(reason: "AVPlayerItem failed: \(detail)", generation: generation)
                    // Recovery order:
                    //   * CoreMedia -12927 usually means AVPlayer rejected
                    //     this fMP4/HLS packaging. Try one remux fallback
                    //     for the same qn before sacrificing quality.
                    //   * If remux is unavailable or also fails, block the
                    //     qn and reload at the next playable quality.
                    //   * For non-codec/proxy failures, keep the existing
                    //     one-shot proxy reload behavior.
                    let failingQn = self.currentQn
                    if self.shouldTryRemuxFallback(for: item, qn: failingQn),
                       let source = self.sourceByQn[failingQn] {
                        self.remuxFallbackAttemptedQns.insert(failingQn)
                        Task { await self.fallbackToRemux(source: source, generation: generation, detail: detail) }
                        return
                    }
                    if self.isUsingRemuxFallback, failingQn > 0 {
                        self.blockedQns.insert(failingQn)
                        AppLog.warning("player", "remux fallback 失败，自动降档", metadata: [
                            "detail": detail,
                            "blockedQn": String(failingQn),
                        ])
                        Task { await self.reload() }
                        return
                    }
                    let alreadyBlocked = failingQn > 0 && self.blockedQns.contains(failingQn)
                    if failingQn > 0, !alreadyBlocked {
                        self.blockedQns.insert(failingQn)
                        AppLog.warning("player", "尝试自动恢复播放(降档)", metadata: [
                            "detail": detail,
                            "blockedQn": String(failingQn),
                        ])
                        Task { await self.reload() }
                    } else if self.autoReloadAttempts < 1 {
                        self.autoReloadAttempts += 1
                        AppLog.warning("player", "尝试自动恢复播放", metadata: [
                            "detail": detail,
                            "attempt": String(self.autoReloadAttempts),
                        ])
                        Task { await self.reload() }
                    } else {
                        self.errorText = detail
                    }
                default:
                    break
                }
            }
        }
    }

    private func shouldTryRemuxFallback(for item: AVPlayerItem, qn: Int64) -> Bool {
        guard qn > 0, !isUsingRemuxFallback, !remuxFallbackAttemptedQns.contains(qn) else { return false }
        guard FFmpegRemuxer.shared.isAvailable else { return false }
        guard sourceByQn[qn] != nil else { return false }
        return Self.containsCoreMedia12927(item.error) || Self.errorLogMentions12927(item.errorLog())
    }

    private func fallbackToRemux(source: PlayUrlDTO, generation: UInt64, detail: String) async {
        guard loadGeneration == generation else { return }
        let resumeAt = player?.currentTime() ?? .zero
        AppLog.warning("player", "尝试 FFmpeg remux fallback", metadata: [
            "detail": detail,
            "qn": String(source.quality),
            "resumeSec": String(format: "%.3f", resumeAt.seconds),
        ])
        isLoading = true
        isVideoReady = false
        itemStatusObservation = nil
        cancelPendingUpgrade()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        activePreparation?.release()
        activePreparation = nil

        do {
            let prep = try await RemuxMP4Engine.shared.makeItem(for: source)
            guard loadGeneration == generation else {
                prep.release()
                return
            }
            if let item = lastLoadedItem {
                applyPresentationMetadata(to: prep.item, for: item)
            }
            let remuxPlayer = AVPlayer(playerItem: prep.item)
            activePreparation = prep
            isUsingRemuxFallback = true
            currentQn = source.quality
            observeItemStatus(prep.item, generation: generation)
            player = remuxPlayer
            if resumeAt.isValid && resumeAt.seconds.isFinite && resumeAt.seconds > 0 {
                await remuxPlayer.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            remuxPlayer.play()
            applyRate(to: remuxPlayer)
            isLoading = false
            var meta = prep.logSummary
            meta["quality"] = String(source.quality)
            meta["resumeSec"] = String(format: "%.3f", resumeAt.seconds)
            AppLog.info("player", "FFmpeg remux fallback 已启动", metadata: meta)
        } catch {
            guard loadGeneration == generation else { return }
            isUsingRemuxFallback = false
            AppLog.error("player", "FFmpeg remux fallback 失败", error: error, metadata: [
                "qn": String(source.quality),
            ])
            if source.quality > 0 {
                blockedQns.insert(source.quality)
                await reload()
            } else {
                isLoading = false
                errorText = error.localizedDescription
            }
        }
    }

    private static func containsCoreMedia12927(_ error: Error?) -> Bool {
        guard let error else { return false }
        let ns = error as NSError
        if ns.domain == "CoreMediaErrorDomain", ns.code == -12927 { return true }
        if ns.localizedDescription.contains("-12927") { return true }
        for value in ns.userInfo.values {
            if let nested = value as? Error, containsCoreMedia12927(nested) { return true }
            if String(describing: value).contains("-12927") { return true }
        }
        return false
    }

    private static func errorLogMentions12927(_ log: AVPlayerItemErrorLog?) -> Bool {
        guard let log else { return false }
        return log.events.contains { event in
            event.errorStatusCode == -12927
                || event.errorComment?.contains("-12927") == true
                || event.errorDomain == "CoreMediaErrorDomain"
        }
    }

    private func exportActiveDiagnostics(reason: String, generation: UInt64) async {
        guard loadGeneration == generation, let preparation = activePreparation else { return }
        if let url = await preparation.exportDiagnostics(reason) {
            AppLog.info("player", "播放器失败诊断文件已导出", metadata: [
                "path": url.path,
                "qn": String(currentQn),
            ])
        }
    }

    private func fetchPlayUrl(aid: Int64, cid: Int64, qn: Int64) async throws -> PlayUrlDTO {
        try await fetchPlayUrl(aid: aid, cid: cid, qn: qn, audioQn: currentAudioQn)
    }

    private func fetchPlayUrl(aid: Int64, cid: Int64, qn: Int64, audioQn: Int64) async throws -> PlayUrlDTO {
        try await Task.detached {
            try CoreClient.shared.playUrl(aid: aid, cid: cid, qn: qn, audioQn: audioQn)
        }.value
    }

    private func isCurrentLoad(_ generation: UInt64, aid: Int64, cid: Int64) -> Bool {
        generation == loadGeneration && self.aid == aid && self.cid == cid
    }

    private func normalizedQualities(from info: PlayUrlDTO) -> [(qn: Int64, label: String)] {
        let pairs = zip(info.acceptQuality, info.acceptDescription)
            .map { (qn: $0.0, label: $0.1) }
        let merged = Dictionary(uniqueKeysWithValues: pairs.map { ($0.qn, $0.label) })
        return merged.keys.sorted(by: >).map { ($0, merged[$0] ?? qualityLabel(for: $0)) }
    }

    private func resolveTargetQn(preferredQn: Int64,
                                 qualities: [(qn: Int64, label: String)],
                                 fallback: Int64) -> Int64 {
        let codes = Set(qualities.map(\.qn)).union([fallback])
        let sorted = codes.sorted(by: >)
        guard let absoluteHighest = sorted.first else { return fallback }
        // Filter against (a) what the device's decoder + display chain
        // can actually play and (b) qns that AVPlayer has already
        // refused this session (typically HDR/DV/8K variants the
        // device claims to support but actually chokes on for this
        // particular asset). Keeping unsupported qns out of the auto
        // pick is what saves us from CoreMedia -12927.
        let playable = sorted.filter { Self.deviceSupports(qn: $0) && !blockedQns.contains($0) }
        let highest = playable.first ?? absoluteHighest
        guard preferredQn > 0 else { return highest }
        return playable.first(where: { $0 <= preferredQn })
            ?? sorted.first(where: { $0 <= preferredQn })
            ?? highest
    }

    /// Static device capability map. We only block qns that the device
    /// can never play; codec-level surprises (e.g. an asset that
    /// advertises HDR but actually fails) are caught dynamically by
    /// `blockedQns` once AVPlayer reports the failure.
    ///
    /// qn → required capability:
    /// * 125 = HDR10/HLG  → `AVPlayer.availableHDRModes` includes hdr10/hlg
    /// * 126 = Dolby Vision → availableHDRModes includes dolbyVision
    /// * 127 = 8K — no clean public API to detect 8K HEVC decode; we
    ///   trust upstream and rely on the dynamic blocklist if it fails.
    private static func deviceSupports(qn: Int64) -> Bool {
        switch qn {
        case 125: return hdrCapability.allowsHDR
        case 126: return hdrCapability.allowsDolbyVision
        default:  return true
        }
    }

    private struct HDRCapability {
        let allowsHDR: Bool
        let allowsDolbyVision: Bool
    }

    private static let hdrCapability: HDRCapability = {
        let modes = AVPlayer.availableHDRModes
        return HDRCapability(
            allowsHDR: modes.contains(.hdr10) || modes.contains(.hlg) || modes.contains(.dolbyVision),
            allowsDolbyVision: modes.contains(.dolbyVision)
        )
    }()

    private func qualityLabel(for qn: Int64) -> String {
        switch qn {
        case 127: return "8K"
        case 126: return "杜比"
        case 125: return "HDR"
        case 120: return "4K"
        case 116: return "1080P60"
        case 112: return "1080P+"
        case 80: return "1080P"
        case 74: return "720P60"
        case 64: return "720P"
        case 32: return "480P"
        case 16: return "360P"
        case 6: return "240P"
        default: return "画质 \(qn)"
        }
    }

    private func normalizedAudioQualities(from info: PlayUrlDTO) -> [(qn: Int64, label: String)] {
        guard !info.acceptAudioQuality.isEmpty else { return [] }
        return zip(info.acceptAudioQuality, info.acceptAudioDescription)
            .map { (qn: $0.0, label: $0.1) }
    }

    func switchAudioQuality(to audioQn: Int64) async {
        guard let player else { return }
        let generation = loadGeneration
        let resumeAt = player.currentTime()
        let wasPlaying = player.timeControlStatus == .playing
        cancelPendingUpgrade()
        AppLog.info("player", "开始切换音质", metadata: [
            "aid": String(aid),
            "cid": String(cid),
            "fromAudioQn": String(currentAudioQn),
            "toAudioQn": String(audioQn),
        ])
        do {
            isVideoReady = false
            itemStatusObservation = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            activePreparation?.release()
            activePreparation = nil
            isUsingRemuxFallback = false
            let info = try await fetchPlayUrl(aid: aid, cid: cid, qn: currentQn, audioQn: audioQn)
            self.sourceByQn[info.quality] = info
            guard isCurrentLoad(generation, aid: aid, cid: cid) else { return }
            let prep = try await engine.makeItem(for: info)
            guard isCurrentLoad(generation, aid: aid, cid: cid) else { return }
            if let item = lastLoadedItem {
                applyPresentationMetadata(to: prep.item, for: item)
            }
            activePreparation = prep
            observeItemStatus(prep.item, generation: generation)
            player.replaceCurrentItem(with: prep.item)
            await player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
            applyRate()
            self.currentAudioQn = info.audioQuality
            self.availableAudioQualities = normalizedAudioQualities(from: info)
            AppLog.info("player", "音质切换成功", metadata: [
                "audioQuality": String(info.audioQuality),
                "audioQualityLabel": info.audioQualityLabel,
            ])
        } catch {
            errorText = error.localizedDescription
            AppLog.error("player", "音质切换失败", error: error, metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "toAudioQn": String(audioQn),
            ])
        }
    }

    private func applyRate(to targetPlayer: AVPlayer? = nil) {
        guard let player = targetPlayer ?? player else { return }
        player.rate = rate
        if rate != 0 { player.defaultRate = rate }
    }

    private func applyPresentationMetadata(to playerItem: AVPlayerItem, for item: FeedItemDTO) {
        let title = item.title
        let author = item.author
        let coverURL = BiliImageURL.resized(item.cover,
                                            pointSize: CGSize(width: 320, height: 320),
                                            quality: 90)
        playerItem.externalMetadata = Self.makeExternalMetadata(title: title,
                                                                author: author,
                                                                artworkData: nil)
        Task { [weak playerItem, title, author, coverURL] in
            guard let playerItem else { return }
            guard let artworkData = await PlayerArtworkStore.shared.load(from: coverURL) else { return }
            playerItem.externalMetadata = Self.makeExternalMetadata(title: title,
                                                                    author: author,
                                                                    artworkData: artworkData)
        }
    }

    private static func makeExternalMetadata(title: String,
                                             author: String,
                                             artworkData: Data?) -> [AVMetadataItem] {
        var metadata: [AVMetadataItem] = [
            makeTextMetadata(identifier: .commonIdentifierTitle, value: title),
        ]
        if !author.isEmpty {
            metadata.append(makeTextMetadata(identifier: .commonIdentifierArtist, value: author))
        }
        if let artworkData {
            metadata.append(makeBinaryMetadata(identifier: .commonIdentifierArtwork,
                                               value: artworkData as NSData,
                                               dataType: kCMMetadataBaseDataType_PNG as String))
        }
        return metadata
    }

    private static func makeTextMetadata(identifier: AVMetadataIdentifier,
                                         value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private static func makeBinaryMetadata(identifier: AVMetadataIdentifier,
                                           value: NSData,
                                           dataType: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.dataType = dataType
        return item
    }
}

@MainActor
private final class PlayerPlaybackCoordinator {
    static let shared = PlayerPlaybackCoordinator()

    private weak var active: PlayerViewModel?

    func activate(_ viewModel: PlayerViewModel) {
        if active !== viewModel {
            active?.pauseForDeactivation()
            active = viewModel
        }
    }

    func unregister(_ viewModel: PlayerViewModel) {
        if active === viewModel {
            active = nil
        }
    }
}

actor PlayerArtworkStore {
    static let shared = PlayerArtworkStore()

    private let cache = NSCache<NSURL, NSData>()

    func load(from urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        if let cached = cache.object(forKey: url as NSURL) {
            return cached as Data
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard let image = UIImage(data: data),
                  let pngData = image.pngData() else { return nil }
            cache.setObject(pngData as NSData, forKey: url as NSURL, cost: pngData.count)
            return pngData
        } catch {
            return nil
        }
    }
}

/// Hidden muted player used by fast-load while racing or preparing a
/// later low->high upgrade.
fileprivate struct WarmPlayer {
    let player: AVPlayer
    let preparation: EnginePreparation

    @MainActor
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        preparation.release()
    }
}

/// Result of racing the high-quality and low-quality warm-player tasks
/// during fast-load.
fileprivate enum FastLoadWinner {
    case hi(WarmPlayer)
    case lo(WarmPlayer)
}

/// Internal state for the race continuation. Tracks per-side errors so
/// we only resume the continuation as a throw once both sides have
/// failed.
fileprivate enum RaceState {
    case pending(hiError: Error?, loError: Error?)
    case resolved
}

/// Shared one-shot state for KVO-based readiness waits.
fileprivate enum ObservationState {
    case pending
    case resolved
}

fileprivate enum WarmPlayerError: Error {
    case unexpectedFailure
}

/// Drives the brief snapshot crossfade we run when the visible AVPlayer
/// instance is swapped (fast-load upgrade). Declared as a protocol so
/// the view-model can call into UIKit code without importing it as a
/// concrete type.
@MainActor
protocol PlayerSwapOverlay: AnyObject {
    /// Snapshot the current AVPlayerLayer contents, overlay them on the
    /// AVPlayerViewController, and schedule a fade-out. Idempotent: if
    /// a previous overlay is still fading we replace it.
    func beginCrossfade()
}

// MARK: - Orientation helpers

@MainActor
enum Orientation {
    /// App-level orientation gate for iPhone. Normal pages stay portrait;
    /// once the native AVKit fullscreen flow starts we temporarily widen
    /// the mask so the fullscreen controller can rotate to landscape.
    private static var phoneSupportedMask: UIInterfaceOrientationMask = .portrait

    static func supportedMask() -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? phoneSupportedMask : .all
    }

    /// Widen the phone orientation mask so AVKit is allowed to enter native
    /// fullscreen in landscape, but do not actively rotate the current page.
    /// This keeps the inline detail page upright while the fullscreen
    /// transition is still being negotiated.
    static func preparePhoneFullscreenLandscape() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        phoneSupportedMask = .allButUpsideDown
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        AppLog.debug("player", "放开手机横屏掩码，等待 AVKit 进入全屏", metadata: [
            "mask": interfaceOrientationMaskDescription(phoneSupportedMask),
        ])
    }

    /// Request a specific interface-orientation set from the active scene.
    /// On iOS 16+ this is the public API; pre-16 falls back to the legacy
    /// `UIDevice.orientation` setter.
    static func request(_ mask: UIInterfaceOrientationMask) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            phoneSupportedMask = mask == .portrait ? .portrait : .allButUpsideDown
        }
        requestWithoutMaskChange(mask)
    }

    /// Request a geometry update without changing the supported mask.
    /// Used when the mask has already been widened (e.g. by
    /// `preparePhoneFullscreenLandscape`) and we just need to
    /// trigger the rotation.
    static func requestWithoutMaskChange(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        if #available(iOS 16, *) {
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            AppLog.debug("player", "请求界面方向更新", metadata: [
                "requestedMask": interfaceOrientationMaskDescription(mask),
                "effectiveMask": interfaceOrientationMaskDescription(phoneSupportedMask),
            ])
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                AppLog.warning("player", "界面方向更新被系统拒绝", metadata: [
                    "requestedMask": interfaceOrientationMaskDescription(mask),
                    "error": error.localizedDescription,
                ])
            }
        } else {
            let value: UIDeviceOrientation
            switch mask {
            case .portrait:        value = .portrait
            case .landscapeLeft:   value = .landscapeRight
            case .landscapeRight:  value = .landscapeLeft
            case .landscape:       value = .landscapeLeft
            default:               value = .portrait
            }
            AppLog.debug("player", "使用旧版方式请求设备方向", metadata: [
                "requestedMask": interfaceOrientationMaskDescription(mask),
                "deviceOrientation": deviceOrientationDescription(value),
            ])
            UIDevice.current.setValue(value.rawValue, forKey: "orientation")
        }
    }
}

// MARK: - Player container (UIKit) hosting AVPlayerViewController + danmaku overlay

/// Wraps `AVPlayerViewController`. Critically, the danmaku overlay is mounted
/// inside `contentOverlayView`, which travels with the player into native
/// fullscreen — so danmaku stays visible there.
struct PlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let title: String
    let danmaku: DanmakuController
    let danmakuEnabled: Bool
    let danmakuOpacity: Double
    /// Called once, with the just-created AVPlayerViewController. Lets the
    /// SwiftUI parent drive native fullscreen entry/exit.
    let onCreated: (AVPlayerViewController) -> Void
    /// Called when the user taps AVKit's native fullscreen button (or our own).
    let onFullscreenChange: (Bool) -> Void
    /// Called once, after the AVPlayerViewController exists, with a
    /// handle the view-model uses to drive the swap crossfade.
    let onSwapOverlayReady: (PlayerSwapOverlay) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.loadViewIfNeeded()
        vc.player = player
        vc.title = title
        vc.updatesNowPlayingInfoCenter = true
        context.coordinator.assignedPlayerID = ObjectIdentifier(player)
        vc.delegate = context.coordinator
        DispatchQueue.main.async {
            onCreated(vc)
            onSwapOverlayReady(context.coordinator)
        }
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.videoGravity = .resizeAspect

        // Mount the danmaku host inside the contentOverlayView so it persists
        // when AVKit moves the player into fullscreen.
        let host = UIHostingController(rootView: DanmakuOverlay(
            controller: danmaku,
            opacity: danmakuEnabled ? danmakuOpacity : 0
        ))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        if let overlay = vc.contentOverlayView {
            overlay.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: overlay.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
        }
        context.coordinator.host = host
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        let incomingPlayerID = ObjectIdentifier(player)
        if vc.title != title {
            vc.title = title
        }
        // Reassign only when SwiftUI handed us a genuinely different
        // AVPlayer instance. During fullscreen transitions AVKit may
        // transiently nil out `vc.player`; we deliberately ignore that
        // path so the controller can restore its own player without us
        // restarting playback from zero. Fast-load promotion, however,
        // does intentionally swap to a new player identity.
        if context.coordinator.assignedPlayerID != incomingPlayerID {
            vc.player = player
            context.coordinator.assignedPlayerID = incomingPlayerID
        }
        // Push opacity changes through to the hosting controller.
        context.coordinator.host?.rootView = DanmakuOverlay(
            controller: danmaku,
            opacity: danmakuEnabled ? danmakuOpacity : 0
        )
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, PlayerSwapOverlay {
        var parent: PlayerContainer
        var host: UIHostingController<DanmakuOverlay>?
        var assignedPlayerID: ObjectIdentifier?
        /// Most recent in-flight crossfade overlay. Held weakly so we
        /// don't extend its life past `removeFromSuperview`.
        weak var activeCrossfade: UIView?
        private var rateBeforeTransition: Float = 1.0
        private var wasPlayingBeforeTransition = false
        private var preTransitionRate: Float?
        private var preTransitionWasPlaying: Bool?
        init(parent: PlayerContainer) { self.parent = parent }

        func prepareForFullscreenTransition(player: AVPlayer?) {
            guard let player else { return }
            preTransitionWasPlaying = player.timeControlStatus == .playing || player.rate > 0
            let activeRate = player.rate
            let defaultRate = player.defaultRate
            preTransitionRate = activeRate > 0 ? activeRate : (defaultRate > 0 ? defaultRate : 1.0)
        }

        // MARK: PlayerSwapOverlay

        func beginCrossfade() {
            // The AVPlayerViewController itself isn't reachable from
            // here, but its `contentOverlayView` lives on the
            // hosting controller's superview chain. We snapshot via
            // `view.snapshotView(afterScreenUpdates:)` which captures
            // AVPlayerLayer contents on iOS 16+.
            guard let host,
                  let containerView = host.view.superview?.superview ?? host.view.superview
            else { return }
            // Drop any stale crossfade still on screen.
            activeCrossfade?.removeFromSuperview()
            guard let snapshot = containerView.snapshotView(afterScreenUpdates: false) else {
                return
            }
            snapshot.frame = containerView.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshot.isUserInteractionEnabled = false
            containerView.addSubview(snapshot)
            activeCrossfade = snapshot
            // Hold the snapshot opaque for one runloop tick so AVKit's
            // black-frame transition is fully covered, then fade.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak snapshot] in
                guard let snapshot, snapshot.superview != nil else { return }
                UIView.animate(withDuration: 0.22,
                               delay: 0,
                               options: [.curveEaseOut, .allowUserInteraction],
                               animations: { snapshot.alpha = 0 },
                               completion: { _ in snapshot.removeFromSuperview() })
            }
        }

        // MARK: AVPlayerViewControllerDelegate

        func playerViewController(_ vc: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            capturePlaybackState(from: vc)
            let currentDeviceOrientation = UIDevice.current.orientation
            AppLog.info("player", "AVKit 即将进入全屏", metadata: [
                "deviceOrientation": deviceOrientationDescription(currentDeviceOrientation),
                "supportedMask": interfaceOrientationMaskDescription(Orientation.supportedMask()),
                "rate": String(rateBeforeTransition),
                "playing": String(wasPlayingBeforeTransition),
            ])
            parent.onFullscreenChange(true)
            let targetMask: UIInterfaceOrientationMask = currentDeviceOrientation == .landscapeRight
                ? .landscapeLeft : .landscapeRight
            Orientation.requestWithoutMaskChange(targetMask)
            coordinator.animate(alongsideTransition: nil) { [weak self, weak vc] _ in
                guard let self, let vc else { return }
                self.restorePlaybackState(on: vc)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak vc] in
                    guard let self, let vc else { return }
                    self.restorePlaybackState(on: vc)
                }
            }
        }
        func playerViewController(_ vc: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            capturePlaybackState(from: vc)
            AppLog.info("player", "AVKit 即将退出全屏", metadata: [
                "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
                "supportedMask": interfaceOrientationMaskDescription(Orientation.supportedMask()),
                "rate": String(rateBeforeTransition),
                "playing": String(wasPlayingBeforeTransition),
            ])
            coordinator.animate(alongsideTransition: nil) { [weak self, weak vc] _ in
                guard let self, let vc else { return }
                self.parent.onFullscreenChange(false)
                Orientation.request(.portrait)
                self.restorePlaybackState(on: vc)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak vc] in
                    guard let self, let vc else { return }
                    self.restorePlaybackState(on: vc)
                }
            }
        }

        private func capturePlaybackState(from vc: AVPlayerViewController) {
            if let pre = preTransitionWasPlaying {
                wasPlayingBeforeTransition = pre
                rateBeforeTransition = preTransitionRate ?? 1.0
                preTransitionWasPlaying = nil
                preTransitionRate = nil
            } else {
                wasPlayingBeforeTransition = vc.player?.timeControlStatus == .playing || (vc.player?.rate ?? 0) > 0
                let defaultRate = vc.player?.defaultRate ?? 0
                let activeRate = vc.player?.rate ?? 0
                rateBeforeTransition = activeRate > 0 ? activeRate : (defaultRate > 0 ? defaultRate : 1.0)
            }
        }

        private func restorePlaybackState(on vc: AVPlayerViewController) {
            guard wasPlayingBeforeTransition, let player = vc.player else { return }
            player.playImmediately(atRate: rateBeforeTransition)
        }
    }
}

// MARK: - Player view

struct PlayerView: View {
    let item: FeedItemDTO
    @StateObject private var vm = PlayerViewModel()
    /// Plain reference type — see `DanmakuController` notes.
    @State private var danmaku = DanmakuController()
    @State private var didBootstrap = false
    @State private var isFullscreen = false
    @State private var lastDeviceOrientation: UIDeviceOrientation = .portrait
    /// Weak handle to the AVPlayerViewController so we can drive native FS.
    @State private var playerVCRef = PlayerVCBox()
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    private let orientationPublisher = NotificationCenter.default
        .publisher(for: UIDevice.orientationDidChangeNotification)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let p = vm.player {
                    PlayerContainer(
                        player: p,
                        title: item.title,
                        danmaku: danmaku,
                        danmakuEnabled: settings.danmakuEnabled,
                        danmakuOpacity: settings.danmakuOpacity,
                        onCreated: { vc in playerVCRef.vc = vc },
                        onFullscreenChange: { fs in isFullscreen = fs },
                        onSwapOverlayReady: { overlay in vm.playerSwapOverlay = overlay }
                    )
                    // Cover the native chrome until the first frame is
                    // ready, otherwise users see a misleading pause icon
                    // hovering over a black surface during buffering.
                    if !vm.isVideoReady {
                        Color.black.opacity(0.85)
                        ProgressView().tint(.white)
                    }
                } else if vm.isLoading {
                    ProgressView().tint(.white)
                } else if let err = vm.errorText {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                            .foregroundStyle(.yellow)
                        Text(err).foregroundStyle(.white).multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
            .aspectRatio(16.0/9.0, contentMode: .fit)

            controlBar

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.headline)
                    Text(item.author).font(.subheadline).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("AV", value: String(item.aid))
                    LabeledContent("BV", value: item.bvid)
                    LabeledContent("CID", value: String(item.cid))
                }
                .padding()
            }
        }
        .navigationTitle("播放")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            configureAudioSession()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            // Run the video preparation and the danmaku fetch concurrently
            // so a slow danmaku endpoint can never hold up first frame.
            async let video: Void = vm.load(item: item,
                                            preferredQn: Int64(settings.resolvedPreferredVideoQn()),
                                            preferredAudioQn: Int64(settings.preferredAudioQn),
                                            fastLoad: settings.fastLoad)
            async let danmaku: Void = loadDanmaku()
            _ = await (video, danmaku)
            vm.activatePlayback()
        }
        .onChange(of: vm.player) { newPlayer in
            if let p = newPlayer {
                danmaku.attach(p)
                vm.activatePlayback()
            }
        }
        .onChange(of: scenePhase) { phase in
            // When the app returns to the foreground after a long lock
            // the local proxy may have been killed by iOS (Network
            // framework cancels listeners on suspended apps). Rebuild
            // the AVPlayerItem against a freshly-bound port so playback
            // does not silently fail with "could not load resource".
            guard phase == .active, didBootstrap, vm.player != nil else { return }
            if !vm.isEngineAlive {
                Task { await vm.reload() }
            }
        }
        .onReceive(orientationPublisher) { _ in
            handleDeviceOrientationChange()
        }
        .onAppear {
            if didBootstrap {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                vm.activatePlayback()
                if let p = vm.player { danmaku.attach(p) }
            }
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            if !isFullscreen {
                vm.pauseForDeactivation()
                Orientation.request(.portrait)
            }
        }
    }

    @ViewBuilder
    private var controlBar: some View {
        HStack(spacing: 10) {
            if !vm.availableQualities.isEmpty {
                Menu {
                    ForEach(vm.availableQualities, id: \.qn) { q in
                        Button {
                            Task {
                                await vm.switchQuality(to: q.qn)
                            }
                        } label: {
                            if q.qn == vm.currentQn {
                                Label(q.label, systemImage: "checkmark")
                            } else {
                                Text(q.label)
                            }
                        }
                    }
                } label: { chip(icon: "slider.horizontal.3", text: currentQualityLabel) }
            }

            if !vm.availableAudioQualities.isEmpty {
                Menu {
                    ForEach(vm.availableAudioQualities, id: \.qn) { q in
                        Button {
                            Task {
                                await vm.switchAudioQuality(to: q.qn)
                            }
                        } label: {
                            if q.qn == vm.currentAudioQn {
                                Label(q.label, systemImage: "checkmark")
                            } else {
                                Text(q.label)
                            }
                        }
                    }
                } label: { chip(icon: "hifispeaker", text: currentAudioQualityLabel) }
            }

            Button {
                settings.danmakuEnabled.toggle()
            } label: {
                chip(icon: settings.danmakuEnabled ? "captions.bubble.fill" : "captions.bubble",
                     text: settings.danmakuEnabled ? "弹幕" : "弹幕关")
            }

            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .contentShape(Capsule())
    }

    private var currentQualityLabel: String {
        vm.availableQualities.first { $0.qn == vm.currentQn }?.label ?? "清晰度"
    }

    private var currentAudioQualityLabel: String {
        vm.availableAudioQualities.first { $0.qn == vm.currentAudioQn }?.label ?? "音质"
    }

    private func loadDanmaku() async {
        AppLog.info("danmaku", "开始加载弹幕", metadata: [
            "cid": String(item.cid),
        ])
        do {
            let track = try await Task.detached { [cid = item.cid] in
                try CoreClient.shared.danmakuList(cid: cid)
            }.value
            danmaku.setItems(track.items)
            if let p = vm.player { danmaku.attach(p) }
            AppLog.info("danmaku", "弹幕加载完成", metadata: [
                "cid": String(item.cid),
                "count": String(track.items.count),
            ])
        } catch {
            AppLog.error("danmaku", "弹幕加载失败", error: error, metadata: [
                "cid": String(item.cid),
            ])
        }
    }

    /// Configure the shared audio session for video playback.
    ///
    /// `.playback` + `.moviePlayback` keeps audio playing when the screen
    /// locks (combined with the `audio` `UIBackgroundModes` entry in
    /// Info.plist), and `setActive(true)` is required so AVPlayer keeps
    /// pulling bytes from the local HLS proxy after the app goes to
    /// background — without it the in-process URLSession is throttled and
    /// playback stalls on the lock screen.
    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .moviePlayback, options: [])
            try s.setActive(true, options: [])
        } catch {
            AppLog.warning("player", "音频会话配置失败", metadata: [
                "error": error.localizedDescription,
            ])
        }
    }

    // MARK: - Fullscreen / orientation

    /// Enter native fullscreen and rotate to landscape. Uses AVKit's private
    /// transition selector — this is widely used in shipping apps and works
    /// reliably across iOS 14–17. Since this app isn't going through App
    /// Review, that's fine.
    private func enterFullscreen() {
        guard !isFullscreen else {
            AppLog.debug("player", "忽略自动进全屏：已经处于全屏状态", metadata: [
                "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
            ])
            return
        }
        guard let vc = playerVCRef.vc else {
            AppLog.warning("player", "自动进全屏失败：AVPlayerViewController 引用为空", metadata: [
                "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
                "lastDeviceOrientation": deviceOrientationDescription(lastDeviceOrientation),
            ])
            return
        }
        let supportedSelectors = fullscreenSelectorSupportDescription(on: vc, selectorNames: fullscreenEnterSelectorCandidates)
        guard let selectorName = firstSupportedFullscreenSelector(on: vc, selectorNames: fullscreenEnterSelectorCandidates) else {
            AppLog.warning("player", "自动进全屏失败：没有可用的 fullscreen selector", metadata: [
                "supportedSelectors": supportedSelectors,
                "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
                "lastDeviceOrientation": deviceOrientationDescription(lastDeviceOrientation),
            ])
            return
        }
        let sel = NSSelectorFromString(selectorName)
        Orientation.preparePhoneFullscreenLandscape()
        isFullscreen = true
        if let coordinator = playerVCRef.vc?.delegate as? PlayerContainer.Coordinator {
            coordinator.prepareForFullscreenTransition(player: vm.player)
        }
        let deviceOrientation = UIDevice.current.orientation
        let targetLandscapeMask: UIInterfaceOrientationMask = deviceOrientation == .landscapeRight
            ? .landscapeLeft : .landscapeRight
        Orientation.requestWithoutMaskChange(targetLandscapeMask)
        AppLog.info("player", "请求进入全屏", metadata: [
            "aid": String(item.aid),
            "cid": String(item.cid),
            "selector": selectorName,
            "supportedSelectors": supportedSelectors,
            "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
            "lastDeviceOrientation": deviceOrientationDescription(lastDeviceOrientation),
            "supportedMask": interfaceOrientationMaskDescription(Orientation.supportedMask()),
        ])
        vc.perform(sel, with: true, with: nil)
    }

    private func exitFullscreen() {
        guard isFullscreen else {
            AppLog.debug("player", "忽略自动退全屏：当前不在全屏", metadata: [
                "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
            ])
            return
        }
        isFullscreen = false
        guard let vc = playerVCRef.vc else {
            AppLog.warning("player", "自动退全屏失败：AVPlayerViewController 引用为空", metadata: [
                "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
            ])
            return
        }
        let supportedSelectors = fullscreenSelectorSupportDescription(on: vc, selectorNames: fullscreenExitSelectorCandidates)
        guard let selectorName = firstSupportedFullscreenSelector(on: vc, selectorNames: fullscreenExitSelectorCandidates) else {
            AppLog.warning("player", "自动退全屏失败：没有可用的 fullscreen selector", metadata: [
                "supportedSelectors": supportedSelectors,
                "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
            ])
            return
        }
        let sel = NSSelectorFromString(selectorName)
        AppLog.info("player", "请求退出全屏", metadata: [
            "aid": String(item.aid),
            "cid": String(item.cid),
            "selector": selectorName,
            "supportedSelectors": supportedSelectors,
            "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
            "supportedMask": interfaceOrientationMaskDescription(Orientation.supportedMask()),
        ])
        vc.perform(sel, with: true, with: nil)
    }

    private func handleDeviceOrientationChange() {
        let o = UIDevice.current.orientation
        AppLog.debug("player", "收到设备方向变化", metadata: [
            "deviceOrientation": deviceOrientationDescription(o),
            "lastDeviceOrientation": deviceOrientationDescription(lastDeviceOrientation),
            "isFullscreen": String(isFullscreen),
            "autoRotateFullscreen": String(settings.autoRotateFullscreen),
            "idiom": UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "pad",
        ])
        guard settings.autoRotateFullscreen else {
            AppLog.debug("player", "忽略设备方向变化：自动全屏已关闭")
            return
        }
        // iPad: skip the auto rotate-into-fullscreen behaviour. iPads
        // are commonly used in landscape as the default reading
        // orientation, so flipping the player into fullscreen on every
        // rotation would be more annoying than useful. The native
        // fullscreen button still works.
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            AppLog.debug("player", "忽略设备方向变化：当前设备不是手机")
            return
        }
        guard o != lastDeviceOrientation else {
            AppLog.debug("player", "忽略设备方向变化：与上次方向相同", metadata: [
                "deviceOrientation": deviceOrientationDescription(o),
            ])
            return
        }
        defer { lastDeviceOrientation = o }
        if o.isLandscape, !isFullscreen {
            enterFullscreen()
        } else if o == .portrait, isFullscreen {
            exitFullscreen()
        } else {
            AppLog.debug("player", "设备方向变化未触发全屏切换", metadata: [
                "deviceOrientation": deviceOrientationDescription(o),
                "isLandscape": String(o.isLandscape),
                "isFullscreen": String(isFullscreen),
            ])
        }
    }
}

// MARK: - PlayerVC handle

fileprivate let fullscreenEnterSelectorCandidates = [
    "enterFullScreenAnimated:completion:",
    "enterFullScreenAnimated:completionHandler:",
    "enterFullscreenAnimated:completion:",
    "enterFullscreenAnimated:completionHandler:",
]

fileprivate let fullscreenExitSelectorCandidates = [
    "exitFullScreenAnimated:completion:",
    "exitFullScreenAnimated:completionHandler:",
    "exitFullscreenAnimated:completion:",
    "exitFullscreenAnimated:completionHandler:",
]

fileprivate func fullscreenSelectorSupportDescription(on vc: NSObject, selectorNames: [String]) -> String {
    selectorNames.map { name in
        let supported = vc.responds(to: NSSelectorFromString(name))
        return "\(name)=\(supported ? "yes" : "no")"
    }.joined(separator: ",")
}

fileprivate func firstSupportedFullscreenSelector(on vc: NSObject, selectorNames: [String]) -> String? {
    selectorNames.first { vc.responds(to: NSSelectorFromString($0)) }
}

fileprivate func deviceOrientationDescription(_ orientation: UIDeviceOrientation) -> String {
    switch orientation {
    case .unknown: return "unknown"
    case .portrait: return "portrait"
    case .portraitUpsideDown: return "portraitUpsideDown"
    case .landscapeLeft: return "landscapeLeft"
    case .landscapeRight: return "landscapeRight"
    case .faceUp: return "faceUp"
    case .faceDown: return "faceDown"
    @unknown default: return "future(\(orientation.rawValue))"
    }
}

fileprivate func interfaceOrientationMaskDescription(_ mask: UIInterfaceOrientationMask) -> String {
    if mask == .portrait { return "portrait" }
    if mask == .landscape { return "landscape" }
    if mask == .allButUpsideDown { return "allButUpsideDown" }
    if mask == .all { return "all" }
    if mask == .portraitUpsideDown { return "portraitUpsideDown" }
    if mask == .landscapeLeft { return "landscapeLeft" }
    if mask == .landscapeRight { return "landscapeRight" }
    return "raw(\(mask.rawValue))"
}

final class PlayerVCBox {
    weak var vc: AVPlayerViewController?
}

