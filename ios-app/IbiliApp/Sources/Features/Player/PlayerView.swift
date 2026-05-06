import SwiftUI
import AVKit
import AVFoundation
import UIKit
import os

private func resolvePlayableItemIfNeeded(_ item: FeedItemDTO) async throws -> FeedItemDTO {
    guard item.cid == 0 else { return item }
    let resolvedCid: Int64 = try await Task.detached(priority: .userInitiated) {
        try CoreClient.shared.videoViewCid(bvid: item.bvid)
    }.value
    return FeedItemDTO(
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
}

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
    @Published private(set) var prefersLandscapeFullscreen = true
    @Published var rate: Float = 1.0 { didSet { applyRate() } }
    @Published private(set) var isTemporarySpeedBoostActive = false
    private let holdSpeedRate: Float = 2.0
    private var temporaryPlaybackRateOverride: Float?
    /// Linear `AVPlayer.volume` value derived from the user's
    /// `audioGainDb` setting. Updated from SwiftUI via
    /// ``setAudioVolumeLinear(_:)`` and applied to the active
    /// AVPlayer (and any subsequently-attached one).
    private var audioVolumeLinear: Float = 1.0
    /// Lightweight handle the SwiftUI player container hands us so we
    /// can drive a snapshot crossfade across an AVPlayer identity swap
    /// without forcing the view-model to know about UIKit views.
    weak var playerSwapOverlay: PlayerSwapOverlay?

    private var aid: Int64 = 0
    private var cid: Int64 = 0
    /// Public read-only accessors so views (e.g. the danmaku-send sheet)
    /// can grab the currently-playing identifiers without having to
    /// thread `(aid, cid)` through every state binding.
    var currentAid: Int64 { aid }
    var currentCid: Int64 { cid }
    private var loadGeneration: UInt64 = 0
    private let discoveryQn: Int64 = 120
    private let engine: PlaybackEngine = HLSProxyEngine.shared
    let pageCache = PlayerPageSessionCache()
    /// Server-recorded resume position for the *current* (aid,cid).
    /// Captured from `playurl.last_play_time_ms` and consumed once when
    /// the AVPlayerItem first reaches `.readyToPlay` so we don't fight
    /// AVPlayer's own initial seek behaviour.
    private var pendingResumeMs: Int64 = 0
    /// Snapshot of the current bvid so the heartbeat call carries the
    /// same identifier upstream PiliPlus uses (`bvid` for ugc).
    private var bvid: String = ""
    /// Periodic time observer token driving heartbeat reports.
    private var heartbeatObserverToken: Any?
    /// End-of-item observer token that sends the terminal heartbeat.
    private var playbackEndObserverToken: NSObjectProtocol?
    /// Last reported playhead second — heartbeat skips repeats so we
    /// don't spam the API when paused.
    private var lastHeartbeatSec: Int64 = -1
    private var itemStatusObservation: NSKeyValueObservation?
    /// Snapshot of the most recent `load(...)` arguments, used by
    /// `reload()` to recover after the local proxy has been killed by
    /// iOS in the background.
    private var lastLoadedItem: FeedItemDTO?
    private var lastPreferredQn: Int64 = 0
    private var lastPreferredAudioQn: Int64 = 0
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
    private let sessionID: PlayerSessionID
    private var behaviorState = PlayerSessionBehaviorState()
    private var playerTimeControlObservation: NSKeyValueObservation?
    private var isPlaybackCompleted = false
    private var isRecoveringPlaybackFromPageCache = false

    init(sessionID: PlayerSessionID = PlayerSessionID()) {
        self.sessionID = sessionID
    }

    deinit {
        MainActor.assumeIsolated {
            PlayerPlaybackCoordinator.shared.unregister(self)
            PlayerNowPlayingCoordinator.shared.unregister(self)
            PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: self)
            player?.pause()
            stopHeartbeat()
            itemStatusObservation = nil
            playerTimeControlObservation?.invalidate()
            playerTimeControlObservation = nil
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
        do {
            item = try await resolvePlayableItemIfNeeded(item)
        } catch {
            isLoading = false
            errorText = "无法解析视频信息: \((error as NSError).localizedDescription)"
            return
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
        bvid = item.bvid
        lastLoadedItem = item
        lastPreferredQn = preferredQn
        lastPreferredAudioQn = preferredAudioQn
        lastFastLoad = fastLoad
        autoReloadAttempts = 0
        if !isSameVideo {
            blockedQns.removeAll()
            pageCache.clearMediaData()
            stopHeartbeat()
            cancelPendingUpgrade()
            // Switching to a different video/part inside the same
            // route should always auto-play the replacement source.
            // Do this before we tear the old player down so the audio
            // session stays claimed across the hand-off and stale
            // `.paused` callbacks from the outgoing player cannot
            // permanently flip the new source into a non-playing
            // intent.
            handle(.prepareAutoplayForMediaReplacement)
            PlayerAudioSessionCoordinator.shared.setSessionNeeded(shouldHoldAudioSession, by: self)
            // Replacing the media inside the same player route (分 P /
            // 合集切换 uses `replaceCurrent`) must tear the outgoing
            // source down immediately. Otherwise the old AVPlayerItem
            // keeps its audio/render pipeline alive while we fetch and
            // prepare the next source, producing overlapping audio.
            // Keep the logical playback intent as `.play` so the audio
            // session stays claimed throughout the hand-off.
            resetCurrentPlaybackForMediaSwitch()
        }
        isPlaybackCompleted = false
        if preferredAudioQn > 0 { currentAudioQn = preferredAudioQn }
        isLoading = true; errorText = nil; isVideoReady = false
        itemStatusObservation = nil
        if isSameVideo {
            stopHeartbeat()
            cancelPendingUpgrade()
        }
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
                rememberPlayURL(warm)
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
                rememberPlayURL(warm)
            } else {
                info = try await fetchPlayUrl(aid: item.aid,
                                              cid: item.cid,
                                              qn: targetQn)
            }
            guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else { return }
            let finalQualities = normalizedQualities(from: info).isEmpty ? qualities : normalizedQualities(from: info)
            self.availableQualities = finalQualities
            rememberPlayURL(info)
            self.availableAudioQualities = normalizedAudioQualities(from: info)
            self.currentAudioQn = info.audioQuality
            // Capture server-recorded resume position. Treated as a
            // single-shot — `observeItemStatus` consumes it on the
            // first `.readyToPlay`, then zeroes the field so future
            // quality switches don't re-seek backward.
            self.pendingResumeMs = info.lastPlayTimeMs

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
                    rememberPlayURL(warm)
                } else {
                    loInfo = try await fetchPlayUrl(aid: item.aid,
                                                    cid: item.cid,
                                                    qn: lowestQn)
                }
                guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else { return }
                rememberPlayURL(loInfo)
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
                self.prefersLandscapeFullscreen = Self.prefersLandscapeFullscreen(for: info)
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
                setPlayer(player)
                applyPlaybackIntent(to: player)
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
        stopHeartbeat()
        suppressNextObservedPlaybackIntent(.pause)
        player?.pause()
        setPlayer(nil)
        itemStatusObservation = nil
        activePreparation?.release()
        activePreparation = nil
        cancelPendingUpgrade()
        aid = 0; cid = 0
        await load(item: item,
               preferredQn: lastPreferredQn,
               preferredAudioQn: lastPreferredAudioQn,
               fastLoad: lastFastLoad)
        // `load(...)` zeroes the counter; preserve our caller's tally
        // so a chain of failed reloads cannot loop indefinitely.
        autoReloadAttempts = max(autoReloadAttempts, priorAttempts)
    }

    /// Whether the engine still owns a live proxy stream. False after
    /// iOS suspends the app long enough to kill the listener.
    var isEngineAlive: Bool { HLSProxyEngine.shared.isAlive }

    func handle(_ event: PlayerSessionEvent) {
        switch event {
        case .interfaceActivated:
            PlayerPlaybackCoordinator.shared.activate(self)
            PlayerNowPlayingCoordinator.shared.activate(self)
        case .pictureInPictureChanged(let isActive):
            if isActive {
                endTemporarySpeedBoost()
                PlayerPlaybackCoordinator.shared.activate(self)
                PlayerNowPlayingCoordinator.shared.activate(self)
            }
        case .playbackIntentChanged(.pause):
            endTemporarySpeedBoost()
        case .observedTimeControlStatus(.paused):
            endTemporarySpeedBoost()
        case .interfaceDeactivated,
             .playbackIntentChanged(.play),
             .prepareAutoplayForMediaReplacement,
             .suppressNextObservedIntent,
             .observedTimeControlStatus:
            break
        }

        guard behaviorState.apply(event) else { return }

        switch event {
        case .interfaceActivated, .interfaceDeactivated, .pictureInPictureChanged, .playbackIntentChanged:
            applyPlaybackIntent()
            PlayerNowPlayingCoordinator.shared.refresh(for: self)
        case .observedTimeControlStatus:
            PlayerAudioSessionCoordinator.shared.setSessionNeeded(shouldHoldAudioSession, by: self)
            PlayerNowPlayingCoordinator.shared.refresh(for: self)
        case .prepareAutoplayForMediaReplacement, .suppressNextObservedIntent:
            break
        }
    }

    var nowPlayingMetadata: PlayerNowPlayingMetadata? {
        guard let item = lastLoadedItem else { return nil }
        return PlayerNowPlayingMetadata(
            title: item.title,
            artist: item.author,
            artworkURL: BiliImageURL.resized(item.cover,
                                             pointSize: CGSize(width: 320, height: 320),
                                             quality: 90),
            duration: item.durationSec > 0 ? TimeInterval(item.durationSec) : nil
        )
    }

    var currentFeedItem: FeedItemDTO? {
        lastLoadedItem
    }

    var currentSessionID: PlayerSessionID {
        sessionID
    }

    var shouldExposeSystemMediaSession: Bool {
        guard player != nil, nowPlayingMetadata != nil else { return false }
        if behaviorState.isInterfacePresentingPlayer {
            return true
        }
        return !isPlaybackCompleted
    }

    var systemMediaSessionDebugMetadata: [String: String] {
        [
            "aid": String(currentAid),
            "cid": String(currentCid),
            "hasPlayer": String(player != nil),
            "isPresentationActive": String(behaviorState.isInterfacePresentingPlayer),
            "isPlaybackCompleted": String(isPlaybackCompleted),
            "playbackRate": String(systemMediaPlaybackRate),
        ]
    }

    var currentElapsedPlaybackTime: TimeInterval? {
        guard let seconds = player?.currentTime().seconds,
              seconds.isFinite,
              seconds >= 0 else {
            return nil
        }
        return seconds
    }

    var systemMediaPlaybackRate: Float {
        guard let player else { return 0 }
        if player.timeControlStatus == .paused, player.rate == 0 {
            return 0
        }
        let resolvedRate = desiredPlaybackRate > 0 ? desiredPlaybackRate : player.rate
        return resolvedRate > 0 ? resolvedRate : 1.0
    }

    var systemMediaDefaultRate: Float {
        let resolvedRate = desiredPlaybackRate > 0 ? desiredPlaybackRate : rate
        return resolvedRate > 0 ? resolvedRate : 1.0
    }

    func refreshSystemMediaSession() {
        PlayerNowPlayingCoordinator.shared.refresh(for: self)
    }

    func handleRemotePlaybackIntent(_ intent: PlayerIntent) {
        switch intent {
        case .pause:
            handle(.playbackIntentChanged(.pause))
        case .play:
            Task { @MainActor in
                self.isPlaybackCompleted = false
                self.handle(.playbackIntentChanged(.play))
                guard !self.isEngineAlive else { return }
                if await self.recoverPlaybackFromPageCacheIfPossible(trigger: "system-remote-play") {
                    return
                }
                await self.reload()
            }
        }
    }

    func recoverFromInactiveEngineIfNeeded(trigger: String) async {
        guard !isEngineAlive else { return }
        if await recoverPlaybackFromPageCacheIfPossible(trigger: trigger) {
            return
        }
        await reload()
    }

    /// Read-only flag mirroring the internal PiP state. Used by the
    /// view-side scene-phase recovery to decide whether returning to
    /// the foreground should auto-collapse the PiP floating window
    /// (only the originating session has this set).
    var isPictureInPictureActive: Bool { behaviorState.pictureInPictureIsActive }

    func backgroundContinuationRate(for player: AVPlayer) -> Float? {
        behaviorState.backgroundContinuationRate(currentRate: player.rate,
                                                desiredRate: desiredPlaybackRate)
    }

    func reapplyPlaybackBehavior(to targetPlayer: AVPlayer? = nil) {
        applyPlaybackIntent(to: targetPlayer)
    }

    var canBeginTemporarySpeedBoost: Bool {
        guard let player else { return false }
        return player.timeControlStatus == .playing || player.rate > 0
    }

    @discardableResult
    func beginTemporarySpeedBoost() -> Bool {
        guard canBeginTemporarySpeedBoost else { return false }
        guard temporaryPlaybackRateOverride != holdSpeedRate else { return true }
        temporaryPlaybackRateOverride = holdSpeedRate
        isTemporarySpeedBoostActive = true
        applyRate()
        return true
    }

    func endTemporarySpeedBoost(on targetPlayer: AVPlayer? = nil) {
        guard temporaryPlaybackRateOverride != nil || isTemporarySpeedBoostActive else { return }
        temporaryPlaybackRateOverride = nil
        isTemporarySpeedBoostActive = false
        applyRate(to: targetPlayer)
    }

    /// Sets the global player gain (linear multiplier). Idempotent.
    /// SwiftUI calls this whenever ``AppSettings.audioGainDb`` changes
    /// or a fresh AVPlayer is mounted.
    func setAudioVolumeLinear(_ linear: Float) {
        let clamped = min(max(linear, 0), 1)
        guard audioVolumeLinear != clamped else { return }
        audioVolumeLinear = clamped
        player?.volume = clamped
    }

    func switchQuality(to qn: Int64) async {
        guard let player else { return }
        let generation = loadGeneration
        let resumeAt = player.currentTime()
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
            suppressNextObservedPlaybackIntent(.pause)
            player.pause()
            endTemporarySpeedBoost(on: player)
            player.replaceCurrentItem(with: nil)
            activePreparation?.release()
            activePreparation = nil
            // Releasing the previous source before allocating the new
            // one keeps the proxy token table from growing across
            // switches without tearing down other tab's retained players.
            let info = try await fetchPlayUrl(aid: aid, cid: cid, qn: qn)
            rememberPlayURL(info)
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
            applyRate(to: player)
            applyPlaybackIntent(to: player)
            self.availableQualities = normalizedQualities(from: info)
            self.currentQn = info.quality
            self.availableAudioQualities = normalizedAudioQualities(from: info)
            self.currentAudioQn = info.audioQuality
            self.prefersLandscapeFullscreen = Self.prefersLandscapeFullscreen(for: info)
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
        PlayerNowPlayingCoordinator.shared.unregister(self)
        loadGeneration &+= 1
        AppLog.debug("player", "销毁播放器", metadata: [
            "aid": String(aid),
            "cid": String(cid),
        ])
        stopHeartbeat()
        suppressNextObservedPlaybackIntent(.pause)
        player?.pause()
        setPlayer(nil)
        itemStatusObservation = nil
        activePreparation?.release()
        activePreparation = nil
        cancelPendingUpgrade()
        pageCache.clearMediaData()
        behaviorState = PlayerSessionBehaviorState()
        isPlaybackCompleted = false
        isVideoReady = false
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

    private static func prefersLandscapeFullscreen(for source: PlayUrlDTO) -> Bool {
        guard let width = source.videoWidth,
              let height = source.videoHeight,
              width > 0,
              height > 0 else {
            return true
        }
        return width >= height
    }

    private var shouldHoldAudioSession: Bool {
        behaviorState.shouldHoldAudioSession
    }

    private func resetCurrentPlaybackForMediaSwitch() {
        itemStatusObservation = nil
        guard let player else { return }
        playerTimeControlObservation?.invalidate()
        playerTimeControlObservation = nil
        suppressNextObservedPlaybackIntent(.pause)
        player.pause()
        endTemporarySpeedBoost(on: player)
        // Match the proven-safe quality-switch ordering: detach the
        // old AVPlayerItem before releasing the proxy/source behind
        // it, otherwise the still-bound item can observe a torn-down
        // backing stream during same-route media replacement.
        player.replaceCurrentItem(with: nil)
        activePreparation?.release()
        activePreparation = nil
    }

    private func setPlayer(_ newPlayer: AVPlayer?) {
        playerTimeControlObservation?.invalidate()
        playerTimeControlObservation = nil
        if newPlayer == nil {
            temporaryPlaybackRateOverride = nil
            isTemporarySpeedBoostActive = false
        } else {
            isPlaybackCompleted = false
        }
        player = newPlayer
        if let newPlayer {
            newPlayer.volume = audioVolumeLinear
            observePlayerTimeControl(newPlayer)
            applyRate(to: newPlayer)
            PlayerNowPlayingCoordinator.shared.refresh(for: self)
        } else {
            PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: self)
            PlayerNowPlayingCoordinator.shared.refresh(for: self)
        }
    }

    private func observePlayerTimeControl(_ player: AVPlayer) {
        playerTimeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.handleObservedPlaybackState(player.timeControlStatus)
            }
        }
    }

    private func handleObservedPlaybackState(_ status: AVPlayer.TimeControlStatus) {
        handle(.observedTimeControlStatus(status))
    }

    private func applyPlaybackIntent(to targetPlayer: AVPlayer? = nil) {
        PlayerAudioSessionCoordinator.shared.setSessionNeeded(shouldHoldAudioSession, by: self)
        guard let targetPlayer = targetPlayer ?? player else { return }
        switch behaviorState.desiredPlaybackCommand(rate: desiredPlaybackRate) {
        case .play(let rate):
            suppressNextObservedPlaybackIntent(.play)
            targetPlayer.playImmediately(atRate: rate)
        case .pause:
            suppressNextObservedPlaybackIntent(.pause)
            targetPlayer.pause()
            endTemporarySpeedBoost(on: targetPlayer)
        }
    }

    private func suppressNextObservedPlaybackIntent(_ intent: PlayerIntent) {
        handle(.suppressNextObservedIntent(intent))
    }

    private var basePlaybackRate: Float {
        rate > 0 ? rate : 1.0
    }

    private var desiredPlaybackRate: Float {
        temporaryPlaybackRateOverride ?? basePlaybackRate
    }

    /// Install a periodic time observer that reports the playhead to
    /// Bilibili every ~15 seconds plus on natural completion. Mirrors
    /// PiliPlus' `makeHeartBeat(type: .status / .completed)` cadence
    /// — that's how the cloud "history / 继续观看" works.
    private func startHeartbeatIfNeeded() {
        guard let player, heartbeatObserverToken == nil else { return }
        let interval = CMTime(seconds: 15, preferredTimescale: 1)
        let aidSnap = aid
        let bvidSnap = bvid
        let cidSnap = cid
        heartbeatObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            guard let self else { return }
            // Only beat while actually playing — paused users don't
            // want their saved position racing forward.
            guard self.player?.timeControlStatus == .playing else { return }
            let sec = Int64(CMTimeGetSeconds(time))
            guard sec >= 0, sec != self.lastHeartbeatSec else { return }
            self.lastHeartbeatSec = sec
            Task.detached(priority: .background) {
                try? CoreClient.shared.archiveHeartbeat(
                    aid: aidSnap, bvid: bvidSnap, cid: cidSnap, playedSeconds: sec
                )
            }
        }
        // Also send a final heartbeat when the item finishes naturally
        // — keeps the cloud history in sync with "watched to end" so
        // the user doesn't get re-prompted to resume next time.
        if let token = playbackEndObserverToken {
            NotificationCenter.default.removeObserver(token)
            playbackEndObserverToken = nil
        }
        if let item = player.currentItem {
            playbackEndObserverToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.isPlaybackCompleted = true
                self.refreshSystemMediaSession()
                let sec = Int64(CMTimeGetSeconds(item.duration))
                Task.detached(priority: .background) {
                    try? CoreClient.shared.archiveHeartbeat(
                        aid: aidSnap, bvid: bvidSnap, cid: cidSnap, playedSeconds: sec
                    )
                }
            }
        }
    }

    /// Tear down the periodic heartbeat observer. Called on load swap
    /// and `deinit` so a stale closure can't keep firing on the next
    /// video.
    private func stopHeartbeat() {
        if let token = heartbeatObserverToken {
            player?.removeTimeObserver(token)
            heartbeatObserverToken = nil
        }
        if let token = playbackEndObserverToken {
            NotificationCenter.default.removeObserver(token)
            playbackEndObserverToken = nil
        }
        // Best-effort terminal beat for the *just-stopped* video so the
        // cloud history matches the actual stop position even if the
        // user dismissed without finishing.
        if aid > 0, cid > 0, let position = player?.currentTime() {
            let sec = Int64(CMTimeGetSeconds(position))
            let aidSnap = aid, bvidSnap = bvid, cidSnap = cid
            Task.detached(priority: .background) {
                try? CoreClient.shared.archiveHeartbeat(
                    aid: aidSnap, bvid: bvidSnap, cid: cidSnap, playedSeconds: sec
                )
            }
        }
        lastHeartbeatSec = -1
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
        let box = WarmPlayerObservationBox()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard box.installContinuation(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let itemObservation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                    switch item.status {
                    case .failed:
                        box.finish(.failure(item.error ?? WarmPlayerError.unexpectedFailure))
                    case .readyToPlay:
                        if player.timeControlStatus == .playing {
                            box.finish(.success(()))
                        }
                    default:
                        break
                    }
                }
                box.installItemObservation(itemObservation)

                let playerObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
                    if player.timeControlStatus == .playing {
                        box.finish(.success(()))
                    }
                }
                box.installPlayerObservation(playerObservation)

                if Task.isCancelled {
                    box.finish(.failure(CancellationError()))
                }
            }
        }, onCancel: {
            box.finish(.failure(CancellationError()))
        })
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
        setPlayer(warm.player)
        currentQn = qn
        isVideoReady = true
        applyPlaybackIntent(to: warm.player)
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
        setPlayer(hiWarm.player)
        self.currentQn = hiInfo.quality
        isVideoReady = true
        applyPlaybackIntent(to: hiWarm.player)
        suppressNextObservedPlaybackIntent(.pause)
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
                    self.isPlaybackCompleted = false
                    self.isVideoReady = true
                    // Seek to the server-recorded resume position
                    // exactly once per load. Cleared so a later
                    // quality-switch readyToPlay event keeps the
                    // user's current position intact.
                    if self.pendingResumeMs > 0 {
                        let ms = self.pendingResumeMs
                        self.pendingResumeMs = 0
                        // Discard if effectively at end (within 3s of
                        // duration) — bilibili reports the *terminal*
                        // position when the user finished the video.
                        let durationSec = item.duration.isNumeric ? CMTimeGetSeconds(item.duration) : 0
                        let resumeSec = Double(ms) / 1000.0
                        if durationSec <= 0 || resumeSec < durationSec - 3 {
                            let target = CMTime(seconds: resumeSec, preferredTimescale: 600)
                            Task { @MainActor in
                                await self.player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .init(seconds: 1, preferredTimescale: 600))
                                AppLog.info("player", "已跳转到云端记录进度", metadata: [
                                    "resumeMs": String(ms),
                                ])
                            }
                        }
                    }
                    self.startHeartbeatIfNeeded()
                    self.refreshSystemMediaSession()
                case .failed:
                    let detail = item.error?.localizedDescription ?? "unknown"
                    self.pageCache.removePlayURL(qn: self.currentQn, audioQn: self.currentAudioQn)
                    AppLog.error("player", "AVPlayerItem 失败", error: item.error, metadata: [
                        "detail": detail,
                    ])
                    await self.exportActiveDiagnostics(reason: "AVPlayerItem failed: \(detail)", generation: generation)
                    let failingQn = self.currentQn
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
                    self.refreshSystemMediaSession()
                default:
                    break
                }
            }
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
        if self.aid == aid,
           self.cid == cid,
           let cached = pageCache.playURL(qn: qn, audioQn: audioQn) {
            AppLog.debug("player", "命中播放页缓存的播放地址", metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "qn": String(qn),
                "audioQn": String(audioQn),
            ])
            return cached
        }
        let info = try await Task.detached {
            try CoreClient.shared.playUrl(aid: aid, cid: cid, qn: qn, audioQn: audioQn)
        }.value
        rememberPlayURL(info)
        return info
    }

    private func rememberPlayURL(_ info: PlayUrlDTO) {
        pageCache.storePlayURL(info)
    }

    private func currentPlaybackTimeForRecovery() -> CMTime {
        guard let player else {
            if pendingResumeMs > 0 {
                return CMTime(seconds: Double(pendingResumeMs) / 1000.0, preferredTimescale: 600)
            }
            return .zero
        }
        let current = player.currentTime()
        if current.isValid, !current.isIndefinite {
            return current
        }
        if pendingResumeMs > 0 {
            return CMTime(seconds: Double(pendingResumeMs) / 1000.0, preferredTimescale: 600)
        }
        return .zero
    }

    private func recoverPlaybackFromPageCacheIfPossible(trigger: String) async -> Bool {
        guard !isRecoveringPlaybackFromPageCache else { return true }
        guard currentQn > 0,
              let info = pageCache.playURL(qn: currentQn, audioQn: currentAudioQn) else {
            AppLog.debug("player", "播放页缓存未命中，无法直接恢复播放源", metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "trigger": trigger,
                "qn": String(currentQn),
                "audioQn": String(currentAudioQn),
            ])
            return false
        }

        isRecoveringPlaybackFromPageCache = true
        defer { isRecoveringPlaybackFromPageCache = false }

        let generation = loadGeneration
        let resumeAt = currentPlaybackTimeForRecovery()

        AppLog.info("player", "尝试使用播放页缓存恢复播放源", metadata: [
            "aid": String(aid),
            "cid": String(cid),
            "trigger": trigger,
            "qn": String(info.quality),
            "audioQn": String(info.audioQuality),
            "resumeSec": String(format: "%.3f", CMTimeGetSeconds(resumeAt)),
        ])

        do {
            let prep = try await engine.makeItem(for: info)
            guard isCurrentLoad(generation, aid: aid, cid: cid) else {
                prep.release()
                return true
            }

            if let item = lastLoadedItem {
                applyPresentationMetadata(to: prep.item, for: item)
            }

            isVideoReady = false
            cancelPendingUpgrade()
            stopHeartbeat()
            itemStatusObservation = nil

            let previousPreparation = activePreparation
            let targetPlayer: AVPlayer
            if let existingPlayer = player {
                suppressNextObservedPlaybackIntent(.pause)
                existingPlayer.pause()
                endTemporarySpeedBoost(on: existingPlayer)
                existingPlayer.replaceCurrentItem(with: nil)
                targetPlayer = existingPlayer
            } else {
                targetPlayer = AVPlayer(playerItem: prep.item)
            }

            activePreparation = prep
            observeItemStatus(prep.item, generation: generation)

            if player == nil {
                setPlayer(targetPlayer)
            } else {
                targetPlayer.replaceCurrentItem(with: prep.item)
            }

            await targetPlayer.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            applyRate(to: targetPlayer)
            applyPlaybackIntent(to: targetPlayer)
            previousPreparation?.release()
            refreshSystemMediaSession()

            AppLog.info("player", "播放页缓存恢复成功", metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "trigger": trigger,
                "qn": String(info.quality),
                "audioQn": String(info.audioQuality),
            ])
            return true
        } catch {
            pageCache.removePlayURL(qn: info.quality, audioQn: info.audioQuality)
            AppLog.warning("player", "播放页缓存恢复失败，已回退到常规重载路径", metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "trigger": trigger,
                "qn": String(info.quality),
                "audioQn": String(info.audioQuality),
                "error": error.localizedDescription,
            ])
            return false
        }
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
            suppressNextObservedPlaybackIntent(.pause)
            player.pause()
            endTemporarySpeedBoost(on: player)
            player.replaceCurrentItem(with: nil)
            activePreparation?.release()
            activePreparation = nil
            let info = try await fetchPlayUrl(aid: aid, cid: cid, qn: currentQn, audioQn: audioQn)
            rememberPlayURL(info)
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
            applyRate(to: player)
            applyPlaybackIntent(to: player)
            self.currentAudioQn = info.audioQuality
            self.availableAudioQualities = normalizedAudioQualities(from: info)
            self.prefersLandscapeFullscreen = Self.prefersLandscapeFullscreen(for: info)
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
        player.defaultRate = desiredPlaybackRate
        guard player.timeControlStatus == .playing || player.rate > 0 else { return }
        player.rate = desiredPlaybackRate
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

fileprivate struct WarmPlayerObservationStorage {
    var state: ObservationState = .pending
    var continuation: CheckedContinuation<Void, Error>?
    var itemObservation: NSKeyValueObservation?
    var playerObservation: NSKeyValueObservation?
}

fileprivate final class WarmPlayerObservationBox: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<WarmPlayerObservationStorage>(
        initialState: WarmPlayerObservationStorage()
    )

    func installContinuation(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        storage.withLock { storage in
            guard case .pending = storage.state else { return false }
            storage.continuation = continuation
            return true
        }
    }

    func installItemObservation(_ observation: NSKeyValueObservation) {
        let shouldInvalidate = storage.withLock { storage in
            guard case .pending = storage.state else { return true }
            storage.itemObservation = observation
            return false
        }
        if shouldInvalidate {
            observation.invalidate()
        }
    }

    func installPlayerObservation(_ observation: NSKeyValueObservation) {
        let shouldInvalidate = storage.withLock { storage in
            guard case .pending = storage.state else { return true }
            storage.playerObservation = observation
            return false
        }
        if shouldInvalidate {
            observation.invalidate()
        }
    }

    func finish(_ result: Result<Void, Error>) {
        let payload = storage.withLock { storage -> (CheckedContinuation<Void, Error>?, NSKeyValueObservation?, NSKeyValueObservation?)? in
            guard case .pending = storage.state else { return nil }
            storage.state = .resolved
            let continuation = storage.continuation
            let itemObservation = storage.itemObservation
            let playerObservation = storage.playerObservation
            storage.continuation = nil
            storage.itemObservation = nil
            storage.playerObservation = nil
            return (continuation, itemObservation, playerObservation)
        }
        guard let (continuation, itemObservation, playerObservation) = payload else { return }
        itemObservation?.invalidate()
        playerObservation?.invalidate()
        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

fileprivate enum WarmPlayerError: Error {
    case unexpectedFailure
}

// MARK: - Player view

struct PlayerView: View {
    private static let deferredDetailMountDelay: TimeInterval = 0.24

    let item: FeedItemDTO
    @StateObject private var vm: PlayerViewModel
    private let onPictureInPictureActiveChange: ((Bool) -> Void)?
    private let onPictureInPictureRestore: (((@escaping (Bool) -> Void) -> Void))?
    /// Plain reference type — see `DanmakuController` notes.
    @State private var danmaku = DanmakuController()
    @State private var didBootstrap = false
    @State private var loadedMediaKey: String?
    @State private var isFullscreen = false
    @State private var presentationState = PlayerPresentationState()
    @State private var lastDeviceOrientation: UIDeviceOrientation = .portrait
    /// Weak handle to the AVPlayerViewController so we can drive native FS.
    @State private var playerVCRef = PlayerVCBox()
    /// Long-press on the danmaku toggle opens this sheet for sending.
    @State private var showDanmakuSheet = false
    /// One-shot transient hint that surfaces when the user enables
    /// danmaku, telling them they can long-press the toggle to send one.
    /// Suppressible via `AppSettings.showDanmakuSendHint`.
    @State private var danmakuHint: String?
    @State private var danmakuHintWork: DispatchWorkItem?
    @State private var deferredDetailMountWork: DispatchWorkItem?
    @State private var shouldMountDetailContent = false
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    private let orientationPublisher = NotificationCenter.default
        .publisher(for: UIDevice.orientationDidChangeNotification)

    init(item: FeedItemDTO,
         viewModel: PlayerViewModel? = nil,
         onPictureInPictureActiveChange: ((Bool) -> Void)? = nil,
         onPictureInPictureRestore: (((@escaping (Bool) -> Void) -> Void))? = nil) {
        self.item = item
        self.onPictureInPictureActiveChange = onPictureInPictureActiveChange
        self.onPictureInPictureRestore = onPictureInPictureRestore
        _vm = StateObject(wrappedValue: viewModel ?? PlayerViewModel())
    }

    private var mediaLoadKey: String {
        "\(item.aid):\(item.bvid):\(item.cid)"
    }

    private var fullscreenTransitionContext: PlayerFullscreenTransitionContext {
        PlayerFullscreenTransitionContext(
            aid: item.aid,
            cid: item.cid,
            isFullscreen: isFullscreen,
            lastDeviceOrientation: lastDeviceOrientation,
            prefersLandscapeFullscreen: vm.prefersLandscapeFullscreen
        )
    }

    private var autoFullscreenContext: PlayerAutoFullscreenContext {
        PlayerAutoFullscreenContext(
            currentOrientation: UIDevice.current.orientation,
            lastDeviceOrientation: lastDeviceOrientation,
            isFullscreen: isFullscreen,
            prefersLandscapeFullscreen: vm.prefersLandscapeFullscreen,
            autoRotateFullscreen: settings.autoRotateFullscreen,
            isPhone: UIDevice.current.userInterfaceIdiom == .phone
        )
    }

    private func handlePresentationEvent(_ event: PlayerPresentationEvent) {
        switch event {
        case .fullscreenChanged(let isFullscreen, let identity):
            guard presentationIdentityMatchesCurrentRoute(identity) else {
                AppLog.debug("player", "忽略旧播放器 fullscreen 回调", metadata: [
                    "eventSessionID": identity.sessionID.uuidString,
                    "currentSessionID": vm.currentSessionID.uuidString,
                ])
                return
            }
            self.isFullscreen = isFullscreen
            if isFullscreen {
                _ = presentationState.beginFullscreen(identity)
            } else {
                _ = presentationState.endFullscreen(identity)
            }
        case .pictureInPictureChanged(let isActive, let identity):
            guard presentationIdentityMatchesCurrentRoute(identity) else {
                AppLog.debug("player", "忽略旧播放器 PiP 回调", metadata: [
                    "eventSessionID": identity.sessionID.uuidString,
                    "currentSessionID": vm.currentSessionID.uuidString,
                ])
                return
            }
            if let onPictureInPictureActiveChange {
                onPictureInPictureActiveChange(isActive)
            } else {
                vm.handle(.pictureInPictureChanged(isActive))
            }
        case .pictureInPictureRestoreRequested(let identity, let completion):
            guard presentationIdentityMatchesCurrentRoute(identity) else {
                AppLog.debug("player", "拒绝旧播放器 PiP 恢复请求", metadata: [
                    "eventSessionID": identity.sessionID.uuidString,
                    "currentSessionID": vm.currentSessionID.uuidString,
                ])
                completion(false)
                return
            }
            onPictureInPictureRestore?(completion) ?? completion(false)
        }
    }

    private func presentationIdentityMatchesCurrentRoute(_ identity: PlayerPresentationIdentity) -> Bool {
        guard identity.sessionID == vm.currentSessionID else { return false }
        if presentationState.accepts(identity) { return true }
        guard let currentPlayerID = vm.player.map(ObjectIdentifier.init),
              let incomingPlayerID = identity.playerID else { return true }
        return currentPlayerID == incomingPlayerID
    }

    private func requestFullscreenTransition(_ direction: PlayerFullscreenTransitionDirection) {
        PlayerFullscreenController.requestTransition(direction,
                                                     context: fullscreenTransitionContext,
                                                     playerBox: playerVCRef,
                                                     player: vm.player,
                                                     updateFullscreenState: { isFullscreen = $0 })
    }

    private func handleDeviceOrientationChange() {
        PlayerFullscreenController.handleDeviceOrientationChange(autoFullscreenContext,
                                                                 onEnterFullscreen: {
                                                                     requestFullscreenTransition(.enter)
                                                                 },
                                                                 onExitFullscreen: {
                                                                     requestFullscreenTransition(.exit)
                                                                 },
                                                                 rememberOrientation: {
                                                                     lastDeviceOrientation = $0
                                                                 })
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let p = vm.player {
                    PlayerContainer(
                        player: p,
                        sessionID: vm.currentSessionID,
                        title: item.title,
                        prefersLandscapeFullscreen: vm.prefersLandscapeFullscreen,
                        danmaku: danmaku,
                        danmakuEnabled: settings.danmakuEnabled,
                        danmakuOpacity: settings.danmakuOpacity,
                        danmakuBlockLevel: settings.resolvedDanmakuBlockLevel(),
                        danmakuFrameRate: settings.resolvedDanmakuFrameRate(),
                        danmakuStrokeWidth: settings.resolvedDanmakuStrokeWidth(),
                        danmakuFontWeight: settings.resolvedDanmakuFontWeight(),
                        danmakuFontScale: settings.resolvedDanmakuFontScale(),
                        isTemporarySpeedBoostActive: { vm.isTemporarySpeedBoostActive },
                        canBeginTemporarySpeedBoost: { vm.canBeginTemporarySpeedBoost },
                        beginTemporarySpeedBoost: { vm.beginTemporarySpeedBoost() },
                        endTemporarySpeedBoost: { vm.endTemporarySpeedBoost() },
                        onCreated: { vc in playerVCRef.vc = vc },
                        onPresentationControllerReady: { controller in
                            playerVCRef.presentationController = controller
                        },
                        onPresentationEvent: handlePresentationEvent,
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

            if shouldMountDetailContent {
                VideoDetailContent(item: item,
                                   detailViewModel: vm.pageCache.detailViewModel,
                                   commentListViewModel: vm.pageCache.commentListViewModel)
                    .transition(.opacity)
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(IbiliTheme.accent)
                    Text("正在准备详情")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .background(IbiliTheme.background)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isFullscreen, vm.player != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    PlayerToolbarDanmaku(
                        danmakuEnabled: $settings.danmakuEnabled,
                        onLongPress: { showDanmakuSheet = true }
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PlayerToolbarVideoQuality(
                        qualities: vm.availableQualities,
                        currentQn: vm.currentQn,
                        onPick: { qn in Task { await vm.switchQuality(to: qn) } }
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PlayerToolbarAudioQuality(
                        audioQualities: vm.availableAudioQualities,
                        currentAudioQn: vm.currentAudioQn,
                        onPick: { qn in Task { await vm.switchAudioQuality(to: qn) } }
                    )
                }
            }
        }
        .task(id: mediaLoadKey) {
            if !didBootstrap {
                didBootstrap = true
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            }

            if loadedMediaKey != mediaLoadKey {
                scheduleDeferredDetailMount(for: mediaLoadKey)
            } else if !shouldMountDetailContent {
                shouldMountDetailContent = true
            }

            // Claim playback focus as soon as the pushed player page
            // starts loading so route-to-route navigation does not
            // momentarily release the shared audio session while the
            // new AVPlayer is still buffering.
            vm.handle(.interfaceActivated)

            guard loadedMediaKey != mediaLoadKey || vm.player == nil else {
                vm.handle(.interfaceActivated)
                return
            }

            loadedMediaKey = mediaLoadKey
            async let video: Void = vm.load(item: item,
                                            preferredQn: Int64(settings.resolvedPreferredVideoQn()),
                                            preferredAudioQn: Int64(settings.preferredAudioQn),
                                            fastLoad: settings.fastLoad)
            async let danmaku: Void = loadDanmaku()
            _ = await (video, danmaku)
            vm.handle(.interfaceActivated)
        }
        .onChange(of: vm.player) { newPlayer in
            if let p = newPlayer {
                vm.setAudioVolumeLinear(settings.resolvedAudioVolumeLinear())
                danmaku.attach(p)
                vm.handle(.interfaceActivated)
            }
        }
        .onChange(of: settings.audioGainDb) { _ in
            vm.setAudioVolumeLinear(settings.resolvedAudioVolumeLinear())
        }
        .onChange(of: scenePhase) { phase in
            PlayerViewLifecycleController.handleScenePhaseChange(
                phase,
                didBootstrap: didBootstrap,
                viewModel: vm,
                playerBox: playerVCRef,
                reloadPlayer: { await vm.recoverFromInactiveEngineIfNeeded(trigger: "foreground-active") }
            )
        }
        .onReceive(orientationPublisher) { _ in
            handleDeviceOrientationChange()
        }
        .onAppear {
            PlayerViewLifecycleController.handleAppear(
                didBootstrap: didBootstrap,
                viewModel: vm,
                danmaku: danmaku,
                resolvedAudioVolumeLinear: settings.resolvedAudioVolumeLinear()
            )
        }
        .onDisappear {
            deferredDetailMountWork?.cancel()
            deferredDetailMountWork = nil
            PlayerViewLifecycleController.handleDisappear(
                isPlayerPresentationActive: presentationState.isFullscreenPresentationActive,
                viewModel: vm,
                danmaku: danmaku
            )
        }
        .onChange(of: settings.danmakuEnabled) { newValue in
            // Surface a one-shot reminder the first few times the user
            // enables danmaku — long-press to send is otherwise hidden.
            // Users can disable this from 设置 once they've internalised
            // the gesture.
            guard newValue, settings.showDanmakuSendHint else { return }
            danmakuHint = "长按弹幕开关可发送弹幕（可在设置中关闭提示）"
            danmakuHintWork?.cancel()
            let work = DispatchWorkItem { danmakuHint = nil }
            danmakuHintWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
        }
        .overlay(alignment: .top) {
            if let m = danmakuHint {
                Text(m)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: danmakuHint)
        .sheet(isPresented: $showDanmakuSheet) {
            DanmakuSendSheet(
                aid: vm.currentAid > 0 ? vm.currentAid : item.aid,
                cid: vm.currentCid > 0 ? vm.currentCid : item.cid,
                progressProvider: { currentPlayheadMs() },
                onSent: { echo in
                    // Local-echo into the live renderer so the user
                    // sees their bullet immediately. Frame styling is
                    // handled inside the canvas based on `isSelf`.
                    danmaku.appendLive(echo)
                }
            )
        }
    }

    /// Snapshot the live AVPlayer playhead in milliseconds. Falls back
    /// to 0 if the player isn't ready or the time is invalid.
    private func currentPlayheadMs() -> Int64 {
        guard let p = vm.player else { return 0 }
        let t = p.currentTime()
        guard t.isValid, !t.isIndefinite else { return 0 }
        let s = CMTimeGetSeconds(t)
        guard s.isFinite, s >= 0 else { return 0 }
        return Int64(s * 1000)
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
        do {
            let resolvedItem: FeedItemDTO
            if let currentFeedItem = vm.currentFeedItem {
                resolvedItem = currentFeedItem
            } else {
                resolvedItem = try await resolvePlayableItemIfNeeded(item)
            }
            if let cachedItems = vm.pageCache.danmaku(for: resolvedItem.cid) {
                danmaku.setItems(cachedItems)
                if let p = vm.player { danmaku.attach(p) }
                AppLog.debug("danmaku", "命中播放页缓存的弹幕", metadata: [
                    "cid": String(resolvedItem.cid),
                    "count": String(cachedItems.count),
                ])
                return
            }
            AppLog.info("danmaku", "开始加载弹幕", metadata: [
                "cid": String(resolvedItem.cid),
            ])
            let sortedItems = try await Task.detached { [cid = resolvedItem.cid, durationSec = resolvedItem.durationSec] in
                try CoreClient.shared.danmakuList(cid: cid, durationSec: durationSec)
                    .items
                    .sorted { $0.timeSec < $1.timeSec }
            }.value
            vm.pageCache.storeDanmaku(sortedItems, for: resolvedItem.cid)
            danmaku.setItems(sortedItems)
            if let p = vm.player { danmaku.attach(p) }
            AppLog.info("danmaku", "弹幕加载完成", metadata: [
                "cid": String(resolvedItem.cid),
                "count": String(sortedItems.count),
            ])
        } catch {
            AppLog.error("danmaku", "弹幕加载失败", error: error, metadata: [
                "cid": String(item.cid),
            ])
        }
    }

    private func scheduleDeferredDetailMount(for key: String) {
        deferredDetailMountWork?.cancel()
        shouldMountDetailContent = false
        let work = DispatchWorkItem { [key] in
            guard key == mediaLoadKey else { return }
            shouldMountDetailContent = true
            deferredDetailMountWork = nil
        }
        deferredDetailMountWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.deferredDetailMountDelay,
            execute: work
        )
    }

}


