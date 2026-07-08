import SwiftUI
import AVKit
import AVFoundation
import UIKit

private func resolvePlayableItemIfNeeded(_ item: FeedItemDTO) async throws -> FeedItemDTO {
    guard !item.isPGC else { return item }
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
        danmaku: item.danmaku,
        pubdate: item.pubdate,
        isFollowed: item.isFollowed,
        epID: item.epID,
        seasonID: item.seasonID,
        isPGC: item.isPGC,
        ownerMID: item.ownerMID,
        feedGoto: item.feedGoto,
        feedID: item.feedID,
        dislikeReasons: item.dislikeReasons,
        feedbackReasons: item.feedbackReasons
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
    @Published private(set) var availableSubtitles: [VideoSubtitleDTO] = []
    @Published private(set) var viewPoints: [VideoViewPointDTO] = []
    @Published var rate: Float = 1.0 { didSet { applyRate() } }
    @Published private(set) var isTemporarySpeedBoostActive = false
    @Published private(set) var isPausedForDetailCollapse = false
    @Published private(set) var playbackCompletionSignal = 0
    private let holdSpeedRate: Float = 2.0
    private var temporaryPlaybackRateOverride: Float?
    /// Linear `AVPlayer.volume` value derived from the user's
    /// `audioGainDb` setting. Updated from SwiftUI via
    /// ``setAudioVolumeLinear(_:)`` and applied to the active
    /// AVPlayer (and any subsequently-attached one).
    private var audioVolumeLinear: Float = 1.0
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
    private var heartbeatEndObserverToken: NSObjectProtocol?
    /// End-of-item observer token driving local completion behavior.
    private var playbackCompletionObserverToken: NSObjectProtocol?
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
    private var cdnSelection: String = MediaCDNService.auto.rawValue
    private var playbackCacheVariant: String = AppSettings.shared.playbackCacheVariantKey()
    private var playbackCodecPreference: String = "auto"
    private var currentVideoCodec: String = ""
    private var isCurrentSourceOffline = false
    private var didAttemptAVCRecovery = false
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
    private let sessionID: PlayerSessionID
    private var behaviorState = PlayerSessionBehaviorState()
    private var playerTimeControlObservation: NSKeyValueObservation?
    private var isPlaybackCompleted = false
    private var isRecoveringPlaybackFromPageCache = false
    private var transientPauseSuppressionDeadline = Date.distantPast
    private var transientPauseSuppressionContext: PlayerTransientPauseSuppressionContext?
    private var pausedForDetailCollapseConfirmationWork: DispatchWorkItem?
    private var isClosing = false
    private var dismissalFadeTask: Task<Void, Never>?

    init(sessionID: PlayerSessionID = PlayerSessionID()) {
        self.sessionID = sessionID
    }

    deinit {
        MainActor.assumeIsolated {
            PlayerPlaybackCoordinator.shared.unregister(self)
            PlayerNowPlayingCoordinator.shared.unregister(self)
            PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: self)
            clearTransientPauseSuppression()
            clearPausedForDetailCollapse()
            dismissalFadeTask?.cancel()
            stopHeartbeat()
            clearPlaybackCompletionObserver()
            itemStatusObservation = nil
            playerTimeControlObservation?.invalidate()
            playerTimeControlObservation = nil
            if let player {
                player.volume = 0
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            activePreparation?.release()
            activePreparation = nil
        }
    }

    private func playbackDebugMetadata(for targetPlayer: AVPlayer? = nil,
                                      extra: [String: String] = [:]) -> [String: String] {
        let player = targetPlayer ?? self.player
        let suppressionRemainingMs = max(0, Int(transientPauseSuppressionDeadline.timeIntervalSinceNow * 1000))
        var metadata = behaviorState.debugMetadata
        metadata["aid"] = String(aid)
        metadata["cid"] = String(cid)
        metadata["sessionID"] = sessionID.uuidString
        metadata["timeControlStatus"] = player.map { timeControlStatusDescription($0.timeControlStatus) } ?? "nil"
        metadata["playerRate"] = player.map { String($0.rate) } ?? "nil"
        metadata["playerDefaultRate"] = player.map { String($0.defaultRate) } ?? "nil"
        metadata["desiredPlaybackRate"] = String(desiredPlaybackRate)
        metadata["transientPauseSuppressionContext"] = transientPauseSuppressionContext?.rawValue ?? "nil"
        metadata["transientPauseSuppressionActive"] = String(Date() < transientPauseSuppressionDeadline)
        metadata["transientPauseSuppressionRemainingMs"] = String(suppressionRemainingMs)
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }

    private func playerSessionEventDescription(_ event: PlayerSessionEvent) -> String {
        switch event {
        case .interfaceActivated:
            return "interfaceActivated"
        case .interfaceDeactivated:
            return "interfaceDeactivated"
        case .pictureInPictureChanged(let isActive):
            return "pictureInPictureChanged(\(isActive))"
        case .playbackIntentChanged(let intent):
            return "playbackIntentChanged(\(intent.rawValue))"
        case .prepareAutoplayForMediaReplacement:
            return "prepareAutoplayForMediaReplacement"
        case .suppressNextObservedIntent(let intent):
            return "suppressNextObservedIntent(\(intent.rawValue))"
        case .observedTimeControlStatus(let status):
            return "observedTimeControlStatus(\(timeControlStatusDescription(status)))"
        }
    }

    func load(
        item: FeedItemDTO,
        preferredQn: Int64,
        preferredAudioQn: Int64 = 0,
        cdnSelection: String = MediaCDNService.auto.rawValue,
        cacheVariant: String = MediaCDNService.auto.rawValue,
        offlineOnly: Bool = false
    ) async {
        guard !isClosing else { return }
        // Some entry points (notably the search results grid) hand us
        // a `FeedItemDTO` with `cid == 0` because the upstream
        // search-by-type endpoint omits cids. Resolve it via the view
        // API before doing anything player-related — otherwise both
        // the web and TV playurl calls hit "请求错误 / 啥都木有".
        var item = item
        if !offlineOnly {
            do {
                item = try await resolvePlayableItemIfNeeded(item)
            } catch {
                guard !isClosing else { return }
                isLoading = false
                errorText = "无法解析视频信息: \((error as NSError).localizedDescription)"
                return
            }
        }
        guard !isClosing else { return }
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
        let requestedAudioQn = max(0, preferredAudioQn)
        lastPreferredAudioQn = requestedAudioQn
        self.cdnSelection = cdnSelection
        playbackCacheVariant = cacheVariant
        autoReloadAttempts = 0
        if !isSameVideo {
            blockedQns.removeAll()
            playbackCodecPreference = "auto"
            currentVideoCodec = ""
            isCurrentSourceOffline = false
            didAttemptAVCRecovery = false
            pageCache.clearMediaData()
            stopHeartbeat()
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
        currentAudioQn = requestedAudioQn
        isLoading = true; errorText = nil; isVideoReady = false; isPausedForDetailCollapse = false
        availableSubtitles = []
        viewPoints = []
        itemStatusObservation = nil
        if isSameVideo {
            stopHeartbeat()
        }
        AppLog.info("player", "开始加载播放器", metadata: [
            "aid": String(item.aid),
            "cid": String(item.cid),
            "preferredQn": String(preferredQn),
            "preferredAudioQn": String(requestedAudioQn),
            "cdn": cdnSelection,
            "offlineOnly": String(offlineOnly),
        ])
        do {
            if let offline = OfflineDownloadService.shared.playbackSource(
                for: item,
                preferredQn: preferredQn,
                audioQn: requestedAudioQn
            ) {
                try await loadOfflineSource(
                    offline,
                    item: item,
                    generation: generation,
                    startedAt: startedAt
                )
                if isCurrentLoad(generation, aid: item.aid, cid: item.cid) {
                    isLoading = false
                }
                return
            } else if offlineOnly {
                throw OfflineDownloadError.message("离线文件不可用或已损坏")
            }

            let discoveryQnTarget = max(preferredQn, discoveryQn)
            let initial: PlayUrlDTO
            if !item.isPGC,
               let warm = PlayUrlPrefetcher.shared.take(aid: item.aid,
                                                        cid: item.cid,
                                                        qn: discoveryQnTarget,
                                                        audioQn: requestedAudioQn,
                                                        cdn: cdnSelection) {
                initial = warm
                rememberPlayURL(warm)
            } else {
                initial = try await fetchPlayUrl(for: item, qn: discoveryQnTarget, audioQn: requestedAudioQn)
            }
            guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else { return }
            let qualities = normalizedQualities(from: initial)
            let targetQn = resolveTargetQn(preferredQn: preferredQn, qualities: qualities, fallback: initial.quality)
            let info: PlayUrlDTO
            if targetQn == initial.quality {
                info = initial
            } else if !item.isPGC,
                      let warm = PlayUrlPrefetcher.shared.take(aid: item.aid,
                                                               cid: item.cid,
                                                               qn: targetQn,
                                                               audioQn: requestedAudioQn,
                                                               cdn: cdnSelection) {
                info = warm
                rememberPlayURL(warm)
            } else {
                info = try await fetchPlayUrl(for: item, qn: targetQn, audioQn: requestedAudioQn)
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
            //
            // `lastPlayTimeMs` is aid-level: the server reports the most
            // recent position across ALL parts, with `lastPlayCid`
            // identifying which part it belongs to. Only honor it when
            // it belongs to the part we are loading, otherwise switching
            // 分P would inherit another part's progress.
            if info.lastPlayCid == 0 || info.lastPlayCid == item.cid {
                self.pendingResumeMs = info.lastPlayTimeMs
            } else {
                self.pendingResumeMs = 0
            }

            let prep = try await engine.makeItem(for: info)
            guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else {
                prep.release()
                AppLog.debug("player", "丢弃过期播放器加载结果", metadata: [
                    "aid": String(item.aid),
                    "cid": String(item.cid),
                ])
                return
            }
            applyPresentationMetadata(to: prep.item, for: item)
            rememberActivePlayURL(info)
            self.currentQn = info.quality
            let player = AVPlayer(playerItem: prep.item)
            configureExternalPlayback(for: player)
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
            meta["audioQuality"] = String(info.audioQuality)
            meta["audioQualityLabel"] = info.audioQualityLabel.isEmpty ? "-" : info.audioQualityLabel
            meta["availableAudio"] = availableAudioQualities.map { String($0.qn) }.joined(separator: ",")
            meta["separateAudio"] = info.audioUrl == nil ? "false" : "true"
            meta["prepMs"] = String(prep.totalElapsedMs)
            meta["startupMs"] = String(startupMs)
            AppLog.info("player", "播放器已就绪", metadata: meta)
            if let msg = info.debugMessage {
                AppLog.warning("player", "core 返回调试信息", metadata: ["detail": msg])
            }
        } catch {
            guard !isClosing else { return }
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
        guard !isClosing, let item = lastLoadedItem else { return }
        AppLog.info("player", "检测到本地代理失效，重新加载", metadata: [
            "aid": String(item.aid),
            "cid": String(item.cid),
        ])
        // Force `load` past its idempotency check by clearing the
        // currently-loaded coordinates and tearing down the player.
        let priorAttempts = autoReloadAttempts
        stopHeartbeat()
        clearPlaybackCompletionObserver()
        suppressNextObservedPlaybackIntent(.pause)
        itemStatusObservation = nil
        if let player {
            player.pause()
            endTemporarySpeedBoost(on: player)
            clearPlaybackCompletionObserver()
            player.replaceCurrentItem(with: nil)
        }
        setPlayer(nil)
        activePreparation?.release()
        activePreparation = nil
        aid = 0; cid = 0
        await load(item: item,
               preferredQn: lastPreferredQn,
               preferredAudioQn: lastPreferredAudioQn,
               cdnSelection: cdnSelection,
               cacheVariant: playbackCacheVariant,
               offlineOnly: isCurrentSourceOffline)
        guard !isClosing else { return }
        // `load(...)` zeroes the counter; preserve our caller's tally
        // so a chain of failed reloads cannot loop indefinitely.
        autoReloadAttempts = max(autoReloadAttempts, priorAttempts)
    }

    /// Whether the engine still owns a live proxy stream. False after
    /// iOS suspends the app long enough to kill the listener.
    var isEngineAlive: Bool { HLSProxyEngine.shared.isAlive }

    func handle(_ event: PlayerSessionEvent) {
        guard !isClosing || event == .interfaceDeactivated || event == .pictureInPictureChanged(false) else { return }
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

        let eventDescription = playerSessionEventDescription(event)
        let applied = behaviorState.apply(event)
        AppLog.debug("player", applied ? "播放器会话事件已应用" : "播放器会话事件被忽略", metadata: playbackDebugMetadata(extra: [
            "event": eventDescription,
            "applied": String(applied),
        ]))
        guard applied else { return }

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

    var currentSeasonID: Int64 {
        lastLoadedItem?.seasonID ?? 0
    }

    var currentEpisodeID: Int64 {
        lastLoadedItem?.epID ?? 0
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
        guard !isClosing else { return nil }
        guard let seconds = player?.currentTime().seconds,
              seconds.isFinite,
              seconds >= 0 else {
            return nil
        }
        return seconds
    }

    var systemMediaPlaybackRate: Float {
        guard !isClosing else { return 0 }
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

    var shouldResumePlaybackAfterNativeFullscreenExit: Bool {
        shouldHoldAudioSession
    }

    func refreshSystemMediaSession() {
        guard !isClosing else { return }
        PlayerNowPlayingCoordinator.shared.refresh(for: self)
    }

    func handleRemotePlaybackIntent(_ intent: PlayerIntent) {
        guard !isClosing else { return }
        switch intent {
        case .pause:
            handle(.playbackIntentChanged(.pause))
        case .play:
            Task { @MainActor in
                guard !self.isClosing else { return }
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

    func pauseForPlaybackCompletion() {
        guard !isClosing else { return }
        isPlaybackCompleted = true
        handle(.playbackIntentChanged(.pause))
        refreshSystemMediaSession()
    }

    func restartCurrentItem() {
        guard !isClosing, let player else { return }
        Task { @MainActor in
            guard !self.isClosing, self.player === player else { return }
            self.isPlaybackCompleted = false
            self.armTransientPauseSuppression(for: .playbackLoopRestart)
            self.suppressNextObservedPlaybackIntent(.pause)
            await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !self.isClosing, self.player === player else { return }
            self.handle(.playbackIntentChanged(.play))
            self.applyPlaybackIntent(to: player)
            self.refreshSystemMediaSession()
        }
    }

    func recoverFromInactiveEngineIfNeeded(trigger: String) async {
        guard !isClosing else { return }
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

    private func configureExternalPlayback(for player: AVPlayer) {
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
    }

    func backgroundContinuationRate(for player: AVPlayer) -> Float? {
        guard !isClosing else { return nil }
        return behaviorState.backgroundContinuationRate(currentRate: player.rate,
                                                        desiredRate: desiredPlaybackRate)
    }

    func reapplyPlaybackBehavior(to targetPlayer: AVPlayer? = nil) {
        applyPlaybackIntent(to: targetPlayer)
    }

    var canBeginTemporarySpeedBoost: Bool {
        guard !isClosing else { return false }
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
        guard !isClosing else { return }
        player?.volume = clamped
    }

    func switchQuality(to qn: Int64) async {
        guard !isClosing, let player else { return }
        let generation = loadGeneration
        let resumeAt = player.currentTime()
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
            clearPlaybackCompletionObserver()
            player.replaceCurrentItem(with: nil)
            activePreparation?.release()
            activePreparation = nil
            // Releasing the previous source before allocating the new
            // one keeps the proxy token table from growing across
            // switches without tearing down other tab's retained players.
            let info: PlayUrlDTO
            if let item = lastLoadedItem {
                if let offline = OfflineDownloadService.shared.playbackSource(
                    for: item,
                    preferredQn: qn,
                    audioQn: currentAudioQn
                ), offline.metadata.qn == qn {
                    info = offline.play
                    isCurrentSourceOffline = true
                    AppLog.info("player", "清晰度切换命中离线缓存", metadata: [
                        "aid": String(item.aid),
                        "cid": String(item.cid),
                        "qn": String(qn),
                    ])
                } else {
                    info = try await fetchPlayUrl(for: item, qn: qn)
                }
            } else {
                info = try await fetchPlayUrl(aid: aid, cid: cid, qn: qn)
            }
            rememberPlayURL(info)
            guard isCurrentLoad(generation, aid: aid, cid: cid) else { return }
            let prep = try await engine.makeItem(for: info)
            guard isCurrentLoad(generation, aid: aid, cid: cid) else {
                prep.release()
                return
            }
            if let item = lastLoadedItem {
                applyPresentationMetadata(to: prep.item, for: item)
            }
            activePreparation = prep
            rememberActivePlayURL(info)
            observeItemStatus(prep.item, generation: generation)
            player.replaceCurrentItem(with: prep.item)
            observePlaybackCompletion(for: player)
            await player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            applyRate(to: player)
            applyPlaybackIntent(to: player)
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
            meta["audioQuality"] = String(info.audioQuality)
            meta["audioQualityLabel"] = info.audioQualityLabel.isEmpty ? "-" : info.audioQualityLabel
            meta["availableAudio"] = availableAudioQualities.map { String($0.qn) }.joined(separator: ",")
            meta["separateAudio"] = info.audioUrl == nil ? "false" : "true"
            meta["prepMs"] = String(prep.totalElapsedMs)
            AppLog.info("player", "清晰度切换成功", metadata: meta)
            if let msg = info.debugMessage {
                AppLog.warning("player", "core 返回调试信息", metadata: ["detail": msg])
            }
        } catch {
            guard !isClosing else { return }
            errorText = error.localizedDescription
            AppLog.error("player", "清晰度切换失败", error: error, metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "toQn": String(qn),
            ])
        }
    }

    func teardown() {
        isClosing = true
        dismissalFadeTask?.cancel()
        dismissalFadeTask = nil
        PlayerPlaybackCoordinator.shared.unregister(self)
        PlayerNowPlayingCoordinator.shared.unregister(self)
        loadGeneration &+= 1
        clearTransientPauseSuppression()
        clearPausedForDetailCollapse()
        AppLog.debug("player", "销毁播放器", metadata: [
            "aid": String(aid),
            "cid": String(cid),
        ])
        stopHeartbeat()
        clearPlaybackCompletionObserver()
        suppressNextObservedPlaybackIntent(.pause)
        itemStatusObservation = nil
        if let player {
            player.volume = 0
            player.pause()
            endTemporarySpeedBoost(on: player)
            player.replaceCurrentItem(with: nil)
        }
        setPlayer(nil)
        activePreparation?.release()
        activePreparation = nil
        pageCache.clearMediaData()
        behaviorState = PlayerSessionBehaviorState()
        isPlaybackCompleted = false
        isVideoReady = false
    }

    func prepareForDismissal() {
        if behaviorState.pictureInPictureIsActive {
            handle(.interfaceDeactivated)
            return
        }
        guard !isClosing else { return }
        isClosing = true
        loadGeneration &+= 1
        clearTransientPauseSuppression()
        clearPausedForDetailCollapse()
        itemStatusObservation = nil
        stopHeartbeat()
        clearPlaybackCompletionObserver()
        PlayerPlaybackCoordinator.shared.unregister(self)
        PlayerNowPlayingCoordinator.shared.unregister(self)
        fadeOutAndPauseForDismissal()
        PlayerNowPlayingCoordinator.shared.refresh(for: self)
    }

    func prepareForStackBackground() {
        guard !isClosing, !behaviorState.pictureInPictureIsActive else { return }
        let status = player?.timeControlStatus
        let playerNeedsPause = (player?.rate ?? 0) > 0 || (status != nil && status != .paused)
        guard behaviorState.interfaceIsActive || playerNeedsPause || isTemporarySpeedBoostActive else { return }
        AppLog.debug("player", "播放器进入导航栈后台", metadata: playbackDebugMetadata(extra: [
            "reason": "route-not-foreground",
        ]))
        handle(.interfaceDeactivated)
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
        clearPlaybackCompletionObserver()
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
        clearPlaybackCompletionObserver()
        clearTransientPauseSuppression()
        clearPausedForDetailCollapse()
        if newPlayer == nil {
            temporaryPlaybackRateOverride = nil
            isTemporarySpeedBoostActive = false
        } else {
            isPlaybackCompleted = false
        }
        player = newPlayer
        updatePausedForDetailCollapse(from: newPlayer)
        if let newPlayer {
            newPlayer.volume = audioVolumeLinear
            observePlayerTimeControl(newPlayer)
            observePlaybackCompletion(for: newPlayer)
            applyRate(to: newPlayer)
            PlayerNowPlayingCoordinator.shared.refresh(for: self)
        } else {
            PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: self)
            PlayerNowPlayingCoordinator.shared.refresh(for: self)
        }
    }

    private func observePlaybackCompletion(for player: AVPlayer) {
        clearPlaybackCompletionObserver()
        guard let item = player.currentItem else { return }
        playbackCompletionObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self,
                  let player,
                  !self.isClosing,
                  self.player === player else { return }
            self.handlePlaybackCompleted()
        }
    }

    private func clearPlaybackCompletionObserver() {
        if let token = playbackCompletionObserverToken {
            NotificationCenter.default.removeObserver(token)
            playbackCompletionObserverToken = nil
        }
    }

    private func handlePlaybackCompleted() {
        isPlaybackCompleted = true
        refreshSystemMediaSession()
        playbackCompletionSignal &+= 1
    }

    private func fadeOutAndPauseForDismissal() {
        dismissalFadeTask?.cancel()
        guard let player else {
            PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: self)
            return
        }
        endTemporarySpeedBoost(on: player)
        dismissalFadeTask = Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            let startVolume = player.volume
            let steps = 4
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: 18_000_000)
                guard !Task.isCancelled, self.player === player else { return }
                player.volume = startVolume * Float(steps - step) / Float(steps)
            }
            guard !Task.isCancelled, self.player === player else { return }
            player.pause()
            player.volume = 0
            PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: self)
        }
    }

    private func observePlayerTimeControl(_ player: AVPlayer) {
        playerTimeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak player] observedPlayer, _ in
            Task { @MainActor in
                guard let self,
                      let player,
                      !self.isClosing,
                      self.player === player else { return }
                self.handleObservedPlaybackState(observedPlayer.timeControlStatus, observedPlayer: observedPlayer)
            }
        }
    }

    private func handleObservedPlaybackState(_ status: AVPlayer.TimeControlStatus,
                                            observedPlayer: AVPlayer? = nil) {
        guard !isClosing else { return }
        let suppressionActive = Date() < transientPauseSuppressionDeadline
        AppLog.debug("player", "观察到 AVPlayer.timeControlStatus 变化", metadata: playbackDebugMetadata(for: observedPlayer, extra: [
            "observedStatus": timeControlStatusDescription(status),
        ]))
        if status == .paused,
           suppressionActive {
            AppLog.debug("player", "忽略短暂播放切换中的瞬时暂停回调", metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "observedStatus": timeControlStatusDescription(status),
            ])
            return
        }
        updatePausedForDetailCollapse(from: observedPlayer)
        if status == .playing || status == .waitingToPlayAtSpecifiedRate {
            clearTransientPauseSuppression()
        }
        handle(.observedTimeControlStatus(status))
    }

    private func updatePausedForDetailCollapse(from observedPlayer: AVPlayer? = nil) {
        guard !isClosing,
              isVideoReady,
              let targetPlayer = observedPlayer ?? player,
              targetPlayer === player else {
            clearPausedForDetailCollapse()
            return
        }
        if targetPlayer.timeControlStatus == .paused && targetPlayer.rate == 0 {
            schedulePausedForDetailCollapseConfirmation(for: targetPlayer)
        } else {
            clearPausedForDetailCollapse()
        }
    }

    private func schedulePausedForDetailCollapseConfirmation(for targetPlayer: AVPlayer) {
        guard !isPausedForDetailCollapse else { return }
        pausedForDetailCollapseConfirmationWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak targetPlayer] in
            guard let self, let targetPlayer else { return }
            self.confirmPausedForDetailCollapse(for: targetPlayer)
        }
        pausedForDetailCollapseConfirmationWork = work
        // Native AVKit briefly reports `.paused` while scrubbing the
        // progress bar. Only arm the scroll-collapse path after the
        // pause stays stable for a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func confirmPausedForDetailCollapse(for targetPlayer: AVPlayer) {
        pausedForDetailCollapseConfirmationWork = nil
        guard !isClosing,
              isVideoReady,
              targetPlayer === player,
              targetPlayer.timeControlStatus == .paused,
              targetPlayer.rate == 0 else { return }
        // Guard against same-value re-publishing: `@Published` fires
        // `objectWillChange` on EVERY assignment, and this runs on the
        // timeControlStatus KVO path which fires in bursts while
        // buffering. Each spurious publish rebuilds the page body and
        // tears down the open toolbar `Menu` (flicker + dead taps).
        if !isPausedForDetailCollapse {
            isPausedForDetailCollapse = true
        }
    }

    private func clearPausedForDetailCollapse() {
        pausedForDetailCollapseConfirmationWork?.cancel()
        pausedForDetailCollapseConfirmationWork = nil
        // Same-value guard: see `confirmPausedForDetailCollapse`.
        if isPausedForDetailCollapse {
            isPausedForDetailCollapse = false
        }
    }

    func armTransientPauseSuppression(for context: PlayerTransientPauseSuppressionContext) {
        transientPauseSuppressionContext = context
        transientPauseSuppressionDeadline = Date().addingTimeInterval(context.window)
        AppLog.debug("player", "启用短暂暂停抑制窗口", metadata: playbackDebugMetadata(extra: [
            "windowMs": String(Int(context.window * 1000)),
        ]))
    }

    func prepareForNativeFullscreenExit(shouldResumePlayback: Bool) {
        guard !isClosing, shouldResumePlayback else { return }
        armTransientPauseSuppression(for: .nativeFullscreenExit)
        suppressNextObservedPlaybackIntent(.pause)
    }

    func completeNativeFullscreenExit(shouldResumePlayback: Bool) {
        guard !isClosing, shouldResumePlayback else { return }
        handle(.playbackIntentChanged(.play))
        armTransientPauseSuppression(for: .nativeFullscreenExit)
        suppressNextObservedPlaybackIntent(.pause)
        guard let player else { return }
        applyPlaybackIntent(to: player)
    }

    private func clearTransientPauseSuppression() {
        transientPauseSuppressionContext = nil
        transientPauseSuppressionDeadline = .distantPast
    }

    private func applyPlaybackIntent(to targetPlayer: AVPlayer? = nil) {
        guard !isClosing else { return }
        PlayerAudioSessionCoordinator.shared.setSessionNeeded(shouldHoldAudioSession, by: self)
        guard let targetPlayer = targetPlayer ?? player else { return }
        switch behaviorState.desiredPlaybackCommand(rate: desiredPlaybackRate) {
        case .play(let rate):
            AppLog.debug("player", "向 AVPlayer 下发播放命令", metadata: playbackDebugMetadata(for: targetPlayer, extra: [
                "command": "play",
                "commandRate": String(rate),
            ]))
            suppressNextObservedPlaybackIntent(.play)
            targetPlayer.playImmediately(atRate: rate)
        case .pause:
            AppLog.debug("player", "向 AVPlayer 下发暂停命令", metadata: playbackDebugMetadata(for: targetPlayer, extra: [
                "command": "pause",
            ]))
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
        guard !isCurrentSourceOffline else { return }
        guard let player, heartbeatObserverToken == nil else { return }
        guard lastLoadedItem?.isPGC != true else { return }
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
        if let token = heartbeatEndObserverToken {
            NotificationCenter.default.removeObserver(token)
            heartbeatEndObserverToken = nil
        }
        if let item = player.currentItem {
            heartbeatEndObserverToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
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
        if let token = heartbeatEndObserverToken {
            NotificationCenter.default.removeObserver(token)
            heartbeatEndObserverToken = nil
        }
        // Best-effort terminal beat for the *just-stopped* video so the
        // cloud history matches the actual stop position even if the
        // user dismissed without finishing.
        if !isCurrentSourceOffline, aid > 0, cid > 0, let position = player?.currentTime() {
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

    private func loadOfflineSource(
        _ offline: OfflinePlaybackSource,
        item: FeedItemDTO,
        generation: UInt64,
        startedAt: CFTimeInterval
    ) async throws {
        let info = offline.play
        AppLog.info("player", "命中离线缓存，优先使用本地播放源", metadata: [
            "aid": String(item.aid),
            "cid": String(item.cid),
            "qn": String(info.quality),
            "audioQn": String(info.audioQuality),
            "storageMode": offline.metadata.storageMode ?? "-",
            "directory": offline.directory.path,
        ])

        let qualities = normalizedQualities(from: info)
        availableQualities = qualities.isEmpty
            ? [(info.quality, qualityLabel(for: info.quality))]
            : qualities
        availableAudioQualities = normalizedAudioQualities(from: info)
        currentAudioQn = info.audioQuality
        pendingResumeMs = 0
        rememberPlayURL(info)

        let prep = try await engine.makeItem(for: info)
        guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else {
            prep.release()
            AppLog.debug("player", "丢弃过期离线播放器加载结果", metadata: [
                "aid": String(item.aid),
                "cid": String(item.cid),
            ])
            return
        }
        applyPresentationMetadata(to: prep.item, for: item)
        rememberActivePlayURL(info)
        currentQn = info.quality
        let player = AVPlayer(playerItem: prep.item)
        configureExternalPlayback(for: player)
        activePreparation = prep
        observeItemStatus(prep.item, generation: generation)
        setPlayer(player)
        applyPlaybackIntent(to: player)

        let startupMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        var meta = prep.logSummary
        meta["aid"] = String(item.aid)
        meta["cid"] = String(item.cid)
        meta["quality"] = String(info.quality)
        meta["available"] = availableQualities.map { String($0.qn) }.joined(separator: ",")
        meta["streamType"] = info.streamType
        meta["videoCodec"] = info.videoCodec.isEmpty ? "-" : info.videoCodec
        meta["audioCodec"] = info.audioCodec.isEmpty ? "-" : info.audioCodec
        meta["separateAudio"] = info.audioUrl == nil ? "false" : "true"
        meta["prepMs"] = String(prep.totalElapsedMs)
        meta["startupMs"] = String(startupMs)
        meta["source"] = "offline"
        AppLog.info("player", "离线播放器已就绪", metadata: meta)
    }

    /// item has buffered enough to render its first frame. The earlier
    /// generation guard ensures stale loads (rapid quality switches /
    /// dismissals) cannot resurrect a closed player.
    private func observeItemStatus(_ item: AVPlayerItem, generation: UInt64) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, !self.isClosing, self.loadGeneration == generation else { return }
                switch item.status {
                case .readyToPlay:
                    self.isPlaybackCompleted = false
                    self.isVideoReady = true
                    self.updatePausedForDetailCollapse()
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
                                guard !self.isClosing, self.loadGeneration == generation else { return }
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
                    let failedCacheVariant = self.playURLCacheVariant()
                    self.pageCache.removePlayURL(
                        qn: self.currentQn,
                        audioQn: self.currentAudioQn,
                        variant: failedCacheVariant
                    )
                    AppLog.error("player", "AVPlayerItem 失败", error: item.error, metadata: [
                        "detail": detail,
                        "videoCodec": self.currentVideoCodec.isEmpty ? "-" : self.currentVideoCodec,
                        "codecPreference": self.playbackCodecPreference,
                    ])
                    guard !self.isClosing, self.loadGeneration == generation else { return }
                    if self.isCurrentSourceOffline {
                        self.errorText = detail
                        self.isLoading = false
                        self.refreshSystemMediaSession()
                        return
                    }
                    await self.exportActiveDiagnostics(reason: "AVPlayerItem failed: \(detail)", generation: generation)
                    guard !self.isClosing, self.loadGeneration == generation else { return }
                    if self.shouldAttemptAVCRecovery() {
                        self.didAttemptAVCRecovery = true
                        self.playbackCodecPreference = "avc"
                        self.pageCache.removePlayURL(
                            qn: self.currentQn,
                            audioQn: self.currentAudioQn,
                            variant: self.playURLCacheVariant(codecPreference: "avc")
                        )
                        AppLog.warning("player", "尝试自动恢复播放(切换 H.264)", metadata: [
                            "detail": detail,
                            "failedCodec": self.currentVideoCodec.isEmpty ? "-" : self.currentVideoCodec,
                            "qn": String(self.currentQn),
                            "nextCodecPreference": self.playbackCodecPreference,
                        ])
                        Task { await self.reload() }
                        self.refreshSystemMediaSession()
                        return
                    }
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

    private func shouldAttemptAVCRecovery() -> Bool {
        guard playbackCodecPreference != "avc", !didAttemptAVCRecovery else { return false }
        let codec = currentVideoCodec.lowercased()
        return codec.hasPrefix("hev1")
            || codec.hasPrefix("hvc1")
            || codec.hasPrefix("dvh1")
            || codec.hasPrefix("dvhe")
            || codec.hasPrefix("av01")
    }

    private func exportActiveDiagnostics(reason: String, generation: UInt64) async {
        guard !isClosing, loadGeneration == generation, let preparation = activePreparation else { return }
        if let url = await preparation.exportDiagnostics(reason) {
            AppLog.info("player", "播放器失败诊断文件已导出", metadata: [
                "path": url.path,
                "qn": String(currentQn),
            ])
        }
    }

    private func fetchPlayUrl(aid: Int64, cid: Int64, qn: Int64) async throws -> PlayUrlDTO {
        try await fetchPlayUrl(aid: aid, bvid: bvid, cid: cid, qn: qn, audioQn: currentAudioQn)
    }

    private func fetchPlayUrl(for item: FeedItemDTO, qn: Int64) async throws -> PlayUrlDTO {
        try await fetchPlayUrl(for: item, qn: qn, audioQn: currentAudioQn)
    }

    private func fetchPlayUrl(for item: FeedItemDTO, qn: Int64, audioQn: Int64) async throws -> PlayUrlDTO {
        if item.isPGC {
            return try await fetchPgcPlayUrl(item: item, qn: qn, audioQn: audioQn)
        }
        return try await fetchPlayUrl(aid: item.aid, bvid: item.bvid, cid: item.cid, qn: qn, audioQn: audioQn)
    }

    private func fetchPlayUrl(aid: Int64, cid: Int64, qn: Int64, audioQn: Int64) async throws -> PlayUrlDTO {
        try await fetchPlayUrl(aid: aid, bvid: bvid, cid: cid, qn: qn, audioQn: audioQn)
    }

    private func fetchPlayUrl(aid: Int64, bvid: String, cid: Int64, qn: Int64, audioQn: Int64) async throws -> PlayUrlDTO {
        let cacheVariant = playURLCacheVariant()
        if self.aid == aid,
           self.cid == cid,
           let cached = pageCache.playURL(qn: qn, audioQn: audioQn, variant: cacheVariant) {
            AppLog.debug("player", "命中播放页缓存的播放地址", metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "qn": String(qn),
                "audioQn": String(audioQn),
                "codecPreference": playbackCodecPreference,
            ])
            return cached
        }
        let cdnSelection = self.cdnSelection
        let codecPreference = self.playbackCodecPreference
        let bvidSnapshot = bvid
        let info = try await Task.detached {
            try CoreClient.shared.playUrl(
                aid: aid,
                bvid: bvidSnapshot,
                cid: cid,
                qn: qn,
                audioQn: audioQn,
                cdn: cdnSelection,
                codecPreference: codecPreference
            )
        }.value
        rememberPlayURL(info)
        return info
    }

    private func fetchPgcPlayUrl(item: FeedItemDTO, qn: Int64, audioQn: Int64) async throws -> PlayUrlDTO {
        let cacheVariant = playURLCacheVariant()
        if self.aid == item.aid,
           self.cid == item.cid,
           let cached = pageCache.playURL(qn: qn, audioQn: audioQn, variant: cacheVariant) {
            AppLog.debug("player", "命中播放页缓存的 PGC 播放地址", metadata: [
                "aid": String(item.aid),
                "cid": String(item.cid),
                "epID": String(item.epID),
                "qn": String(qn),
                "audioQn": String(audioQn),
                "codecPreference": playbackCodecPreference,
            ])
            return cached
        }
        let cdnSelection = self.cdnSelection
        let codecPreference = self.playbackCodecPreference
        let info = try await Task.detached {
            try CoreClient.shared.pgcPlayUrl(
                aid: item.aid,
                cid: item.cid,
                epID: item.epID,
                seasonID: item.seasonID,
                qn: qn,
                audioQn: audioQn,
                cdn: cdnSelection,
                codecPreference: codecPreference
            )
        }.value
        rememberPlayURL(info)
        return info
    }

    private func rememberPlayURL(_ info: PlayUrlDTO) {
        currentVideoCodec = info.videoCodec
        pageCache.storePlayURL(info, variant: playURLCacheVariant())
    }

    private func rememberActivePlayURL(_ info: PlayUrlDTO) {
        currentVideoCodec = info.videoCodec
        isCurrentSourceOffline = info.url.hasPrefix("file://")
        availableSubtitles = info.subtitles
        viewPoints = info.viewPoints
    }

    private func playURLCacheVariant(codecPreference: String? = nil) -> String {
        "\(playbackCacheVariant)|codec=\(codecPreference ?? playbackCodecPreference)"
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
        guard !isClosing else { return true }
        guard !isRecoveringPlaybackFromPageCache else { return true }
        let cacheVariant = playURLCacheVariant()
        guard currentQn > 0,
              let info = pageCache.playURL(qn: currentQn, audioQn: currentAudioQn, variant: cacheVariant) else {
            AppLog.debug("player", "播放页缓存未命中，无法直接恢复播放源", metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "trigger": trigger,
                "qn": String(currentQn),
                "audioQn": String(currentAudioQn),
                "codecPreference": playbackCodecPreference,
            ])
            return false
        }

        guard !isClosing else { return true }
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
            "codecPreference": playbackCodecPreference,
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
            stopHeartbeat()
            itemStatusObservation = nil

            let previousPreparation = activePreparation
            let targetPlayer: AVPlayer
            if let existingPlayer = player {
                suppressNextObservedPlaybackIntent(.pause)
                existingPlayer.pause()
                endTemporarySpeedBoost(on: existingPlayer)
                clearPlaybackCompletionObserver()
                existingPlayer.replaceCurrentItem(with: nil)
                targetPlayer = existingPlayer
            } else {
                targetPlayer = AVPlayer(playerItem: prep.item)
                configureExternalPlayback(for: targetPlayer)
            }

            activePreparation = prep
            rememberActivePlayURL(info)
            observeItemStatus(prep.item, generation: generation)

            if player == nil {
                setPlayer(targetPlayer)
            } else {
                targetPlayer.replaceCurrentItem(with: prep.item)
                observePlaybackCompletion(for: targetPlayer)
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
                "codecPreference": playbackCodecPreference,
            ])
            return true
        } catch {
            guard !isClosing else { return true }
            pageCache.removePlayURL(qn: info.quality, audioQn: info.audioQuality, variant: cacheVariant)
            AppLog.warning("player", "播放页缓存恢复失败，已回退到常规重载路径", metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "trigger": trigger,
                "qn": String(info.quality),
                "audioQn": String(info.audioQuality),
                "codecPreference": playbackCodecPreference,
                "error": error.localizedDescription,
            ])
            return false
        }
    }

    private func isCurrentLoad(_ generation: UInt64, aid: Int64, cid: Int64) -> Bool {
        !isClosing && generation == loadGeneration && self.aid == aid && self.cid == cid
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
        var merged: [Int64: String] = [:]
        for (index, qn) in info.acceptAudioQuality.enumerated() {
            let explicitLabel = index < info.acceptAudioDescription.count ? info.acceptAudioDescription[index] : ""
            merged[qn] = explicitLabel.isEmpty ? audioQualityLabel(for: qn) : explicitLabel
        }
        if info.audioQuality > 0 {
            merged[info.audioQuality] = info.audioQualityLabel.isEmpty
                ? audioQualityLabel(for: info.audioQuality)
                : info.audioQualityLabel
        }
        return merged.keys
            .sorted { audioQualityRank($0) > audioQualityRank($1) }
            .map { ($0, merged[$0] ?? audioQualityLabel(for: $0)) }
    }

    private func audioQualityRank(_ qn: Int64) -> Int {
        switch qn {
        case 100010: return 800
        case 100009: return 700
        case 100008: return 600
        case 30251: return 500
        case 30250, 30255: return 400
        case 30280: return 300
        case 30232: return 200
        case 30216: return 100
        default: return 0
        }
    }

    private func audioQualityLabel(for qn: Int64) -> String {
        switch qn {
        case 100010: return "100010"
        case 100009: return "100009"
        case 100008: return "100008"
        case 30251: return "Hi-Res无损"
        case 30250, 30255: return "杜比全景声"
        case 30280: return "192K"
        case 30232: return "132K"
        case 30216: return "64K"
        default: return "音质 \(qn)"
        }
    }

    func switchAudioQuality(to audioQn: Int64) async {
        guard !isClosing, let player else { return }
        let generation = loadGeneration
        let resumeAt = player.currentTime()
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
            clearPlaybackCompletionObserver()
            player.replaceCurrentItem(with: nil)
            activePreparation?.release()
            activePreparation = nil
            let info: PlayUrlDTO
            if let item = lastLoadedItem {
                if let offline = OfflineDownloadService.shared.playbackSource(
                    for: item,
                    preferredQn: currentQn,
                    audioQn: audioQn
                ), offline.metadata.qn == currentQn, offline.metadata.audioQn == audioQn {
                    info = offline.play
                    AppLog.info("player", "音质切换命中离线缓存", metadata: [
                        "aid": String(item.aid),
                        "cid": String(item.cid),
                        "qn": String(currentQn),
                        "audioQn": String(audioQn),
                    ])
                } else {
                    info = try await fetchPlayUrl(for: item, qn: currentQn, audioQn: audioQn)
                }
            } else {
                info = try await fetchPlayUrl(aid: aid, cid: cid, qn: currentQn, audioQn: audioQn)
            }
            rememberPlayURL(info)
            guard isCurrentLoad(generation, aid: aid, cid: cid) else { return }
            let prep = try await engine.makeItem(for: info)
            guard isCurrentLoad(generation, aid: aid, cid: cid) else {
                prep.release()
                return
            }
            if let item = lastLoadedItem {
                applyPresentationMetadata(to: prep.item, for: item)
            }
            activePreparation = prep
            rememberActivePlayURL(info)
            observeItemStatus(prep.item, generation: generation)
            player.replaceCurrentItem(with: prep.item)
            observePlaybackCompletion(for: player)
            await player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            applyRate(to: player)
            applyPlaybackIntent(to: player)
            self.currentAudioQn = info.audioQuality
            self.availableAudioQualities = normalizedAudioQualities(from: info)
            AppLog.info("player", "音质切换成功", metadata: [
                "audioQuality": String(info.audioQuality),
                "audioQualityLabel": info.audioQualityLabel,
            ])
        } catch {
            guard !isClosing else { return }
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

// MARK: - Player view

struct PlayerNextPartCandidate: Equatable {
    let item: FeedItemDTO
    let label: String
}

private enum PlayerSheet: String, Identifiable {
    case danmakuSend
    case danmakuStyle
    case offlineDownload

    var id: String { rawValue }
}

struct PlayerView: View {
    private static let deferredDetailMountDelay: TimeInterval = 0.24
    private static let danmakuSegmentLengthSec: Double = 6 * 60
    private static let longDanmakuDurationThresholdSec: Int64 = 2 * 60 * 60

    let item: FeedItemDTO
    let offlineOnly: Bool
    @StateObject private var vm: PlayerViewModel
    private let onPictureInPictureActiveChange: ((Bool) -> Void)?
    private let onPictureInPictureRestore: (((@escaping (Bool) -> Void) -> Void))?
    /// Plain reference type — see `DanmakuController` notes.
    @State private var danmaku = DanmakuController()
    @State private var subtitle = SubtitleController()
    @State private var didBootstrap = false
    @State private var loadedMediaKey: String?
    /// Weak handle to the AVPlayerViewController for PiP and background audio handling.
    @State private var playerVCRef = PlayerVCBox()
    /// Long-press on the danmaku toggle opens this sheet for sending.
    @State private var activeSheet: PlayerSheet?
    @State private var subtitleEnabled = false
    @State private var subtitleLoadingID: String?
    @State private var selectedSubtitleID: String?
    /// Plain `let` on purpose (NOT `@StateObject`): this page only calls
    /// methods on the service and never reads its `@Published` state in
    /// `body`. Subscribing would re-render the page (and tear down the
    /// open toolbar `Menu`) every time a background download mutates
    /// `entries`.
    private let offlineService = OfflineDownloadService.shared
    @State private var playerActionToast: String?
    @State private var playerActionToastWork: DispatchWorkItem?
    /// One-shot transient hint that surfaces when the user enables
    /// danmaku, telling them they can long-press the toggle to send one.
    /// Suppressible via `AppSettings.showDanmakuSendHint`.
    @State private var danmakuHint: String?
    @State private var danmakuHintWork: DispatchWorkItem?
    @State private var deferredDetailMountWork: DispatchWorkItem?
    @State private var shouldMountDetailContent = false
    @State private var pendingDanmakuLoadKey: String?
    @State private var loadedDanmakuKey: String?
    @State private var danmakuLoadedSegments: Set<Int64> = []
    @State private var danmakuSegmentLoadTasks: [Int64: Task<Void, Never>] = [:]
    @State private var danmakuTimeObserver: Any?
    @State private var danmakuTimeObserverPlayer: AVPlayer?
    @State private var danmakuTimeJumpObserver: NSObjectProtocol?
    @State private var detailTimelineObserver: Any?
    @State private var detailTimelineObserverPlayer: AVPlayer?
    /// Held via `@State` (NOT `@StateObject`) so the per-second tick
    /// does not invalidate this view's `body`; rebuilding the body every
    /// second destroys the open toolbar `Menu` (flicker + dead taps).
    /// Only `VideoTimelineSection` down in the detail area observes it.
    @State private var detailTimelineClock = PlaybackTimelineClock()
    @State private var nextPartCandidate: PlayerNextPartCandidate?
    @State private var detailScrollOffsetForPlayerCollapse: CGFloat = 0
    @State private var isPlayerCollapseArmed = false
    @State private var playerCollapseAnchorOffset: CGFloat = 0
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation
    @Environment(\.rootContentNavigation) private var rootNavigation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.beginNativePlayerFullscreenExit) private var beginNativePlayerFullscreenExit
    @Environment(\.endNativePlayerFullscreenExit) private var endNativePlayerFullscreenExit

    init(item: FeedItemDTO,
         offlineOnly: Bool = false,
         viewModel: PlayerViewModel? = nil,
         onPictureInPictureActiveChange: ((Bool) -> Void)? = nil,
         onPictureInPictureRestore: (((@escaping (Bool) -> Void) -> Void))? = nil) {
        self.item = item
        self.offlineOnly = offlineOnly
        self.onPictureInPictureActiveChange = onPictureInPictureActiveChange
        self.onPictureInPictureRestore = onPictureInPictureRestore
        _vm = StateObject(wrappedValue: viewModel ?? PlayerViewModel())
    }

    private var mediaLoadKey: String {
        "\(item.isPGC ? "pgc" : "ugc"):\(item.aid):\(item.bvid):\(item.cid):\(item.epID)"
    }

    private func handlePresentationEvent(_ event: PlayerPresentationEvent) {
        switch event {
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
        case .nativeFullscreenWillBegin(let identity):
            guard presentationIdentityMatchesCurrentRoute(identity) else { return }
            beginNativePlayerFullscreenExit()
        case .nativeFullscreenDidBegin(let identity):
            guard presentationIdentityMatchesCurrentRoute(identity) else { return }
            endNativePlayerFullscreenExit()
        case .nativeFullscreenExitWillBegin(let identity, let shouldResumePlayback):
            guard presentationIdentityMatchesCurrentRoute(identity) else { return }
            beginNativePlayerFullscreenExit()
            vm.prepareForNativeFullscreenExit(shouldResumePlayback: shouldResumePlayback)
        case .nativeFullscreenExitDidEnd(let identity, let shouldResumePlayback):
            guard presentationIdentityMatchesCurrentRoute(identity) else { return }
            vm.completeNativeFullscreenExit(shouldResumePlayback: shouldResumePlayback)
            endNativePlayerFullscreenExit()
        }
    }

    private func presentationIdentityMatchesCurrentRoute(_ identity: PlayerPresentationIdentity) -> Bool {
        guard identity.sessionID == vm.currentSessionID else { return false }
        guard let currentPlayerID = vm.player.map(ObjectIdentifier.init),
              let incomingPlayerID = identity.playerID else { return true }
        return currentPlayerID == incomingPlayerID
    }

    private var canCollapsePlayerForDetailScroll: Bool {
        !offlineOnly
            && shouldMountDetailContent
            && vm.isPausedForDetailCollapse
            && isPlayerCollapseArmed
    }

    private func collapsedPlayerHeight(expandedHeight: CGFloat) -> CGFloat {
        min(expandedHeight, 72)
    }

    private func playerCollapseProgress(expandedHeight: CGFloat) -> CGFloat {
        guard canCollapsePlayerForDetailScroll else { return 0 }
        let collapsedHeight = collapsedPlayerHeight(expandedHeight: expandedHeight)
        let scrollDistance = max(60, expandedHeight - collapsedHeight)
        let scrollDeltaAfterPause = detailScrollOffsetForPlayerCollapse - playerCollapseAnchorOffset
        return min(max(scrollDeltaAfterPause / scrollDistance, 0), 1)
    }

    private func playerHeight(for width: CGFloat) -> CGFloat {
        let expandedHeight = width * 9.0 / 16.0
        let collapsedHeight = collapsedPlayerHeight(expandedHeight: expandedHeight)
        let progress = playerCollapseProgress(expandedHeight: expandedHeight)
        return expandedHeight - (expandedHeight - collapsedHeight) * progress
    }

    private func handleDetailScrollOffsetForPlayerCollapse(_ offset: CGFloat) {
        let clamped = max(0, offset)
        detailScrollOffsetForPlayerCollapse = clamped
        if vm.isPausedForDetailCollapse, !isPlayerCollapseArmed {
            isPlayerCollapseArmed = true
            playerCollapseAnchorOffset = clamped
        }
    }

    private func armPlayerCollapseFromCurrentScrollPosition() {
        guard vm.isPausedForDetailCollapse else {
            resetPlayerCollapseAnchor()
            return
        }
        isPlayerCollapseArmed = true
        playerCollapseAnchorOffset = detailScrollOffsetForPlayerCollapse
    }

    private func resetPlayerCollapseAnchor() {
        isPlayerCollapseArmed = false
        playerCollapseAnchorOffset = detailScrollOffsetForPlayerCollapse
    }

    private func expandCollapsedPlayerAndPlay() {
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.9, blendDuration: 0.12)) {
            playerCollapseAnchorOffset = detailScrollOffsetForPlayerCollapse
            isPlayerCollapseArmed = true
        }
        vm.handle(.playbackIntentChanged(.play))
    }

    @ViewBuilder
    private func collapsedPlayerButton(progress: CGFloat) -> some View {
        let visibility = min(max((progress - 0.42) / 0.58, 0), 1)
        Button(action: expandCollapsedPlayerAndPlay) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(IbiliTheme.accent)
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 1)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("继续播放")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IbiliTheme.textPrimary)
                    Text((vm.currentFeedItem ?? item).title)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
        .opacity(Double(visibility))
        .allowsHitTesting(progress > 0.72)
        .accessibilityLabel("继续播放")
    }

    private func resetSubtitleState() {
        subtitleEnabled = false
        subtitleLoadingID = nil
        selectedSubtitleID = nil
        subtitle.setTrack(nil)
        subtitle.setVisible(false)
    }

    private func handlePlaybackCompleted() {
        switch settings.completionBehavior {
        case .pause:
            vm.pauseForPlaybackCompletion()
        case .loop:
            vm.restartCurrentItem()
            flashPlayerAction("已循环播放")
        case .nextPart:
            guard let candidate = nextPartCandidate else {
                vm.pauseForPlaybackCompletion()
                flashPlayerAction("已是最后一 P")
                return
            }
            vm.handle(.prepareAutoplayForMediaReplacement)
            nextPartCandidate = nil
            openPlayer(candidate.item, mode: .replaceCurrent)
            flashPlayerAction("自动播放 \(candidate.label)")
        }
    }

    private func openPlayer(_ item: FeedItemDTO, mode: DeepLinkRouter.OpenMode = .push) {
        if isInPlayerHostNavigation {
            router.open(item, mode: mode)
        } else {
            rootNavigation.openPlayer(item, mode: mode)
        }
    }

    private func disableSubtitle() {
        resetSubtitleState()
    }

    private func selectSubtitle(_ track: VideoSubtitleDTO) async {
        guard subtitleLoadingID == nil else { return }
        let candidates = subtitleURLCandidates(for: track)
        guard !candidates.isEmpty else { return }
        subtitleLoadingID = track.id
        do {
            let subtitleTrack = try await loadSubtitleTrack(from: candidates)
            guard subtitleLoadingID == track.id else { return }
            selectedSubtitleID = track.id
            subtitleEnabled = true
            subtitle.setTrack(subtitleTrack)
            subtitle.setVisible(true)
            flashPlayerAction("字幕已切换")
        } catch {
            AppLog.error("player", "字幕加载失败", error: error, metadata: [
                "lan": track.lan,
                "sources": candidates.map { $0.label }.joined(separator: ","),
            ])
            if selectedSubtitleID == nil {
                subtitleEnabled = false
                subtitle.setVisible(false)
            }
            flashPlayerAction("字幕加载失败")
        }
        if subtitleLoadingID == track.id {
            subtitleLoadingID = nil
        }
    }

    private func subtitleURLCandidates(for track: VideoSubtitleDTO) -> [(label: String, url: String)] {
        var seen = Set<String>()
        var candidates: [(label: String, url: String)] = []
        func append(_ label: String, _ raw: String) {
            let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, seen.insert(url).inserted else { return }
            candidates.append((label: label, url: url))
        }
        // PiliPlus still fetches `subtitle_url`; keep v2 as a fallback
        // because some subtitle_url_v2 hosts fail TLS on-device.
        append("subtitle_url", track.subtitleUrl)
        append("subtitle_url_v2", track.subtitleUrlV2)
        return candidates
    }

    private func loadSubtitleTrack(from candidates: [(label: String, url: String)]) async throws -> SubtitleTrackDTO {
        var lastError: Error?
        for candidate in candidates {
            do {
                let track = try await CoreClient.shared.subtitleTrack(from: candidate.url)
                guard !track.items.isEmpty else {
                    lastError = URLError(.zeroByteResource)
                    AppLog.error("player", "字幕候选为空", error: lastError!, metadata: [
                        "source": candidate.label,
                    ])
                    continue
                }
                AppLog.info("player", "字幕加载成功", metadata: [
                    "source": candidate.label,
                    "count": String(track.items.count),
                ])
                return track
            } catch {
                lastError = error
                AppLog.error("player", "字幕候选加载失败", error: error, metadata: [
                    "source": candidate.label,
                ])
            }
        }
        throw lastError ?? URLError(.badURL)
    }

    private func seekTo(seconds: Int64) {
        guard let player = vm.player else { return }
        let target = CMTime(seconds: Double(max(0, seconds)), preferredTimescale: 600)
        Task { @MainActor in
            detailTimelineClock.seconds = Double(max(0, seconds))
            detailTimelineClock.lastWholeSecond = seconds
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            if player.rate == 0 {
                vm.handle(.playbackIntentChanged(.play))
            }
        }
    }

    private var offlineDetailPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(IbiliTheme.accent)
                Text("离线播放")
                    .font(.headline)
                Spacer()
            }
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IbiliTheme.textPrimary)
                .lineLimit(3)
            if !item.author.isEmpty {
                Text(item.author)
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IbiliTheme.background)
    }

    var body: some View {
        GeometryReader { proxy in
            let playerWidth = proxy.size.width
            let expandedPlayerHeight = playerWidth * 9.0 / 16.0
            let collapseProgress = playerCollapseProgress(expandedHeight: expandedPlayerHeight)
            let visiblePlayerHeight = playerHeight(for: playerWidth)
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    ZStack {
                        Color.black
                        if let p = vm.player {
                            PlayerContainer(
                                player: p,
                                sessionID: vm.currentSessionID,
                                title: item.title,
                                danmaku: danmaku,
                                subtitle: subtitle,
                                subtitleEnabled: subtitleEnabled,
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
                                shouldResumePlaybackAfterNativeFullscreenExit: { vm.shouldResumePlaybackAfterNativeFullscreenExit },
                                onCreated: { vc in playerVCRef.vc = vc },
                                onPresentationEvent: handlePresentationEvent
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
                    .frame(width: playerWidth, height: expandedPlayerHeight)
                    .opacity(Double(max(0, 1 - collapseProgress * 1.6)))
                    .allowsHitTesting(collapseProgress < 0.78)

                    collapsedPlayerButton(progress: collapseProgress)
                }
                .frame(width: playerWidth, height: visiblePlayerHeight, alignment: .top)
                .clipped()
                .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.9, blendDuration: 0.08), value: vm.isPausedForDetailCollapse)

                if offlineOnly {
                    offlineDetailPlaceholder
                } else if shouldMountDetailContent {
                    VideoDetailContent(item: item,
                                       currentCid: vm.currentCid,
                                       currentSeasonID: vm.currentSeasonID,
                                       currentEpisodeID: vm.currentEpisodeID,
                                   detailViewModel: vm.pageCache.detailViewModel,
                                   commentListViewModel: vm.pageCache.commentListViewModel,
                                   interactionService: vm.pageCache.interactionService,
                                   viewPoints: vm.viewPoints,
                                   playbackTimeline: detailTimelineClock,
                                   onSeekToTime: { seconds in seekTo(seconds: seconds) },
                                   onNextPartCandidateChange: { candidate in
                                       nextPartCandidate = candidate
                                   },
                                   onScrollOffsetChange: handleDetailScrollOffsetForPlayerCollapse)
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
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .background(IbiliTheme.background.ignoresSafeArea(.container, edges: .bottom))
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            playerToolbar
        }
        .onChange(of: activeSheet?.id) { newValue in
            logPlayerMenu("菜单 sheet 状态变化", metadata: [
                "activeSheet": newValue ?? "nil",
            ])
        }
        .onChange(of: settings.completionBehavior) { newValue in
            logPlayerMenu("播放完行为状态已观察到变化", metadata: [
                "value": newValue.rawValue,
            ])
        }
        .task(id: mediaLoadKey) {
            if !didBootstrap {
                didBootstrap = true
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
            nextPartCandidate = nil
            loadedDanmakuKey = nil
            pendingDanmakuLoadKey = mediaLoadKey
            resetSubtitleState()
            resetDanmakuSegmentLoading()
            await vm.load(item: item,
                          preferredQn: Int64(settings.resolvedPreferredVideoQn()),
                          preferredAudioQn: Int64(settings.resolvedPreferredAudioQn()),
                          cdnSelection: settings.cdnService.rawValue,
                          cacheVariant: settings.playbackCacheVariantKey(),
                          offlineOnly: offlineOnly)
            vm.handle(.interfaceActivated)
        }
        .onChange(of: vm.isVideoReady) { ready in
            guard ready else { return }
            if let p = vm.player {
                configureDanmakuSegmentObserver(for: p)
            }
            loadPendingDanmakuIfNeeded()
        }
        .onChange(of: vm.player) { newPlayer in
            if let p = newPlayer {
                vm.setAudioVolumeLinear(settings.resolvedAudioVolumeLinear())
                danmaku.attach(p)
                subtitle.attach(p)
                configureDanmakuSegmentObserver(for: p)
                configureDetailTimelineObserver(for: p)
                vm.handle(.interfaceActivated)
                if vm.isVideoReady {
                    loadPendingDanmakuIfNeeded()
                }
            } else {
                clearDanmakuTimeObserver()
                clearDetailTimelineObserver()
                subtitle.detach()
            }
        }
        .onChange(of: vm.availableSubtitles) { subtitles in
            guard let selectedSubtitleID,
                  !subtitles.contains(where: { $0.id == selectedSubtitleID }) else {
                return
            }
            disableSubtitle()
        }
        .onChange(of: vm.isPausedForDetailCollapse) { paused in
            if paused {
                armPlayerCollapseFromCurrentScrollPosition()
            } else {
                resetPlayerCollapseAnchor()
            }
        }
        .onChange(of: vm.playbackCompletionSignal) { _ in
            handlePlaybackCompleted()
        }
        .onChange(of: settings.cdnService.rawValue) { _ in
            PlayUrlPrefetcher.shared.clear()
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
        .onAppear {
            AppLog.debug("player", "播放器页面 onAppear", metadata: [
                "aid": String(vm.currentAid),
                "cid": String(vm.currentCid),
            ])
            PlayerViewLifecycleController.handleAppear(
                didBootstrap: didBootstrap,
                viewModel: vm,
                danmaku: danmaku,
                resolvedAudioVolumeLinear: settings.resolvedAudioVolumeLinear()
            )
        }
        .onDisappear {
            AppLog.debug("player", "播放器页面 onDisappear", metadata: [
                "aid": String(vm.currentAid),
                "cid": String(vm.currentCid),
            ])
            deferredDetailMountWork?.cancel()
            deferredDetailMountWork = nil
            PlayerViewLifecycleController.handleDisappear(viewModel: vm)
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
        .overlay(alignment: .top) {
            if let message = playerActionToast {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(.top, 48)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: danmakuHint)
        .animation(.easeInOut(duration: 0.2), value: playerActionToast)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .danmakuSend:
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
            case .danmakuStyle:
                DanmakuStyleSettingsView()
                    .environmentObject(settings)
            case .offlineDownload:
                OfflineDownloadSheet(
                    item: vm.currentFeedItem ?? item,
                    qualities: vm.availableQualities,
                    currentQn: vm.currentQn,
                    audioQualities: vm.availableAudioQualities,
                    currentAudioQn: vm.currentAudioQn,
                    cdn: settings.cdnService.rawValue,
                    onStart: { request in
                        offlineService.start(request)
                        activeSheet = nil
                        flashPlayerAction("已加入离线缓存")
                    }
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var playerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            PlayerToolbarDanmaku(
                danmakuEnabled: $settings.danmakuEnabled,
                isEnabled: vm.player != nil,
                onLongPress: { activeSheet = .danmakuSend }
            )
        }
        ToolbarItem(placement: .topBarTrailing) {
            PlayerToolbarSubtitle(
                subtitles: vm.availableSubtitles,
                selectedID: selectedSubtitleID,
                isEnabled: vm.player != nil,
                isLoadingID: subtitleLoadingID,
                onPick: { track in
                    logPlayerMenu("选择字幕", metadata: [
                        "subtitleID": track.id,
                        "subtitleLanguage": track.lan,
                    ])
                    Task { await selectSubtitle(track) }
                },
                onDisable: {
                    logPlayerMenu("关闭字幕")
                    disableSubtitle()
                },
                onOpen: {
                    logPlayerMenu("打开字幕菜单", metadata: [
                        "subtitleCount": String(vm.availableSubtitles.count),
                    ])
                }
            )
        }
        ToolbarItem(placement: .topBarTrailing) {
            PlayerToolbarVideoQuality(
                qualities: vm.availableQualities,
                currentQn: vm.currentQn,
                onPick: { qn in
                    logPlayerMenu("选择画质", metadata: [
                        "qn": String(qn),
                    ])
                    Task { await vm.switchQuality(to: qn) }
                },
                onOpen: {
                    logPlayerMenu("打开画质菜单", metadata: [
                        "qualityCount": String(vm.availableQualities.count),
                    ])
                }
            )
        }
        ToolbarItem(placement: .topBarTrailing) {
            PlayerToolbarOverflowMenu(
                audioQualities: vm.availableAudioQualities,
                currentAudioQn: vm.currentAudioQn,
                completionBehavior: settings.completionBehavior,
                isEnabled: vm.player != nil,
                onPickAudioQuality: { qn in
                    if let quality = vm.availableAudioQualities.first(where: { $0.qn == qn }) {
                        selectAudioQuality(quality)
                    } else {
                        logPlayerMenu("选择音质", metadata: [
                            "audioQn": String(qn),
                            "label": "",
                        ])
                        Task { await vm.switchAudioQuality(to: qn) }
                    }
                },
                onSelectCompletionBehavior: { behavior in
                    selectCompletionBehavior(behavior)
                },
                onOpenOfflineDownload: {
                    presentPlayerSheet(.offlineDownload, logMessage: "打开离线缓存")
                },
                onOpenDanmakuStyle: {
                    presentPlayerSheet(.danmakuStyle, logMessage: "打开弹幕样式")
                },
                onSaveCover: {
                    logPlayerMenu("保存封面请求")
                    saveCurrentCover()
                },
                onOpen: {
                    logPlayerMenu("打开更多菜单", metadata: [
                        "isDisabled": String(vm.player == nil),
                        "completionBehavior": settings.completionBehavior.rawValue,
                        "availableAudioCount": String(vm.availableAudioQualities.count),
                    ])
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

    private func saveCurrentCover() {
        let cover = (vm.currentFeedItem ?? item).cover
        logPlayerMenu("保存封面任务开始", metadata: [
            "coverEmpty": String(cover.isEmpty),
            "cover": cover,
        ])
        Task {
            do {
                try await offlineService.saveCoverToPhotos(urlString: cover)
                await MainActor.run {
                    logPlayerMenu("保存封面成功")
                    flashPlayerAction("封面已保存到相册")
                }
            } catch {
                await MainActor.run {
                    AppLog.error("player.menu", "保存封面失败", error: error, metadata: playerMenuMetadata())
                    flashPlayerAction((error as? LocalizedError)?.errorDescription ?? "封面保存失败")
                }
            }
        }
    }

    private func presentPlayerSheet(_ sheet: PlayerSheet, logMessage: String) {
        logPlayerMenu(logMessage)
        activeSheet = sheet
    }

    private func selectAudioQuality(_ quality: (qn: Int64, label: String)) {
        logPlayerMenu("选择音质", metadata: [
            "audioQn": String(quality.qn),
            "label": quality.label,
        ])
        Task {
            await vm.switchAudioQuality(to: quality.qn)
        }
    }

    private func selectCompletionBehavior(_ behavior: PlayerCompletionBehavior) {
        let oldValue = settings.completionBehavior
        logPlayerMenu("选择播放完行为", metadata: [
            "oldValue": oldValue.rawValue,
            "newValue": behavior.rawValue,
        ])
        settings.completionBehavior = behavior
        logPlayerMenu("播放完行为写入完成", metadata: [
            "oldValue": oldValue.rawValue,
            "newValue": settings.completionBehavior.rawValue,
        ])
    }

    private func logPlayerMenu(_ message: String, metadata: [String: String] = [:]) {
        AppLog.info("player.menu", message, metadata: playerMenuMetadata(extra: metadata))
    }

    private func playerMenuMetadata(extra: [String: String] = [:]) -> [String: String] {
        var metadata = [
            "aid": String(vm.currentAid),
            "cid": String(vm.currentCid),
            "hasPlayer": String(vm.player != nil),
            "currentQn": String(vm.currentQn),
            "currentAudioQn": String(vm.currentAudioQn),
            "completionBehavior": settings.completionBehavior.rawValue,
            "activeSheet": activeSheet?.id ?? "nil",
        ]
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }

    private func flashPlayerAction(_ message: String) {
        playerActionToast = message
        playerActionToastWork?.cancel()
        let work = DispatchWorkItem { playerActionToast = nil }
        playerActionToastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
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
                     text: settings.danmakuEnabled ? "弹幕" : "弹幕关",
                     tint: settings.danmakuEnabled ? IbiliTheme.accent : .white)
            }

            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func chip(icon: String, text: String, tint: Color = .primary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).font(.subheadline.weight(.medium))
        }
        .foregroundStyle(tint)
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
            guard resolvedItem.cid > 0 else { return }
            if let offlineItems = OfflineDownloadService.shared.danmakuItems(for: resolvedItem) {
                vm.pageCache.storeDanmaku(offlineItems, for: resolvedItem.cid)
                danmaku.setItems(offlineItems)
                if let p = vm.player { danmaku.attach(p) }
                AppLog.info("danmaku", "命中离线弹幕", metadata: [
                    "cid": String(resolvedItem.cid),
                    "count": String(offlineItems.count),
                ])
                return
            }
            guard !offlineOnly else {
                AppLog.warning("danmaku", "离线播放未找到本地弹幕，跳过联网加载", metadata: [
                    "cid": String(resolvedItem.cid),
                ])
                return
            }
            guard !usesSegmentedDanmaku(resolvedItem) else {
                await MainActor.run {
                    if let p = vm.player {
                        danmaku.attach(p)
                        configureDanmakuSegmentObserver(for: p)
                    }
                    scheduleDanmakuSegmentsAroundCurrentTime(for: resolvedItem)
                }
                return
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
                "isPGC": String(resolvedItem.isPGC),
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

    private func loadPendingDanmakuIfNeeded() {
        guard let key = pendingDanmakuLoadKey,
              key == mediaLoadKey,
              loadedDanmakuKey != key else {
            return
        }
        loadedDanmakuKey = key
        Task { await loadDanmaku() }
    }

    private func usesSegmentedDanmaku(_ item: FeedItemDTO) -> Bool {
        !item.isPGC && item.durationSec >= Self.longDanmakuDurationThresholdSec
    }

    private func configureDanmakuSegmentObserver(for player: AVPlayer) {
        clearDanmakuTimeObserver()
        let interval = CMTime(seconds: 8, preferredTimescale: 600)
        danmakuTimeObserverPlayer = player
        danmakuTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak vm] time in
            guard let current = vm?.currentFeedItem else { return }
            Task { @MainActor in
                guard current.cid == self.vm.currentCid,
                      self.usesSegmentedDanmaku(current),
                      self.loadedDanmakuKey == self.mediaLoadKey else { return }
                let seconds = time.seconds.isFinite ? max(0, time.seconds) : 0
                self.scheduleDanmakuSegments(around: seconds, for: current)
            }
        }
        danmakuTimeJumpObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped,
            object: player.currentItem,
            queue: .main
        ) { [weak vm] _ in
            guard let current = vm?.currentFeedItem else { return }
            Task { @MainActor in
                guard current.cid == self.vm.currentCid,
                      self.usesSegmentedDanmaku(current),
                      self.loadedDanmakuKey == self.mediaLoadKey else { return }
                self.scheduleDanmakuSegmentsAroundCurrentTime(for: current)
            }
        }
    }

    private func clearDanmakuTimeObserver() {
        if let observer = danmakuTimeObserver, let player = danmakuTimeObserverPlayer {
            player.removeTimeObserver(observer)
        }
        danmakuTimeObserver = nil
        danmakuTimeObserverPlayer = nil
        if let observer = danmakuTimeJumpObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        danmakuTimeJumpObserver = nil
    }

    private func configureDetailTimelineObserver(for player: AVPlayer) {
        clearDetailTimelineObserver()
        detailTimelineObserverPlayer = player
        let clock = detailTimelineClock
        if let seconds = vm.currentElapsedPlaybackTime {
            clock.seconds = seconds
        }
        detailTimelineObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.6, preferredTimescale: 600),
            queue: .main
        ) { time in
            Task { @MainActor in
                let seconds = time.seconds
                guard seconds.isFinite, seconds >= 0 else { return }
                let wholeSecond = Int64(seconds.rounded(.down))
                guard wholeSecond != clock.lastWholeSecond else { return }
                clock.lastWholeSecond = wholeSecond
                clock.seconds = seconds
            }
        }
    }

    private func clearDetailTimelineObserver() {
        if let observer = detailTimelineObserver, let player = detailTimelineObserverPlayer {
            player.removeTimeObserver(observer)
        }
        detailTimelineObserver = nil
        detailTimelineObserverPlayer = nil
        detailTimelineClock.lastWholeSecond = -1
    }

    private func resetDanmakuSegmentLoading() {
        cancelDanmakuSegmentTasks()
        danmakuLoadedSegments.removeAll()
    }

    private func cancelDanmakuSegmentTasks() {
        danmakuSegmentLoadTasks.values.forEach { $0.cancel() }
        danmakuSegmentLoadTasks.removeAll()
    }

    private func scheduleDanmakuSegmentsAroundCurrentTime(for item: FeedItemDTO) {
        let seconds = vm.player?.currentTime().seconds ?? 0
        scheduleDanmakuSegments(around: seconds.isFinite ? max(0, seconds) : 0, for: item)
    }

    private func scheduleDanmakuSegments(around seconds: Double, for item: FeedItemDTO) {
        guard usesSegmentedDanmaku(item), item.cid > 0 else { return }
        let current = danmakuSegmentIndex(for: seconds)
        loadDanmakuSegment(current, for: item)
        let maxSegment = max(Int64(1), Int64(ceil(Double(item.durationSec) / Self.danmakuSegmentLengthSec)))
        if current < maxSegment {
            loadDanmakuSegment(current + 1, for: item)
        }
    }

    private func danmakuSegmentIndex(for seconds: Double) -> Int64 {
        max(1, Int64(floor(seconds / Self.danmakuSegmentLengthSec)) + 1)
    }

    private func loadDanmakuSegment(_ segmentIndex: Int64, for item: FeedItemDTO) {
        guard segmentIndex > 0,
              !danmakuLoadedSegments.contains(segmentIndex),
              danmakuSegmentLoadTasks[segmentIndex] == nil else {
            return
        }
        if let cached = vm.pageCache.danmakuSegment(cid: item.cid, segmentIndex: segmentIndex) {
            danmakuLoadedSegments.insert(segmentIndex)
            danmaku.mergeItems(cached)
            if let p = vm.player { danmaku.attach(p) }
            return
        }

        let key = mediaLoadKey
        let cid = item.cid
        danmakuSegmentLoadTasks[segmentIndex] = Task {
            do {
                AppLog.info("danmaku", "开始加载分段弹幕", metadata: [
                    "cid": String(cid),
                    "segment": String(segmentIndex),
                ])
                let sortedItems = try await Task.detached(priority: .utility) {
                    try CoreClient.shared.danmakuSegment(cid: cid, segmentIndex: segmentIndex)
                        .items
                        .sorted { $0.timeSec < $1.timeSec }
                }.value
                await MainActor.run {
                    guard key == mediaLoadKey, cid == vm.currentCid else { return }
                    danmakuSegmentLoadTasks[segmentIndex] = nil
                    danmakuLoadedSegments.insert(segmentIndex)
                    vm.pageCache.storeDanmakuSegment(sortedItems, cid: cid, segmentIndex: segmentIndex)
                    danmaku.mergeItems(sortedItems)
                    if let p = vm.player { danmaku.attach(p) }
                    AppLog.info("danmaku", "分段弹幕加载完成", metadata: [
                        "cid": String(cid),
                        "segment": String(segmentIndex),
                        "count": String(sortedItems.count),
                    ])
                }
            } catch {
                await MainActor.run {
                    guard key == mediaLoadKey else { return }
                    danmakuSegmentLoadTasks[segmentIndex] = nil
                    AppLog.error("danmaku", "分段弹幕加载失败", error: error, metadata: [
                        "cid": String(cid),
                        "segment": String(segmentIndex),
                    ])
                }
            }
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
