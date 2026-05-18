import AVKit
import SwiftUI

struct AnimePlayerView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.dismissPlayerHost) private var dismissPlayerHost
    @StateObject private var sourceStore = AnimeSourceStore.shared
    @StateObject private var vm = AnimePlayerViewModel()
    @State private var presentationRouteActive = false
    @State private var lifecycleID = UUID()
    @State private var createdController: AVPlayerViewController?
    @State private var showsCandidates = false
    @State private var showsSourceSettings = false
    @State private var captchaRequest: AnimeCaptchaRequest?
    @State private var webResolverRequest: AnimeWebVideoResolveRequest?

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
        .navigationBarBackButtonHidden(true)
        .task(id: route.id) {
            await sourceStore.ensureDefaultSubscriptionsLoaded()
            await vm.load(
                route: route,
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: dismissPlayerHost) {
                    Label("返回", systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("数据源")
                        .font(.headline)
                    Text(resourceSummaryText)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                Spacer()
                if vm.isLoading || vm.isSearchingMore {
                    ProgressView().controlSize(.small)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textSecondary)
            }
            if let activeCandidate {
                AnimeActiveResourceRow(candidate: activeCandidate, format: vm.currentPlay?.format ?? "")
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
                        AnimeSourceReportRow(report: report, showsCaptchaButton: false) {}
                    }
                }
            }
        }
        .padding(12)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            showsCandidates = true
        }
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
