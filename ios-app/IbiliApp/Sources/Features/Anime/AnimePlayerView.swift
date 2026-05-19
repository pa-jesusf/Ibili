import AVKit
import SwiftUI

struct AnimePlayerView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.dismissPlayerHost) private var dismissPlayerHost
    @StateObject private var sourceStore = AnimeSourceStore.shared
    @StateObject private var vm: AnimePlayerViewModel
    @State private var isFullscreen = false
    @State private var presentationState = PlayerPresentationState()
    @State private var isInlineHostVisible = false
    @State private var playerVCRef = PlayerVCBox()
    @State private var showsCandidates = false
    @State private var showsSourceSettings = false
    @State private var showsDanmakuStyle = false
    @State private var captchaRequest: AnimeCaptchaRequest?
    @State private var webResolverRequest: AnimeWebVideoResolveRequest?
    @State private var selectedContentTab: AnimePlayerContentTab = .details
    @State private var episodeComments: [AnimeEpisodeCommentDTO] = []
    @State private var commentsEpisodeID: Int64?
    @State private var isLoadingComments = false
    @State private var commentsErrorText: String?

    let route: DeepLinkRouter.AnimePlayerRoute

    init(route: DeepLinkRouter.AnimePlayerRoute, viewModel: AnimePlayerViewModel? = nil) {
        self.route = route
        _vm = StateObject(wrappedValue: viewModel ?? AnimePlayerViewModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            playerSurface
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            contentArea
        }
        .background(IbiliTheme.background)
        .navigationTitle(route.episode.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .task(id: route.id) {
            await sourceStore.ensureDefaultSubscriptionsLoaded()
            await vm.load(
                route: route,
                enabledSourcesProvider: { sourceStore.sources.filter(\.enabled) }
            )
        }
        .task(id: "\(route.episode.id)-\(selectedContentTab.rawValue)") {
            guard selectedContentTab == .comments else { return }
            await loadEpisodeComments()
        }
        .onAppear {
            AppLog.debug("anime", "追番播放页 onAppear", metadata: [
                "subjectID": String(route.subject.id),
                "episodeID": String(route.episode.id),
                "isFullscreen": String(isFullscreen),
                "isFullscreenPresentationActive": String(presentationState.isFullscreenPresentationActive),
                "isAwaitingInlineFullscreenReturn": String(presentationState.isAwaitingInlineFullscreenReturn),
            ])
            Orientation.activatePlayerPresentationRoute(route.id)
            isInlineHostVisible = true
            if presentationState.isAwaitingInlineFullscreenReturn {
                _ = presentationState.finishFullscreenReturn(currentPresentationIdentity)
            }
        }
        .onDisappear {
            AppLog.debug("anime", "追番播放页 onDisappear", metadata: [
                "subjectID": String(route.subject.id),
                "episodeID": String(route.episode.id),
                "isFullscreen": String(isFullscreen),
                "isFullscreenPresentationActive": String(presentationState.isFullscreenPresentationActive),
                "isAwaitingInlineFullscreenReturn": String(presentationState.isAwaitingInlineFullscreenReturn),
            ])
            isInlineHostVisible = false
            if !isNativePlayerPresentationActive {
                Orientation.deactivatePlayerPresentationRoute(route.id)
            }
        }
        .sheet(isPresented: $showsCandidates) {
            NavigationStack {
                AnimeCandidateListView(
                    candidates: vm.candidates,
                    diagnostics: vm.diagnostics,
                    isLoading: vm.isResolving,
                    activeCandidateID: vm.currentCandidateID,
                    activePlayURL: vm.currentPlay?.url,
                    onPick: { candidate in
                        showsCandidates = false
                        Task { await vm.play(candidate: candidate, route: route) }
                    },
                    onSolveCaptcha: { report in
                        showsCandidates = false
                        guard report.status == "captcha",
                              let url = URL(string: report.captchaURL),
                              !report.captchaURL.isEmpty else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            captchaRequest = AnimeCaptchaRequest(sourceID: report.sourceID, sourceName: report.sourceName, url: url)
                        }
                    },
                    onManageSources: {
                        showsCandidates = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            showsSourceSettings = true
                        }
                    }
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsSourceSettings) {
            NavigationStack {
                AnimeSourceSettingsView(store: sourceStore, showsDoneButton: true)
            }
            .environmentObject(settings)
            .tint(IbiliTheme.accent)
        }
        .sheet(item: $captchaRequest) { request in
            AnimeCaptchaWebViewSheet(request: request) { session in
                sourceStore.updateCookie(session.cookies, forSourceID: request.sourceID)
                Task {
                    await vm.retryAfterCaptchaSolved(
                        sourceID: request.sourceID,
                        route: route,
                        session: session
                    )
                }
            }
        }
        .background(alignment: .topLeading) {
            if let webResolverRequest {
                AnimeWebVideoResolverHost(request: webResolverRequest) { result in
                    self.webResolverRequest = nil
                    Task {
                        await vm.handleWebResolveResult(result, route: route)
                    }
                }
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onReceive(vm.webResolveRequests) { request in
            webResolverRequest = request
        }
        .onChange(of: settings.danmakuEnabled) { enabled in
            if enabled {
                Task { await vm.loadDanmakuIfNeeded(route: route) }
            } else {
                vm.danmaku.clear()
            }
        }
        .sheet(isPresented: $showsDanmakuStyle) {
            DanmakuStyleSettingsView()
                .environmentObject(settings)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .toolbar {
            if !isFullscreen {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: dismissPlayerHost) {
                        Label("返回", systemImage: "chevron.backward")
                            .labelStyle(.iconOnly)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PlayerToolbarDanmaku(
                        danmakuEnabled: $settings.danmakuEnabled,
                        isEnabled: vm.player != nil,
                        onLongPress: { showsDanmakuStyle = true }
                    )
                    Button {
                        showsCandidates = true
                    } label: {
                        Label("选择数据源", systemImage: "server.rack")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(vm.candidates.isEmpty && vm.isLoading)

                    Button {
                        Task {
                            await vm.refresh(
                                route: route,
                                enabledSourcesProvider: { sourceStore.sources.filter(\.enabled) }
                            )
                        }
                    } label: {
                        Label("刷新资源", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(vm.isLoading)
                }
            }
        }
        .tint(IbiliTheme.accent)
    }

    private var contentArea: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedContentTab {
                    case .details:
                        playerDetailContent
                    case .comments:
                        playerCommentContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 86)
            }

            IbiliSegmentedTabs(
                tabs: AnimePlayerContentTab.allCases,
                title: { $0.title },
                selection: $selectedContentTab
            )
            .frame(maxWidth: 260)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
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
                    isPresentationRouteActive: isPresentationRouteActive,
                    danmaku: vm.danmaku,
                    subtitle: nil,
                    subtitleEnabled: false,
                    danmakuEnabled: settings.danmakuEnabled,
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
                    canRestorePlaybackAfterPresentation: { isPresentationRouteActive && vm.canRestorePlaybackAfterPresentation },
                    onCreated: { controller in
                        playerVCRef.vc = controller
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
                .font(.title.weight(.bold))
                .foregroundStyle(IbiliTheme.textPrimary)
                .lineLimit(3)
            HStack(spacing: 8) {
                Text(String(format: "%02d", Int(route.episode.sort.rounded())))
                    .font(.title3.weight(.medium).monospacedDigit())
                    .foregroundStyle(IbiliTheme.textSecondary)
                Text(route.episode.displayTitle)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .lineLimit(1)
                if vm.isLoading {
                    ProgressView().controlSize(.small)
                }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("数据源")
                        .font(.headline)
                    Text(resourceSummaryText)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                Spacer()
                Button {
                    showsCandidates = true
                } label: {
                    Label("更换", systemImage: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(IbiliTheme.accent)
            }
            if let activeCandidate {
                AnimeActiveResourceRow(candidate: activeCandidate, format: vm.currentPlay?.format ?? "")
            } else if vm.isLoading || vm.isSearchingMore {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在为当前集检索资源")
                        .font(.footnote)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var activeCandidate: AnimeMediaCandidateDTO? {
        if let id = vm.currentCandidateID,
           let candidate = vm.candidates.first(where: { $0.id == id }) {
            return candidate
        }
        guard let url = vm.currentPlay?.url else { return nil }
        return vm.candidates.first { $0.url == url }
    }

    private var resourceSummaryText: String {
        guard let diagnostics = vm.diagnostics else { return "准备检索" }
        if vm.isSearchingMore { return "已优先播放，继续检索中" }
        if vm.isLoading { return "正在检索资源" }
        return "\(diagnostics.supportedCandidates) 个可播 · \(diagnostics.attemptedQueries) 次查询"
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("剧集列表")
                        .font(.title3.weight(.bold))
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
        .padding(14)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var playerDetailContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleSection
            playerActionRow
            sourceStatusSection
            if !route.subject.episodes.isEmpty {
                episodeSection
            }
            danmakuSourceSection
            if !route.subject.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("简介")
                        .font(.title3.weight(.bold))
                    VideoDescriptionView(desc: route.subject.summary, descV2: [])
                }
                .padding(14)
                .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var playerActionRow: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Label(route.subject.collectionType > 0 ? route.subject.collectionLabel : "未收藏", systemImage: "heart.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IbiliTheme.accent)
            Button {
                showsCandidates = true
            } label: {
                Label("选择数据源", systemImage: "server.rack")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(IbiliTheme.accent)
            Button {
                Task {
                    await vm.refresh(
                        route: route,
                        enabledSourcesProvider: { sourceStore.sources.filter(\.enabled) }
                    )
                }
            } label: {
                Label("刷新资源", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(IbiliTheme.accent)
            .disabled(vm.isLoading)
        }
    }

    private var danmakuSourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("弹幕源")
                    .font(.title3.weight(.bold))
                Spacer()
                Button {
                    showsDanmakuStyle = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .foregroundStyle(IbiliTheme.accent)
            }
            HStack(spacing: 12) {
                AnimeDanmakuSourceCard(
                    title: activeCandidate?.isBiliCandidate == true ? "B站弹幕" : "Dandanplay",
                    subtitle: settings.danmakuEnabled ? "自动匹配当前集" : "已关闭显示",
                    symbol: "captions.bubble"
                )
                AnimeDanmakuSourceCard(
                    title: activeCandidate?.sourceName ?? "Animeko",
                    subtitle: activeCandidate == nil ? "等待资源命中" : "随当前线路播放",
                    symbol: "rectangle.stack"
                )
            }
        }
        .padding(14)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var playerCommentContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("评论")
                        .font(.title3.weight(.bold))
                    Text(route.episode.displayTitle)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                Spacer()
                Button {
                    Task { await loadEpisodeComments(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(IbiliTheme.accent)
                .disabled(isLoadingComments)
            }

            if isLoadingComments, episodeComments.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
            } else if let commentsErrorText, episodeComments.isEmpty {
                emptyState(title: "评论加载失败", symbol: "bubble.left.and.bubble.right", message: commentsErrorText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if episodeComments.isEmpty {
                emptyState(title: "暂无评论", symbol: "bubble.left.and.bubble.right", message: "Bangumi 暂无当前单集讨论")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(episodeComments) { comment in
                        AnimeEpisodeCommentRow(comment: comment)
                    }
                }
            }
        }
    }

    private func loadEpisodeComments(force: Bool = false) async {
        let episodeID = route.episode.id
        if commentsEpisodeID != episodeID {
            commentsEpisodeID = episodeID
            episodeComments = []
            commentsErrorText = nil
        }
        if force {
            episodeComments = []
            commentsErrorText = nil
        }
        guard force || episodeComments.isEmpty || commentsErrorText != nil else { return }
        guard !isLoadingComments else { return }
        isLoadingComments = true
        defer { isLoadingComments = false }
        do {
            episodeComments = try await Task.detached(priority: .utility) {
                try CoreClient.shared.animeEpisodeComments(episodeID: episodeID)
            }.value
            commentsErrorText = nil
            AppLog.info("anime", "追番单集评论加载完成", metadata: [
                "subjectID": String(route.subject.id),
                "episodeID": String(route.episode.id),
                "count": String(episodeComments.count),
            ])
        } catch {
            commentsErrorText = error.localizedDescription
            AppLog.error("anime", "追番单集评论加载失败", error: error, metadata: [
                "subjectID": String(route.subject.id),
                "episodeID": String(route.episode.id),
            ])
        }
    }

    private var visibleSourceReports: [AnimeMediaSourceReportDTO] {
        Array((vm.diagnostics?.sourceReports ?? []).prefix(8))
    }

    private func handlePresentationEvent(_ event: PlayerPresentationEvent) {
        switch event {
        case .fullscreenChanged(let isFullscreen, let identity):
            guard presentationIdentityMatchesCurrentRoute(identity) else {
                AppLog.debug("anime", "忽略旧追番播放器 fullscreen 回调", metadata: [
                    "eventSessionID": identity.sessionID.uuidString,
                    "currentSessionID": route.id.uuidString,
                ])
                return
            }
            AppLog.debug("anime", "处理追番 fullscreen 展示状态变化", metadata: [
                "subjectID": String(route.subject.id),
                "episodeID": String(route.episode.id),
                "isFullscreen": String(isFullscreen),
                "isInlineHostVisible": String(isInlineHostVisible),
                "sessionID": identity.sessionID.uuidString,
            ])
            self.isFullscreen = isFullscreen
            if isFullscreen {
                _ = presentationState.beginFullscreen(identity)
            } else {
                _ = presentationState.endFullscreen(identity)
                if isInlineHostVisible {
                    _ = presentationState.finishFullscreenReturn(currentPresentationIdentity)
                }
            }
        case .suppressTransientPauseObservation(let identity, let context):
            guard presentationIdentityMatchesCurrentRoute(identity) else { return }
            vm.armTransientPauseSuppression(for: context)
        case .pictureInPictureChanged(let isActive, let identity):
            guard presentationIdentityMatchesCurrentRoute(identity) else {
                AppLog.debug("anime", "忽略旧追番播放器 PiP 回调", metadata: [
                    "eventSessionID": identity.sessionID.uuidString,
                    "currentSessionID": route.id.uuidString,
                ])
                return
            }
            if isActive {
                Orientation.activatePlayerPresentationRoute(route.id)
            }
        case .pictureInPictureRestoreRequested(_, let completion):
            completion(true)
        }
    }

    private func presentationIdentityMatchesCurrentRoute(_ identity: PlayerPresentationIdentity) -> Bool {
        guard identity.sessionID == route.id else { return false }
        if presentationState.accepts(identity) { return true }
        guard let currentPlayerID = vm.player.map(ObjectIdentifier.init),
              let incomingPlayerID = identity.playerID else { return true }
        return currentPlayerID == incomingPlayerID
    }

    private var currentPresentationIdentity: PlayerPresentationIdentity {
        PlayerPresentationIdentity(
            sessionID: route.id,
            playerID: vm.player.map(ObjectIdentifier.init)
        )
    }

    private var isNativePlayerPresentationActive: Bool {
        isFullscreen
            || presentationState.isFullscreenPresentationActive
            || presentationState.isAwaitingInlineFullscreenReturn
    }

    private var isPresentationRouteActive: Bool {
        isInlineHostVisible || isNativePlayerPresentationActive
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

private enum AnimePlayerContentTab: String, CaseIterable, Identifiable {
    case details
    case comments

    var id: String { rawValue }
    var title: String {
        switch self {
        case .details: return "详情"
        case .comments: return "评论"
        }
    }
}

private struct AnimeDanmakuSourceCard: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(IbiliTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AnimeEpisodeCommentRow: View {
    let comment: AnimeEpisodeCommentDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AnimeEpisodeCommentHeader(comment: comment)
            Text(comment.content)
                .font(.body)
                .foregroundStyle(IbiliTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !comment.replies.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(comment.replies.prefix(3)) { reply in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(reply.user.displayName)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(IbiliTheme.accent)
                            Text(reply.content)
                                .font(.footnote)
                                .foregroundStyle(IbiliTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if comment.replies.count > 3 {
                        Text("共 \(comment.replies.count) 条回复")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(IbiliTheme.accent)
                    }
                }
                .padding(10)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(14)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct AnimeEpisodeCommentHeader: View {
    let comment: AnimeEpisodeCommentDTO

    var body: some View {
        HStack(spacing: 10) {
            RemoteImage(url: comment.user.avatar, targetPointSize: CGSize(width: 80, height: 80), quality: 72)
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(comment.user.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(1)
                Text(BiliFormat.relativeDate(comment.createdAt))
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}
