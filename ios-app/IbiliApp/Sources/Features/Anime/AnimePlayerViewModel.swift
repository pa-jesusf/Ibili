import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

@MainActor
final class AnimePlayerViewModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var currentPlay: AnimePlayUrlDTO?
    @Published private(set) var currentCandidateID: String?
    @Published private(set) var candidates: [AnimeMediaCandidateDTO] = []
    @Published private(set) var diagnostics: AnimeMediaFetchDiagnosticsDTO?
    @Published private(set) var isLoading = false
    @Published private(set) var isSearchingMore = false
    @Published private(set) var isResolving = false
    @Published var errorText: String?
    let webResolveRequests = PassthroughSubject<AnimeWebVideoResolveRequest, Never>()

    let danmaku = DanmakuController()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var itemNotificationObservers: [NSObjectProtocol] = []
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemLikelyToKeepUpObservation: NSKeyValueObservation?
    private var itemEmptyBufferObservation: NSKeyValueObservation?
    private var playerTimeControlObservation: NSKeyValueObservation?
    private var markedWatched = false
    private weak var observedPlayer: AVPlayer?
    private var loadGeneration = UUID()
    private var pendingWebResolvers: [UUID: CheckedContinuation<AnimeWebVideoResolveResult, Never>] = [:]
    private var activeRoute: DeepLinkRouter.AnimePlayerRoute?
    private var triedCandidateIDs = Set<String>()
    private var failedPlayURLs = Set<String>()
    private var didReachReadyToPlay = false
    private var isAutoSelecting = false
    private var fetchSession: AnimeMediaFetchSession?
    private var sessionSnapshotTask: Task<Void, Never>?

    func load(
        route: DeepLinkRouter.AnimePlayerRoute,
        enabledSourcesProvider: () -> [AnimeSourceDTO]
    ) async {
        loadGeneration = UUID()
        let generation = loadGeneration
        errorText = nil
        candidates = []
        diagnostics = nil
        currentCandidateID = nil
        isSearchingMore = false
        markedWatched = false
        activeRoute = route
        triedCandidateIDs = []
        failedPlayURLs = []
        didReachReadyToPlay = false
        isAutoSelecting = false
        stop(keepState: false)

        if let play = route.initialPlay {
            await startPlayback(play: play, route: route, generation: generation)
            return
        }
        await refresh(
            route: route,
            enabledSourcesProvider: enabledSourcesProvider,
            generation: generation
        )
    }

    func refresh(
        route: DeepLinkRouter.AnimePlayerRoute,
        enabledSourcesProvider: () -> [AnimeSourceDTO],
        generation: UUID? = nil
    ) async {
        let activeGeneration: UUID
        if let generation {
            activeGeneration = generation
        } else {
            loadGeneration = UUID()
            activeGeneration = loadGeneration
        }
        stop(keepState: false)
        isLoading = true
        isSearchingMore = true
        errorText = nil
        activeRoute = route
        candidates = []
        currentCandidateID = nil
        triedCandidateIDs = []
        failedPlayURLs = []
        didReachReadyToPlay = false
        isAutoSelecting = false
        markedWatched = false
        let enabledSources = enabledSourcesProvider()
        diagnostics = Self.placeholderDiagnostics(for: enabledSources)
        let names = [route.subject.nameCn, route.subject.name] + route.subject.aliases
        AppLog.info("anime", "追番播放页开始会话式检索资源", metadata: [
            "subjectID": String(route.subject.id),
            "episodeID": String(route.episode.id),
            "episodeSort": String(format: "%.2f", route.episode.sort),
            "episodeTitle": route.episode.displayTitle,
            "keywordPreview": names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(4).joined(separator: " | "),
            "enabledSources": String(enabledSources.count),
        ])
        let sourceJSONByID = Self.buildSourceJSONMap(for: enabledSources)
        let session = AnimeMediaFetchSession(
            route: route,
            sources: enabledSources,
            sourceJSONByID: sourceJSONByID
        )
        bind(session: session, route: route, generation: activeGeneration)
        fetchSession = session
        await session.start()
    }

    func play(candidate: AnimeMediaCandidateDTO, route: DeepLinkRouter.AnimePlayerRoute) async {
        guard shouldAttemptCandidate(candidate) else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            let play = try await resolveCandidate(candidate, route: route)
            AppLog.info("anime", "追番手动选择候选资源", metadata: candidateMetadata(candidate, route: route, extra: [
                "resolvedFormat": play.format,
                "resolvedURL": Self.redactedURL(play.url),
                "resolvedHeaders": Self.redactedHeaderSummary(play.headers),
            ]))
            loadGeneration = UUID()
            await startPlayback(play: play, route: route, generation: loadGeneration, candidateID: candidate.id)
        } catch {
            errorText = error.localizedDescription
            AppLog.error("anime", "追番手动选择候选资源失败", error: error, metadata: candidateMetadata(candidate, route: route))
        }
    }

    func retryAfterCaptchaSolved(
        sourceID: String,
        route: DeepLinkRouter.AnimePlayerRoute,
        session: AnimeCaptchaSessionDTO
    ) async {
        let generation = loadGeneration
        isResolving = true
        isSearchingMore = true
        defer { isResolving = false }
        AppLog.info("anime", "追番验证码完成，重启单个数据源检索", metadata: [
            "subjectID": String(route.subject.id),
            "episodeID": String(route.episode.id),
            "sourceID": sourceID,
            "finalURL": Self.redactedURL(session.finalURL),
            "htmlBytes": String(session.html.utf8.count),
        ])
        await fetchSession?.restartSource(sourceID, captchaSession: session)
        guard generation == loadGeneration else { return }
    }

    func stop() {
        stop(keepState: false)
    }

    private func bind(
        session: AnimeMediaFetchSession,
        route: DeepLinkRouter.AnimePlayerRoute,
        generation: UUID
    ) {
        sessionSnapshotTask?.cancel()
        sessionSnapshotTask = Task { [weak self, weak session] in
            guard let session else { return }
            for await snapshot in session.snapshots {
                await MainActor.run {
                    self?.applySessionSnapshot(snapshot, route: route, generation: generation)
                }
            }
        }
    }

    private func applySessionSnapshot(
        _ snapshot: AnimeMediaSessionSnapshotDTO,
        route: DeepLinkRouter.AnimePlayerRoute,
        generation: UUID
    ) {
        guard generation == loadGeneration else { return }
        candidates = snapshot.candidates
        diagnostics = snapshot.diagnostics
        isSearchingMore = !snapshot.isComplete
        isLoading = currentPlay == nil && !snapshot.isComplete
        AppLog.debug("anime", "追番播放页会话快照", metadata: [
            "subjectID": String(route.subject.id),
            "episodeID": String(route.episode.id),
            "complete": snapshot.isComplete ? "true" : "false",
            "candidateCount": String(snapshot.candidates.count),
            "supportedCandidates": String(snapshot.diagnostics.supportedCandidates),
            "sourceReports": Self.sourceReportSummary(snapshot.diagnostics.sourceReports),
        ])
        let playable = candidates.filter(shouldAttemptCandidate(_:))
        if currentPlay == nil, !isAutoSelecting, !playable.isEmpty {
            isAutoSelecting = true
            Task { @MainActor in
                let didStart = await startFirstPlayable(from: playable, route: route, generation: generation)
                isAutoSelecting = false
                if didStart {
                    isLoading = false
                    errorText = nil
                } else if snapshot.isComplete, currentPlay == nil {
                    isLoading = false
                    errorText = "没有找到可播放资源"
                }
            }
        } else if snapshot.isComplete, !isAutoSelecting {
            isLoading = false
            if currentPlay == nil {
                errorText = "没有找到可播放资源"
            }
        }
    }

    private func stop(keepState: Bool) {
        if let timeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        itemNotificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        itemStatusObservation?.invalidate()
        itemLikelyToKeepUpObservation?.invalidate()
        itemEmptyBufferObservation?.invalidate()
        playerTimeControlObservation?.invalidate()
        if !keepState {
            sessionSnapshotTask?.cancel()
            sessionSnapshotTask = nil
            fetchSession?.cancel()
            fetchSession = nil
        }
        timeObserver = nil
        endObserver = nil
        itemNotificationObservers = []
        itemStatusObservation = nil
        itemLikelyToKeepUpObservation = nil
        itemEmptyBufferObservation = nil
        playerTimeControlObservation = nil
        observedPlayer = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if !keepState {
            currentPlay = nil
            currentCandidateID = nil
            isAutoSelecting = false
            resolvePendingWebRequests(errorText: "播放器会话已停止")
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func handleWebResolveResult(_ result: AnimeWebVideoResolveResult, route: DeepLinkRouter.AnimePlayerRoute) async {
        guard let continuation = pendingWebResolvers.removeValue(forKey: result.requestID) else {
            AppLog.warning("anime", "追番 WebView 嗅探结果丢弃：请求已失效", metadata: [
                "subjectID": String(route.subject.id),
                "episodeID": String(route.episode.id),
                "requestID": result.requestID.uuidString,
                "success": result.play == nil ? "false" : "true",
                "method": result.method,
            ])
            return
        }
        continuation.resume(returning: result)
    }

    private func startPlayback(
        play: AnimePlayUrlDTO,
        route: DeepLinkRouter.AnimePlayerRoute,
        generation: UUID,
        candidateID: String? = nil
    ) async {
        guard generation == loadGeneration else { return }
        stop(keepState: true)
        currentPlay = play
        currentCandidateID = candidateID
        didReachReadyToPlay = false
        guard let url = URL(string: play.url) else {
            errorText = "播放地址无效"
            return
        }
        var headers = play.headers
        headers["User-Agent"] = headers["User-Agent"] ?? headers["user-agent"] ?? (play.userAgent.isEmpty ? BiliHTTP.headers["User-Agent"] ?? "" : play.userAgent)
        if !play.referer.isEmpty {
            headers["Referer"] = headers["Referer"] ?? headers["referer"] ?? play.referer
        }
        headers["Accept"] = headers["Accept"] ?? "*/*"
        if headers.isEmpty {
            headers = [
            "User-Agent": play.userAgent.isEmpty ? BiliHTTP.headers["User-Agent"] ?? "" : play.userAgent,
            ]
        }
        AppLog.info("anime", "追番播放资源准备", metadata: [
            "subjectID": String(route.subject.id),
            "episodeID": String(route.episode.id),
            "format": play.format,
            "url": Self.redactedURL(play.url),
            "host": url.host ?? "",
            "pathExtension": url.pathExtension,
            "headers": Self.redactedHeaderSummary(headers),
            "hasCookie": Self.hasHeader("Cookie", in: headers) ? "true" : "false",
            "refererHost": URL(string: headers["Referer"] ?? headers["referer"] ?? "")?.host ?? "",
        ])
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = [
            metadata(.commonIdentifierTitle, value: play.title),
        ].compactMap { $0 }
        let nextPlayer = AVPlayer(playerItem: item)
        nextPlayer.allowsExternalPlayback = true
        nextPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
        nextPlayer.volume = AppSettings.shared.resolvedAudioVolumeLinear()
        PlayerAudioSessionCoordinator.shared.setSessionNeeded(true, by: self)
        player = nextPlayer
        configureNowPlaying(play: play, route: route)
        observeProgress(player: nextPlayer, route: route)
        observePlaybackDiagnostics(player: nextPlayer, item: item, play: play, route: route)
        nextPlayer.play()
    }

    private func observeProgress(player: AVPlayer, route: DeepLinkRouter.AnimePlayerRoute) {
        observedPlayer = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.handleProgress(time.seconds, player: player, route: route)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.markWatched(route: route)
            }
        }
    }

    private func handleProgress(_ seconds: Double, player: AVPlayer, route: DeepLinkRouter.AnimePlayerRoute) {
        guard !markedWatched else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        guard duration.isFinite, duration > 60, seconds / duration >= 0.9 else { return }
        markWatched(route: route)
    }

    private func markWatched(route: DeepLinkRouter.AnimePlayerRoute) {
        guard !markedWatched,
              let session = BangumiSessionStore.load(),
              !session.accessToken.isEmpty else { return }
        markedWatched = true
        Task.detached(priority: .utility) {
            try? CoreClient.shared.animeEpisodeUpdate(
                accessToken: session.accessToken,
                subjectID: route.subject.id,
                episodeID: route.episode.id,
                collectionType: 2
            )
        }
    }

    private func configureNowPlaying(play: AnimePlayUrlDTO, route: DeepLinkRouter.AnimePlayerRoute) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: play.title,
            MPMediaItemPropertyArtist: route.subject.displayTitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: 1,
        ]
        if let duration = player?.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    private func metadata(_ identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem? {
        guard !value.isEmpty else { return nil }
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item.copy() as? AVMetadataItem
    }

    private func startFirstPlayable(
        from candidates: [AnimeMediaCandidateDTO],
        route: DeepLinkRouter.AnimePlayerRoute,
        generation: UUID
    ) async -> Bool {
        for candidate in candidates where shouldAttemptCandidate(candidate) {
            guard !triedCandidateIDs.contains(candidate.id) else { continue }
            triedCandidateIDs.insert(candidate.id)
            do {
                AppLog.info("anime", "追番尝试候选资源", metadata: candidateMetadata(candidate, route: route))
                let play = try await resolveCandidate(candidate, route: route)
                guard !failedPlayURLs.contains(play.url) else {
                    AppLog.warning("anime", "追番候选资源跳过：播放地址已失败", metadata: candidateMetadata(candidate, route: route, extra: [
                        "resolvedURL": Self.redactedURL(play.url),
                    ]))
                    continue
                }
                guard generation == loadGeneration else { return true }
                AppLog.info("anime", "追番候选资源解析成功", metadata: candidateMetadata(candidate, route: route, extra: [
                    "resolvedFormat": play.format,
                    "resolvedURL": Self.redactedURL(play.url),
                    "resolvedHeaders": Self.redactedHeaderSummary(play.headers),
                ]))
                await startPlayback(play: play, route: route, generation: generation, candidateID: candidate.id)
                errorText = nil
                return true
            } catch {
                AppLog.warning("anime", "追番候选资源解析失败", metadata: candidateMetadata(candidate, route: route, extra: [
                    "error": error.localizedDescription,
                ]))
            }
        }
        return false
    }

    private func resolveCandidate(
        _ candidate: AnimeMediaCandidateDTO,
        route: DeepLinkRouter.AnimePlayerRoute
    ) async throws -> AnimePlayUrlDTO {
        if candidate.isSupported {
            return try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.animeMediaResolve(
                    candidate: candidate,
                    title: "\(route.subject.displayTitle) · \(route.episode.displayTitle)",
                    cover: route.subject.coverURL
                )
            }.value
        }
        guard canResolveByWebView(candidate) else {
            throw CoreError(category: "anime_web_resolver", message: candidate.unsupportedReason, code: nil)
        }
        let request = AnimeWebVideoResolveRequest(
            candidate: candidate,
            title: "\(route.subject.displayTitle) · \(route.episode.displayTitle)",
            cover: route.subject.coverURL
        )
        AppLog.info("anime", "追番 WebView 嗅探开始", metadata: candidateMetadata(candidate, route: route, extra: [
            "requestID": request.id.uuidString,
            "resolverURL": Self.redactedURL(request.url.absoluteString),
        ]))
        let result = await withCheckedContinuation { continuation in
            pendingWebResolvers[request.id] = continuation
            webResolveRequests.send(request)
        }
        if let play = result.play {
            AppLog.info("anime", "追番 WebView 嗅探成功", metadata: candidateMetadata(candidate, route: route, extra: [
                "requestID": request.id.uuidString,
                "resolvedFormat": play.format,
                "resolvedURL": Self.redactedURL(play.url),
                "resolvedHeaders": Self.redactedHeaderSummary(play.headers),
                "method": result.method,
            ]))
            return play
        }
        throw CoreError(category: "anime_web_resolver", message: result.errorText ?? "WebView 未嗅探到可播放资源", code: nil)
    }

    private func resolvePendingWebRequests(errorText: String) {
        let pending = pendingWebResolvers
        pendingWebResolvers.removeAll()
        for (id, continuation) in pending {
            continuation.resume(returning: AnimeWebVideoResolveResult(
                requestID: id,
                play: nil,
                errorText: errorText,
                method: "cancelled"
            ))
        }
    }

    private func shouldAttemptCandidate(_ candidate: AnimeMediaCandidateDTO) -> Bool {
        candidate.isSupported || canResolveByWebView(candidate)
    }

    private func canResolveByWebView(_ candidate: AnimeMediaCandidateDTO) -> Bool {
        guard candidate.kind == "web" else { return false }
        return URL(string: candidate.url) != nil || URL(string: candidate.pageURL) != nil
    }

    private func candidateMetadata(
        _ candidate: AnimeMediaCandidateDTO,
        route: DeepLinkRouter.AnimePlayerRoute,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var metadata: [String: String] = [
            "subjectID": String(route.subject.id),
            "episodeID": String(route.episode.id),
            "sourceID": candidate.sourceID,
            "source": candidate.sourceName,
            "kind": candidate.kind,
            "quality": candidate.qualityLabel,
            "supported": candidate.isSupported ? "true" : "false",
            "url": Self.redactedURL(candidate.url),
            "pageURL": Self.redactedURL(candidate.pageURL),
            "refererHost": URL(string: candidate.referer)?.host ?? "",
            "headers": Self.redactedHeaderSummary(candidate.headers),
            "hasCookie": Self.hasHeader("Cookie", in: candidate.headers) ? "true" : "false",
        ]
        if !candidate.unsupportedReason.isEmpty {
            metadata["unsupportedReason"] = candidate.unsupportedReason
        }
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }

    private func observePlaybackDiagnostics(
        player: AVPlayer,
        item: AVPlayerItem,
        play: AnimePlayUrlDTO,
        route: DeepLinkRouter.AnimePlayerRoute
    ) {
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                self?.logItemStatus(item, play: play, route: route)
            }
        }
        itemLikelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { _, _ in
            AppLog.debug("anime", "追番 AVPlayer 缓冲状态变化", metadata: [
                "subjectID": String(route.subject.id),
                "episodeID": String(route.episode.id),
                "likelyToKeepUp": item.isPlaybackLikelyToKeepUp ? "true" : "false",
                "format": play.format,
            ])
        }
        itemEmptyBufferObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { _, _ in
            AppLog.debug("anime", "追番 AVPlayer 空缓冲状态变化", metadata: [
                "subjectID": String(route.subject.id),
                "episodeID": String(route.episode.id),
                "bufferEmpty": item.isPlaybackBufferEmpty ? "true" : "false",
                "format": play.format,
            ])
        }
        playerTimeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            AppLog.debug("anime", "追番 AVPlayer 播放状态变化", metadata: [
                "subjectID": String(route.subject.id),
                "episodeID": String(route.episode.id),
                "timeControlStatus": Self.timeControlStatusText(player.timeControlStatus),
                "waitingReason": player.reasonForWaitingToPlay?.rawValue ?? "",
                "format": play.format,
            ])
        }
        itemNotificationObservers = [
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemPlaybackStalled,
                object: item,
                queue: .main
            ) { _ in
                AppLog.warning("anime", "追番 AVPlayer 播放卡顿", metadata: Self.itemLogMetadata(item, play: play, route: route))
            },
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewErrorLogEntry,
                object: item,
                queue: .main
            ) { _ in
                AppLog.warning("anime", "追番 AVPlayer 新错误日志", metadata: Self.itemLogMetadata(item, play: play, route: route))
            },
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewAccessLogEntry,
                object: item,
                queue: .main
            ) { _ in
                AppLog.debug("anime", "追番 AVPlayer 新访问日志", metadata: Self.itemLogMetadata(item, play: play, route: route))
            },
        ]
    }

    private func logItemStatus(
        _ item: AVPlayerItem,
        play: AnimePlayUrlDTO,
        route: DeepLinkRouter.AnimePlayerRoute
    ) {
        switch item.status {
        case .unknown:
            AppLog.debug("anime", "追番 AVPlayerItem 状态未知", metadata: Self.itemLogMetadata(item, play: play, route: route))
        case .readyToPlay:
            didReachReadyToPlay = true
            errorText = nil
            AppLog.info("anime", "追番 AVPlayerItem 已就绪", metadata: Self.itemLogMetadata(item, play: play, route: route))
        case .failed:
            failedPlayURLs.insert(play.url)
            errorText = item.error?.localizedDescription ?? "播放失败"
            AppLog.error("anime", "追番 AVPlayerItem 播放失败", error: item.error, metadata: Self.itemLogMetadata(item, play: play, route: route))
            scheduleFailoverAfterPlaybackFailure(failedURL: play.url)
        @unknown default:
            AppLog.warning("anime", "追番 AVPlayerItem 未知状态", metadata: Self.itemLogMetadata(item, play: play, route: route))
        }
    }

    private func scheduleFailoverAfterPlaybackFailure(failedURL: String) {
        guard let route = activeRoute else { return }
        let generation = loadGeneration
        let remainingCount = candidates.filter { shouldAttemptCandidate($0) && !triedCandidateIDs.contains($0.id) }.count
        guard remainingCount > 0 else {
            AppLog.warning("anime", "追番播放失败后无可用候选", metadata: [
                "subjectID": String(route.subject.id),
                "episodeID": String(route.episode.id),
                "failedURL": Self.redactedURL(failedURL),
            ])
            return
        }
        AppLog.info("anime", "追番播放失败，准备尝试下一个资源", metadata: [
            "subjectID": String(route.subject.id),
            "episodeID": String(route.episode.id),
            "failedURL": Self.redactedURL(failedURL),
            "remainingCandidates": String(remainingCount),
        ])
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard generation == loadGeneration else { return }
            let didStart = await startFirstPlayable(from: candidates, route: route, generation: generation)
            if !didStart {
                errorText = "当前资源不可用，且没有可切换的资源"
            }
        }
    }

    private static func itemLogMetadata(
        _ item: AVPlayerItem,
        play: AnimePlayUrlDTO,
        route: DeepLinkRouter.AnimePlayerRoute
    ) -> [String: String] {
        var metadata: [String: String] = [
            "subjectID": String(route.subject.id),
            "episodeID": String(route.episode.id),
            "format": play.format,
            "url": redactedURL(play.url),
            "status": itemStatusText(item.status),
            "duration": durationText(item.duration.seconds),
            "likelyToKeepUp": item.isPlaybackLikelyToKeepUp ? "true" : "false",
            "bufferEmpty": item.isPlaybackBufferEmpty ? "true" : "false",
        ]
        if let error = item.error {
            metadata["itemError"] = error.localizedDescription
        }
        if let access = item.accessLog()?.events.last {
            metadata["accessServer"] = access.serverAddress ?? ""
            metadata["accessURI"] = redactedURL(access.uri ?? "")
            metadata["mediaRequests"] = String(access.numberOfMediaRequests)
            metadata["observedBitrate"] = String(format: "%.0f", access.observedBitrate)
            metadata["indicatedBitrate"] = String(format: "%.0f", access.indicatedBitrate)
            metadata["transferDuration"] = String(format: "%.2f", access.transferDuration)
            metadata["downloadedDuration"] = String(format: "%.2f", access.segmentsDownloadedDuration)
            metadata["droppedFrames"] = String(access.numberOfDroppedVideoFrames)
        }
        if let errorLog = item.errorLog()?.events.last {
            metadata["errorDomain"] = errorLog.errorDomain
            metadata["errorStatusCode"] = String(errorLog.errorStatusCode)
            metadata["errorComment"] = errorLog.errorComment ?? ""
            metadata["errorServer"] = errorLog.serverAddress ?? ""
            metadata["errorURI"] = redactedURL(errorLog.uri ?? "")
        }
        return metadata
    }

    private static func sourceReportSummary(_ reports: [AnimeMediaSourceReportDTO]) -> String {
        reports.prefix(8).map {
            "\($0.sourceName):\($0.status):\($0.supportedCount)/\($0.candidateCount)"
        }.joined(separator: " | ")
    }

    static func redactedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value.prefix(160).description }
        let queryNames = (components.queryItems ?? []).map(\.name)
        components.queryItems = queryNames.isEmpty ? nil : queryNames.map { URLQueryItem(name: $0, value: "*") }
        return components.string?.prefix(220).description ?? value.prefix(160).description
    }

    static func redactedHeaderSummary(_ headers: [String: String]) -> String {
        headers.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { key in
                if key.caseInsensitiveCompare("Cookie") == .orderedSame {
                    return "Cookie(*)"
                }
                return key
            }
            .joined(separator: ",")
    }

    private static func hasHeader(_ key: String, in headers: [String: String]) -> Bool {
        headers.keys.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
    }

    private static func itemStatusText(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed"
        @unknown default: return "unknownDefault"
        }
    }

    private static func timeControlStatusText(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waiting"
        case .playing: return "playing"
        @unknown default: return "unknownDefault"
        }
    }

    private static func durationText(_ seconds: Double) -> String {
        seconds.isFinite ? String(format: "%.2f", seconds) : "indefinite"
    }

    private static func placeholderDiagnostics(for sources: [AnimeSourceDTO]) -> AnimeMediaFetchDiagnosticsDTO {
        AnimeMediaFetchDiagnosticsDTO(
            enabledSources: Int64(sources.count),
            attemptedQueries: 0,
            succeededQueries: 0,
            failedQueries: 0,
            unsupportedCandidates: 0,
            supportedCandidates: 0,
            messages: [],
            sourceReports: sources.map {
                AnimeMediaSourceReportDTO(
                    sourceID: $0.id,
                    sourceName: $0.name,
                    factoryID: $0.factoryID,
                    stateID: "pending",
                    isWorking: false,
                    isTemporarilyEnabled: false,
                    attemptedQueries: 0,
                    succeededQueries: 0,
                    failedQueries: 0,
                    candidateCount: 0,
                    supportedCount: 0,
                    status: "pending",
                    message: "等待检索",
                    captchaURL: "",
                    captchaKind: ""
                )
            }
        )
    }

    private static func buildSourceJSONMap(for sources: [AnimeSourceDTO]) -> [String: String] {
        var result: [String: String] = [:]
        for source in sources {
            do {
                result[source.id] = try AnimeSourceStore.shared.sourceJSON(for: source)
            } catch {
                AppLog.error("anime", "追番数据源序列化失败", error: error, metadata: [
                    "sourceID": source.id,
                    "source": source.name,
                ])
            }
        }
        return result
    }
}
