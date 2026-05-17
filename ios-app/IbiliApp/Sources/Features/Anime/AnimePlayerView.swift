import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import WebKit

struct AnimePlayerView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var sourceStore = AnimeSourceStore.shared
    @StateObject private var vm = AnimePlayerViewModel()
    @State private var presentationRouteActive = false
    @State private var lifecycleID = UUID()
    @State private var createdController: AVPlayerViewController?
    @State private var showsCandidates = false
    @State private var captchaRequest: AnimeCaptchaRequest?

    let route: DeepLinkRouter.AnimePlayerRoute

    var body: some View {
        VStack(spacing: 0) {
            playerSurface
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    titleSection
                    sourceStatusSection
                    if !route.subject.episodes.isEmpty {
                        episodeSection
                    }
                    if !route.subject.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VideoDescriptionView(desc: route.subject.summary, descV2: [])
                            .padding(12)
                            .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(16)
            }
        }
        .background(IbiliTheme.background)
        .navigationTitle(route.episode.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: route.id) {
            await sourceStore.ensureDefaultSubscriptionsLoaded()
            await vm.load(
                route: route,
                sourcesJSONProvider: sourceStore.enabledSourcesJSON,
                enabledSourcesProvider: { sourceStore.sources.filter(\.enabled) }
            )
        }
        .onAppear {
            lifecycleID = UUID()
        }
        .onDisappear {
            let id = lifecycleID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard id == lifecycleID else { return }
                PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: vm)
                vm.stop()
            }
        }
        .sheet(isPresented: $showsCandidates) {
            NavigationStack {
                AnimeCandidateListView(
                    candidates: vm.candidates,
                    diagnostics: vm.diagnostics,
                    isLoading: vm.isResolving,
                    onPick: { candidate in
                        showsCandidates = false
                        Task { await vm.play(candidate: candidate, route: route) }
                    }
                )
            }
        }
        .sheet(item: $captchaRequest) { request in
            AnimeCaptchaWebViewSheet(request: request) { cookie in
                sourceStore.updateCookie(cookie, forSourceID: request.sourceID)
                Task {
                    await vm.refresh(
                        route: route,
                        sourcesJSONProvider: sourceStore.enabledSourcesJSON,
                        enabledSourcesProvider: { sourceStore.sources.filter(\.enabled) }
                    )
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsCandidates = true
                } label: {
                    Image(systemName: "server.rack")
                }
                .disabled(vm.candidates.isEmpty && vm.isLoading)
                .tint(IbiliTheme.accent)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await vm.refresh(
                            route: route,
                            sourcesJSONProvider: sourceStore.enabledSourcesJSON,
                            enabledSourcesProvider: { sourceStore.sources.filter(\.enabled) }
                        )
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isLoading)
                .tint(IbiliTheme.accent)
            }
        }
        .tint(.white)
    }

    @ViewBuilder
    private var playerSurface: some View {
        ZStack {
            Color.black
            if let player = vm.player, let play = vm.currentPlay {
                PlayerContainer(
                    player: player,
                    sessionID: route.id,
                    title: play.title,
                    prefersLandscapeFullscreen: true,
                    isPresentationRouteActive: presentationRouteActive,
                    danmaku: vm.danmaku,
                    subtitle: nil,
                    subtitleEnabled: false,
                    danmakuEnabled: false,
                    danmakuOpacity: settings.danmakuOpacity,
                    danmakuBlockLevel: settings.resolvedDanmakuBlockLevel(),
                    danmakuFrameRate: settings.resolvedDanmakuFrameRate(),
                    danmakuStrokeWidth: settings.resolvedDanmakuStrokeWidth(),
                    danmakuFontWeight: settings.resolvedDanmakuFontWeight(),
                    danmakuFontScale: settings.resolvedDanmakuFontScale(),
                    isTemporarySpeedBoostActive: { false },
                    canBeginTemporarySpeedBoost: { false },
                    beginTemporarySpeedBoost: { false },
                    endTemporarySpeedBoost: {},
                    canRestorePlaybackAfterPresentation: { presentationRouteActive },
                    onCreated: { controller in
                        createdController = controller
                    },
                    onPresentationEvent: handlePresentationEvent
                )
            } else {
                AnimePlayerPlaceholder(
                    coverURL: route.subject.coverURL,
                    title: route.subject.displayTitle,
                    episodeTitle: route.episode.displayTitle,
                    isLoading: vm.isLoading,
                    errorText: vm.errorText,
                    onRetry: {
                        Task {
                            await vm.refresh(
                                route: route,
                                sourcesJSONProvider: sourceStore.enabledSourcesJSON,
                                enabledSourcesProvider: { sourceStore.sources.filter(\.enabled) }
                            )
                        }
                    }
                )
            }
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(route.subject.displayTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(IbiliTheme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(route.episode.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .lineLimit(1)
                if vm.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            if let play = vm.currentPlay {
                Text([play.format.uppercased(), activeSourceName].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeSourceName: String {
        guard let url = vm.currentPlay?.url else { return "" }
        return vm.candidates.first { $0.url == url }?.sourceName ?? ""
    }

    private var sourceStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("数据源")
                    .font(.headline)
                Spacer()
                if let diagnostics = vm.diagnostics {
                    Text(vm.isSearchingMore ? "继续检索中" : "\(diagnostics.supportedCandidates) 可播 / \(diagnostics.attemptedQueries) 查询")
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
            }
            if vm.diagnostics?.sourceReports.isEmpty != false {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检索资源")
                        .font(.footnote)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(visibleSourceReports) { report in
                        AnimeSourceReportRow(report: report) {
                            guard report.status == "captcha", let url = URL(string: report.captchaURL), !report.captchaURL.isEmpty else { return }
                            captchaRequest = AnimeCaptchaRequest(sourceID: report.sourceID, sourceName: report.sourceName, url: url)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("选集")
                        .font(.headline)
                    Text("当前 \(route.episode.displayTitle)")
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(route.subject.episodes.enumerated()), id: \.element.id) { index, episode in
                            AnimePlayerEpisodeChip(
                                episode: episode,
                                index: index + 1,
                                isCurrent: episode.id == route.episode.id,
                                stateLabel: episodeStateLabel(episode.collectionType)
                            ) {
                                guard episode.id != route.episode.id else { return }
                                router.openAnimeEpisode(subject: route.subject, episode: episode, mode: .replaceCurrent)
                            }
                            .id(episode.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .background(PlayerSwipeBackExclusionZone(includeEnclosingScrollView: true))
                .overlay(PlayerSwipeBackExclusionZone(includeEnclosingScrollView: false))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo(route.episode.id, anchor: .center)
                    }
                }
                .onChange(of: route.episode.id) { _ in
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(route.episode.id, anchor: .center)
                    }
                }
            }
        }
        .padding(12)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var visibleSourceReports: [AnimeMediaSourceReportDTO] {
        Array((vm.diagnostics?.sourceReports ?? []).prefix(8))
    }

    private func handlePresentationEvent(_ event: PlayerPresentationEvent) {
        switch event {
        case .fullscreenChanged(let isFullscreen, _):
            presentationRouteActive = isFullscreen
            if isFullscreen {
                Orientation.activatePlayerPresentationRoute(route.id)
            } else {
                Orientation.deactivatePlayerPresentationRoute(route.id)
            }
        case .suppressTransientPauseObservation:
            break
        case .pictureInPictureChanged(let isActive, _):
            presentationRouteActive = isActive
        case .pictureInPictureRestoreRequested(_, let completion):
            completion(true)
        }
    }

    private func episodeStateLabel(_ value: Int64) -> String {
        switch value {
        case 1: return "想看"
        case 2: return "看过"
        case 3: return "在看"
        case 4: return "搁置"
        case 5: return "抛弃"
        default: return ""
        }
    }
}

@MainActor
final class AnimePlayerViewModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var currentPlay: AnimePlayUrlDTO?
    @Published private(set) var candidates: [AnimeMediaCandidateDTO] = []
    @Published private(set) var diagnostics: AnimeMediaFetchDiagnosticsDTO?
    @Published private(set) var isLoading = false
    @Published private(set) var isSearchingMore = false
    @Published private(set) var isResolving = false
    @Published var errorText: String?

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

    func load(
        route: DeepLinkRouter.AnimePlayerRoute,
        sourcesJSONProvider: () throws -> String,
        enabledSourcesProvider: () -> [AnimeSourceDTO]
    ) async {
        loadGeneration = UUID()
        let generation = loadGeneration
        errorText = nil
        candidates = []
        diagnostics = nil
        isSearchingMore = false
        markedWatched = false
        stop(keepState: false)

        if let play = route.initialPlay {
            await startPlayback(play: play, route: route, generation: generation)
            return
        }
        await refresh(
            route: route,
            sourcesJSONProvider: sourcesJSONProvider,
            enabledSourcesProvider: enabledSourcesProvider,
            generation: generation
        )
    }

    func refresh(
        route: DeepLinkRouter.AnimePlayerRoute,
        sourcesJSONProvider: () throws -> String,
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
        isSearchingMore = false
        errorText = nil
        do {
            let sourcesJSON = try sourcesJSONProvider()
            let enabledSources = enabledSourcesProvider()
            diagnostics = Self.placeholderDiagnostics(for: enabledSources)
            let names = [route.subject.nameCn, route.subject.name] + route.subject.aliases
            AppLog.info("anime", "追番播放页开始检索资源", metadata: [
                "subjectID": String(route.subject.id),
                "episodeID": String(route.episode.id),
                "episodeSort": String(format: "%.2f", route.episode.sort),
                "episodeTitle": route.episode.displayTitle,
                "keywordPreview": names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(4).joined(separator: " | "),
                "enabledSources": String(enabledSources.count),
                "sourcesBytes": String(sourcesJSON.utf8.count),
            ])
            let fastResult = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.animeMediaFetchOptions(
                    sourcesJSON: sourcesJSON,
                    subjectNames: names,
                    episodeSort: route.episode.sort,
                    episodeName: route.episode.displayTitle,
                    maxSources: 8,
                    stopAfterSupported: 1
                )
            }.value
            guard activeGeneration == loadGeneration else { return }
            candidates = fastResult.candidates
            diagnostics = fastResult.diagnostics
            logFetchResult(fastResult, phase: "fast", route: route)
            if await startFirstPlayable(from: fastResult.candidates, route: route, generation: activeGeneration) {
                isLoading = false
                isSearchingMore = true
            } else if !fastResult.candidates.isEmpty {
                errorText = "暂未找到可播放资源，继续检索中"
                isSearchingMore = true
            }

            let fullResult = try await Task.detached(priority: .utility) {
                try CoreClient.shared.animeMediaFetchOptions(
                    sourcesJSON: sourcesJSON,
                    subjectNames: names,
                    episodeSort: route.episode.sort,
                    episodeName: route.episode.displayTitle,
                    maxSources: 0,
                    stopAfterSupported: 0
                )
            }.value
            guard activeGeneration == loadGeneration else { return }
            candidates = Self.mergedCandidates(primary: candidates, secondary: fullResult.candidates)
            diagnostics = fullResult.diagnostics
            isSearchingMore = false
            isLoading = false
            logFetchResult(fullResult, phase: "full", route: route)
            if currentPlay == nil {
                let didStart = await startFirstPlayable(from: candidates, route: route, generation: activeGeneration)
                if !didStart {
                    errorText = "没有找到可播放资源"
                }
            } else {
                errorText = nil
            }
            if currentPlay == nil {
                errorText = "没有找到可播放资源"
            }
        } catch {
            guard activeGeneration == loadGeneration else { return }
            candidates = []
            diagnostics = nil
            isLoading = false
            isSearchingMore = false
            errorText = error.localizedDescription
            AppLog.error("anime", "追番播放页资源检索失败", error: error, metadata: [
                "subjectID": String(route.subject.id),
                "episodeID": String(route.episode.id),
            ])
        }
    }

    func play(candidate: AnimeMediaCandidateDTO, route: DeepLinkRouter.AnimePlayerRoute) async {
        guard candidate.isSupported else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            let play = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.animeMediaResolve(
                    candidate: candidate,
                    title: "\(route.subject.displayTitle) · \(route.episode.displayTitle)",
                    cover: route.subject.coverURL
                )
            }.value
            AppLog.info("anime", "追番手动选择候选资源", metadata: candidateMetadata(candidate, route: route, extra: [
                "resolvedFormat": play.format,
                "resolvedURL": Self.redactedURL(play.url),
                "resolvedHeaders": Self.redactedHeaderSummary(play.headers),
            ]))
            loadGeneration = UUID()
            await startPlayback(play: play, route: route, generation: loadGeneration)
        } catch {
            errorText = error.localizedDescription
            AppLog.error("anime", "追番手动选择候选资源失败", error: error, metadata: candidateMetadata(candidate, route: route))
        }
    }

    func stop() {
        stop(keepState: false)
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
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func startPlayback(
        play: AnimePlayUrlDTO,
        route: DeepLinkRouter.AnimePlayerRoute,
        generation: UUID
    ) async {
        guard generation == loadGeneration else { return }
        stop(keepState: true)
        currentPlay = play
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
        for candidate in candidates where candidate.isSupported {
            do {
                AppLog.info("anime", "追番尝试候选资源", metadata: candidateMetadata(candidate, route: route))
                let play = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.animeMediaResolve(
                        candidate: candidate,
                        title: "\(route.subject.displayTitle) · \(route.episode.displayTitle)",
                        cover: route.subject.coverURL
                    )
                }.value
                guard generation == loadGeneration else { return true }
                AppLog.info("anime", "追番候选资源解析成功", metadata: candidateMetadata(candidate, route: route, extra: [
                    "resolvedFormat": play.format,
                    "resolvedURL": Self.redactedURL(play.url),
                    "resolvedHeaders": Self.redactedHeaderSummary(play.headers),
                ]))
                await startPlayback(play: play, route: route, generation: generation)
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

    private func logFetchResult(_ result: AnimeMediaFetchResultDTO, phase: String, route: DeepLinkRouter.AnimePlayerRoute) {
        AppLog.info("anime", "追番播放页资源检索完成", metadata: [
            "subjectID": String(route.subject.id),
            "episodeID": String(route.episode.id),
            "phase": phase,
            "attemptedQueries": String(result.diagnostics.attemptedQueries),
            "succeededQueries": String(result.diagnostics.succeededQueries),
            "failedQueries": String(result.diagnostics.failedQueries),
            "supportedCandidates": String(result.diagnostics.supportedCandidates),
            "unsupportedCandidates": String(result.diagnostics.unsupportedCandidates),
            "candidateCount": String(result.candidates.count),
            "topCandidates": Self.candidateSummary(result.candidates),
            "sourceReports": Self.sourceReportSummary(result.diagnostics.sourceReports),
            "messages": result.diagnostics.messages.prefix(4).joined(separator: " | "),
        ])
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
            AppLog.info("anime", "追番 AVPlayerItem 已就绪", metadata: Self.itemLogMetadata(item, play: play, route: route))
        case .failed:
            errorText = item.error?.localizedDescription ?? "播放失败"
            AppLog.error("anime", "追番 AVPlayerItem 播放失败", error: item.error, metadata: Self.itemLogMetadata(item, play: play, route: route))
        @unknown default:
            AppLog.warning("anime", "追番 AVPlayerItem 未知状态", metadata: Self.itemLogMetadata(item, play: play, route: route))
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

    private static func candidateSummary(_ candidates: [AnimeMediaCandidateDTO]) -> String {
        candidates.prefix(6).map {
            let host = URL(string: $0.url)?.host ?? ""
            return "\($0.sourceName)/\($0.kind)/\($0.qualityLabel)/\($0.isSupported ? "ok" : "no")/\(host)"
        }.joined(separator: " | ")
    }

    private static func sourceReportSummary(_ reports: [AnimeMediaSourceReportDTO]) -> String {
        reports.prefix(8).map {
            "\($0.sourceName):\($0.status):\($0.supportedCount)/\($0.candidateCount)"
        }.joined(separator: " | ")
    }

    private static func redactedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value.prefix(160).description }
        let queryNames = (components.queryItems ?? []).map(\.name)
        components.queryItems = queryNames.isEmpty ? nil : queryNames.map { URLQueryItem(name: $0, value: "*") }
        return components.string?.prefix(220).description ?? value.prefix(160).description
    }

    private static func redactedHeaderSummary(_ headers: [String: String]) -> String {
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

    private static func mergedCandidates(
        primary: [AnimeMediaCandidateDTO],
        secondary: [AnimeMediaCandidateDTO]
    ) -> [AnimeMediaCandidateDTO] {
        var seen = Set<String>()
        var merged: [AnimeMediaCandidateDTO] = []
        for candidate in primary + secondary where seen.insert(candidate.id).inserted {
            merged.append(candidate)
        }
        return merged.sorted {
            if $0.isSupported != $1.isSupported { return $0.isSupported && !$1.isSupported }
            let left = qualityScore($0.qualityLabel)
            let right = qualityScore($1.qualityLabel)
            if left != right { return left > right }
            return $0.sourceName < $1.sourceName
        }
    }

    private static func qualityScore(_ value: String) -> Int {
        let upper = value.uppercased()
        if upper.contains("4K") || upper.contains("2160") { return 2160 }
        if upper.contains("1080") { return 1080 }
        if upper.contains("720") { return 720 }
        if upper.contains("480") { return 480 }
        if upper.contains("360") { return 360 }
        return 0
    }
}

private struct AnimePlayerPlaceholder: View {
    let coverURL: String
    let title: String
    let episodeTitle: String
    let isLoading: Bool
    let errorText: String?
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            RemoteImage(url: coverURL, targetPointSize: CGSize(width: 640, height: 360), quality: 70)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay(Color.black.opacity(0.64))
            VStack(spacing: 12) {
                if isLoading {
                    ProgressView().tint(.white)
                } else if errorText != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2.weight(.semibold))
                } else {
                    Image(systemName: "play.tv")
                        .font(.title2.weight(.semibold))
                }
                VStack(spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                .multilineTextAlignment(.center)
                if errorText != nil {
                    Button("重试", action: onRetry)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
        }
    }

    private var statusText: String {
        if let errorText { return errorText }
        return isLoading ? "正在检索 \(episodeTitle)" : episodeTitle
    }
}

private struct AnimeSourceReportRow: View {
    let report: AnimeMediaSourceReportDTO
    let onSolveCaptcha: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.sourceName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if report.supportedCount > 0 {
                Text("\(report.supportedCount)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(IbiliTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(IbiliTheme.accent.opacity(0.12), in: Capsule())
            } else if report.status == "captcha" {
                Button("验证", action: onSolveCaptcha)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch report.status {
        case "found":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(IbiliTheme.accent)
        case "searching", "pending":
            ProgressView().controlSize(.small)
        case "failed":
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        case "captcha":
            Image(systemName: "lock.shield").foregroundStyle(.orange)
        case "unsupported":
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        default:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private var detailText: String {
        if !report.message.isEmpty {
            if report.status == "captcha", !report.captchaKind.isEmpty {
                return report.captchaKind
            }
            return report.message
        }
        if report.attemptedQueries > 0 {
            return "查询 \(report.succeededQueries)/\(report.attemptedQueries)"
        }
        return "等待检索"
    }
}

private struct AnimeCandidateListView: View {
    let candidates: [AnimeMediaCandidateDTO]
    let diagnostics: AnimeMediaFetchDiagnosticsDTO?
    let isLoading: Bool
    let onPick: (AnimeMediaCandidateDTO) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                if candidates.isEmpty {
                    emptyState(title: "没有找到资源", symbol: "magnifyingglass")
                        .padding(.vertical, 24)
                } else {
                    ForEach(candidates) { candidate in
                        Button {
                            guard candidate.isSupported else { return }
                            onPick(candidate)
                        } label: {
                            CandidateRow(candidate: candidate)
                        }
                        .disabled(!candidate.isSupported || isLoading)
                    }
                }
            }
            if let diagnostics {
                Section("诊断") {
                    LabeledContent("查询", value: "\(diagnostics.succeededQueries)/\(diagnostics.attemptedQueries)")
                    LabeledContent("可播放", value: "\(diagnostics.supportedCandidates)")
                    LabeledContent("不可播放", value: "\(diagnostics.unsupportedCandidates)")
                    ForEach(diagnostics.messages.prefix(4), id: \.self) { message in
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("数据源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { dismiss() }
            }
        }
    }
}

private struct CandidateRow: View {
    let candidate: AnimeMediaCandidateDTO

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: candidate.isSupported ? "play.circle.fill" : "exclamationmark.triangle")
                .foregroundStyle(candidate.isSupported ? IbiliTheme.accent : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                Text([candidate.sourceName, candidate.qualityLabel, candidate.kind.uppercased()]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
                if !candidate.isSupported {
                    Text(candidate.unsupportedReason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

private struct AnimeCaptchaRequest: Identifiable {
    let sourceID: String
    let sourceName: String
    let url: URL

    var id: String { "\(sourceID)-\(url.absoluteString)" }
}

private struct AnimeCaptchaWebViewSheet: View {
    let request: AnimeCaptchaRequest
    let onSolved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cookieText = ""

    var body: some View {
        NavigationStack {
            AnimeCaptchaWebView(url: request.url, cookieText: $cookieText)
                .navigationTitle(request.sourceName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") {
                            onSolved(cookieText)
                            dismiss()
                        }
                        .disabled(cookieText.isEmpty)
                    }
                }
        }
    }
}

private struct AnimeCaptchaWebView: UIViewRepresentable {
    let url: URL
    @Binding var cookieText: String

    func makeCoordinator() -> Coordinator {
        Coordinator(cookieText: $cookieText)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = BiliHTTP.headers["User-Agent"]
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding private var cookieText: String

        init(cookieText: Binding<String>) {
            _cookieText = cookieText
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let value = cookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                DispatchQueue.main.async {
                    self.cookieText = value
                }
            }
        }
    }
}

private struct AnimePlayerEpisodeChip: View {
    let episode: AnimeEpisodeDTO
    let index: Int
    let isCurrent: Bool
    let stateLabel: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(String(format: "%02d", index))
                        .font(.caption2.weight(.bold).monospacedDigit())
                    if isCurrent {
                        Image(systemName: "waveform")
                            .imageScale(.small)
                    } else if !stateLabel.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .imageScale(.small)
                    }
                }
                .foregroundStyle(isCurrent || !stateLabel.isEmpty ? IbiliTheme.accent : IbiliTheme.textSecondary)

                Text(episode.displayTitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isCurrent || !stateLabel.isEmpty ? IbiliTheme.accent : IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(width: 124, height: 72, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent || !stateLabel.isEmpty ? IbiliTheme.accent.opacity(0.12) : Color(.tertiarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isCurrent ? IbiliTheme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
