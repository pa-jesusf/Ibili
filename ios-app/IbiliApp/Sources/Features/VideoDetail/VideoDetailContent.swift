import SwiftUI
import UIKit

/// The richer detail content area below the player. Owns its own
/// `VideoDetailViewModel` and the interaction service. Designed to
/// scroll independently below the fixed-height player.
///
/// Layout:
/// 1. Intro (title + stat line)
/// 2. Action row (like / coin / fav / share / watch later)
/// 3. Uploader card
/// 4. Description (expandable)
/// 5. UGC season card / pages picker (when applicable)
/// 6. Tags
/// 7. Segmented tabs: 简介 / 评论 / 相关
struct VideoDetailContent: View {
    let item: FeedItemDTO
    let currentCid: Int64
    let currentSeasonID: Int64
    let currentEpisodeID: Int64
    @ObservedObject private var vm: VideoDetailViewModel
    private let commentListViewModel: CommentListViewModel
    @ObservedObject private var interaction: VideoInteractionService
    private let onScrollOffsetChange: ((CGFloat) -> Void)?
    private let viewPoints: [VideoViewPointDTO]
    private let currentPlaybackSeconds: Double
    private let onSeekToTime: ((Int64) -> Void)?
    @EnvironmentObject private var router: DeepLinkRouter
    @State private var tab: Tab = .intro
    @State private var mountedTabs: Set<Tab> = [.intro]
    @StateObject private var scrollContexts = VideoDetailScrollContexts()
    @State private var detailScrollOffset: CGFloat = 0
    @State private var toastWork: DispatchWorkItem?
    @State private var toast: String?
    @State private var isRefreshingMetadata = false
    @State private var didTriggerUpwardRefreshSinceTop = false
    @State private var lastMetadataRefreshAt = Date.distantPast
    @State private var pgcSeason: PgcSeasonDTO?
    @State private var pgcLoading = false
    @State private var pgcErrorText: String?

    private let topAnchorID = "videoDetailTop"
    private static let upwardRefreshTriggerOffset: CGFloat = 72
    private static let upwardRefreshResetOffset: CGFloat = 8
    private static let metadataRefreshCooldown: TimeInterval = 12
    private static let floatingControlsReservedBottomInset: CGFloat = 82

    init(item: FeedItemDTO,
         currentCid: Int64 = 0,
         currentSeasonID: Int64 = 0,
         currentEpisodeID: Int64 = 0,
         detailViewModel: VideoDetailViewModel,
         commentListViewModel: CommentListViewModel,
         interactionService: VideoInteractionService,
         viewPoints: [VideoViewPointDTO] = [],
         currentPlaybackSeconds: Double = 0,
         onSeekToTime: ((Int64) -> Void)? = nil,
         onScrollOffsetChange: ((CGFloat) -> Void)? = nil) {
        self.item = item
        self.currentCid = currentCid
        self.currentSeasonID = currentSeasonID
        self.currentEpisodeID = currentEpisodeID
        self._vm = ObservedObject(wrappedValue: detailViewModel)
        self.commentListViewModel = commentListViewModel
        self._interaction = ObservedObject(wrappedValue: interactionService)
        self.viewPoints = viewPoints
        self.currentPlaybackSeconds = currentPlaybackSeconds
        self.onSeekToTime = onSeekToTime
        self.onScrollOffsetChange = onScrollOffsetChange
    }

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case intro = "简介"
        case replies = "评论"
        case related = "相关"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .intro:
                return "note.text"
            case .replies:
                return "text.bubble"
            case .related:
                return "rectangle.stack"
            }
        }
    }

    private var visibleTabs: [Tab] {
        item.isPGC ? [.intro, .replies] : Tab.allCases
    }

    var body: some View {
        GeometryReader { viewportProxy in
            ScrollViewReader { proxy in
                scrollContent
                    .background(IbiliTheme.background)
                    .environment(\.commentViewportHeight, max(1, viewportProxy.size.height))
                    .environment(\.commentContentWidth, max(1, viewportProxy.size.width - 32))
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        PlayerDetailFloatingControlCluster(
                            tabs: visibleTabs,
                            selection: $tab,
                            onReselectCurrentTab: {
                                proxy.interruptingScrollTo(
                                    topAnchorID(for: tab),
                                    anchor: .top,
                                    context: scrollContexts.context(for: tab),
                                    animation: .spring(response: 0.28, dampingFraction: 0.88)
                                )
                            }
                        )
                    }
            }
        }
        .onChange(of: tab) { newValue in
            mountedTabs.insert(newValue)
        }
        .onChange(of: visibleTabs) { tabs in
            if !tabs.contains(tab) {
                tab = tabs.first ?? .intro
            }
        }
        .task(id: "\(item.isPGC ? "pgc" : "ugc"):\(item.aid):\(item.bvid):\(item.epID):\(currentSeasonID):\(currentEpisodeID)") {
            if item.isPGC {
                interaction.reset(stat: VideoStatDTO(
                    view: item.play,
                    danmaku: item.danmaku,
                    reply: 0,
                    favorite: 0,
                    coin: 0,
                    share: 0,
                    like: 0
                ))
                await loadPgcSeasonIfNeeded()
                return
            }
            let stat = vm.view?.stat ?? VideoStatDTO(view: 0, danmaku: 0, reply: 0, favorite: 0, coin: 0, share: 0, like: 0)
            interaction.reset(stat: stat)

            let detailAlreadyLoaded = vm.matchesLoadedDetail(aid: item.aid, bvid: item.bvid)
            let interactionAlreadyHydrated = interaction.matchesHydratedState(aid: item.aid, bvid: item.bvid)

            if detailAlreadyLoaded && interactionAlreadyHydrated {
                AppLog.debug("video", "播放页详情复用现有状态", metadata: [
                    "aid": String(item.aid),
                    "bvid": item.bvid,
                ])
            } else if item.aid > 0 || !item.bvid.isEmpty {
                if !detailAlreadyLoaded && !interactionAlreadyHydrated {
                    async let bootstrapTask: Void = vm.bootstrap(aid: item.aid, bvid: item.bvid)
                    async let hydrateTask: Void = interaction.hydrate(aid: item.aid, bvid: item.bvid, ownerMid: nil)
                    _ = await (bootstrapTask, hydrateTask)
                } else {
                    if !detailAlreadyLoaded {
                        await vm.bootstrap(aid: item.aid, bvid: item.bvid)
                    }
                    if !interactionAlreadyHydrated {
                        await interaction.hydrate(aid: item.aid, bvid: item.bvid, ownerMid: nil)
                    }
                }
            } else if !detailAlreadyLoaded {
                await vm.bootstrap(aid: item.aid, bvid: item.bvid)
            }

            if let stat = vm.view?.stat { interaction.reset(stat: stat) }
        }
        .onChange(of: interaction.lastToast) { newToast in
            guard let m = newToast, !m.isEmpty else { return }
            toast = m
            toastWork?.cancel()
            let w = DispatchWorkItem { toast = nil }
            toastWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
        }
        .overlay(alignment: .top) {
            if let m = toast {
                Text(m)
                    .font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    private var commentOID: Int64 {
        item.isPGC ? item.aid : (vm.view?.aid ?? item.aid)
    }

    private var refreshBVID: String {
        let resolved = vm.view?.bvid ?? ""
        return resolved.isEmpty ? item.bvid : resolved
    }

    @ViewBuilder
    private var scrollContent: some View {
        ZStack(alignment: .top) {
            ForEach(visibleTabs) { targetTab in
                if mountedTabs.contains(targetTab) || tab == targetTab {
                    tabScrollContent(for: targetTab)
                        .opacity(tab == targetTab ? 1 : 0)
                        .allowsHitTesting(tab == targetTab)
                        .accessibilityHidden(tab != targetTab)
                        .zIndex(tab == targetTab ? 1 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func tabScrollContent(for targetTab: Tab) -> some View {
        if targetTab == .replies {
            CommentListView(
                oid: item.isPGC ? pgcCommentOID : commentOID,
                kind: item.isPGC ? pgcCommentKind : 1,
                viewModel: commentListViewModel,
                usesVirtualizedList: true,
                onScrollOffsetChange: { value in
                    guard tab == targetTab else { return }
                    handleDetailScrollOffsetChange(value)
                }
            )
            .refreshable {
                if item.isPGC {
                    await commentListViewModel.refresh(oid: pgcCommentOID, kind: pgcCommentKind)
                } else {
                    await commentListViewModel.refresh(oid: commentOID)
                }
            }
        } else if targetTab == .related, !item.isPGC {
            RelatedVideoList(
                items: vm.related,
                isLoadingMore: vm.isLoadingMoreRelated,
                isEnd: vm.relatedIsEnd,
                onTap: { feedItem in
                    router.open(feedItem)
                },
                onReachEnd: {
                    Task { await vm.loadMoreRelated() }
                },
                onScrollOffsetChange: { value in
                    guard tab == targetTab else { return }
                    handleDetailScrollOffsetChange(value)
                }
            )
            .refreshable {
                await refreshMetadata()
            }
        } else if #available(iOS 18.0, *) {
            ScrollView {
                InterruptibleScrollCapture(context: scrollContexts.context(for: targetTab))
                    .frame(width: 0, height: 0)
                Color.clear.frame(height: 0).id(topAnchorID(for: targetTab))
                contentColumn(for: targetTab)
            }
            .refreshable {
                await refreshMetadata()
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, newValue in
                guard tab == targetTab else { return }
                handleDetailScrollOffsetChange(newValue)
            }
        } else {
            ScrollView {
                InterruptibleScrollCapture(context: scrollContexts.context(for: targetTab))
                    .frame(width: 0, height: 0)
                // Top sentinel that reports its position in the named
                // coordinate space. As the user scrolls down, `minY`
                // becomes negative; we feed `-minY` into
                // `detailScrollOffset` so callers can treat it as a
                // positive "distance scrolled from top" value, matching
                // the iOS 18 `contentOffset.y` semantics.
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: DetailScrollOffsetPreferenceKey.self,
                            value: -geo.frame(in: .named(scrollCoordinateSpaceName(for: targetTab))).minY
                        )
                }
                .frame(height: 1)
                .id(topAnchorID(for: targetTab))
                contentColumn(for: targetTab)
            }
            .refreshable {
                await refreshMetadata()
            }
            .coordinateSpace(name: scrollCoordinateSpaceName(for: targetTab))
            .scrollIndicators(.hidden)
            .onPreferenceChange(DetailScrollOffsetPreferenceKey.self) { value in
                guard tab == targetTab else { return }
                handleDetailScrollOffsetChange(value)
            }
        }
    }

    @ViewBuilder
    private func contentColumn(for targetTab: Tab) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                switch targetTab {
                case .intro:
                    introBody
                case .replies:
                    if item.isPGC {
                        CommentListView(oid: pgcCommentOID, kind: pgcCommentKind, viewModel: commentListViewModel)
                            .padding(.horizontal, 16)
                    } else {
                        CommentListView(oid: commentOID, viewModel: commentListViewModel)
                            .padding(.horizontal, 16)
                    }
                case .related:
                    if item.isPGC {
                        EmptyView()
                    } else {
                        RelatedVideoList(
                            items: vm.related,
                            isLoadingMore: vm.isLoadingMoreRelated,
                            isEnd: vm.relatedIsEnd,
                            onTap: { feedItem in
                                router.open(feedItem)
                            },
                            onReachEnd: {
                                Task { await vm.loadMoreRelated() }
                            }
                        )
                        .padding(.horizontal, 12)
                    }
                }
            }
            .padding(.bottom, Self.floatingControlsReservedBottomInset)
        }
        .padding(.top, 12)
    }

    private func topAnchorID(for targetTab: Tab) -> String {
        "\(topAnchorID)-\(targetTab.rawValue)"
    }

    private func scrollCoordinateSpaceName(for targetTab: Tab) -> String {
        "video-detail-scroll-\(targetTab.rawValue)"
    }

    @ViewBuilder
    private var introBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            VideoIntroSection(
                title: vm.view?.title ?? item.title,
                stat: item.isPGC
                    ? VideoStatDTO(view: item.play, danmaku: item.danmaku, reply: 0, favorite: 0, coin: 0, share: 0, like: 0)
                    : vm.view?.stat,
                pubdate: vm.view?.pubdate ?? 0,
                aid: vm.view?.aid ?? item.aid,
                bvid: vm.view?.bvid ?? item.bvid
            )
            .padding(.horizontal, 16)

            if !item.isPGC, let stat = vm.view?.stat {
                if interaction.isHydrating {
                    // Don't flash default-false icons before relation
                    // state arrives — show a spacer-height loader.
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .frame(height: 64)
                } else {
                    VideoActionRow(
                        aid: vm.view?.aid ?? item.aid,
                        bvid: vm.view?.bvid ?? item.bvid,
                        title: vm.view?.title ?? item.title,
                        stat: stat,
                        interaction: interaction
                    )
                    .padding(.horizontal, 8)
                }
            }

            if !item.isPGC, let owner = vm.view?.owner {
                UploaderCardView(owner: owner, interaction: interaction)
                    .padding(.horizontal, 16)
            }

            if item.isPGC {
                pgcIntroBody
            } else if let v = vm.view, !v.desc.isEmpty || !v.descV2.isEmpty {
                VideoDescriptionView(desc: v.desc, descV2: v.descV2)
                    .padding(.horizontal, 16)
            }

            if !viewPoints.isEmpty {
                VideoTimelineSection(
                    viewPoints: viewPoints,
                    currentSeconds: currentPlaybackSeconds,
                    onSeek: { seconds in
                        onSeekToTime?(seconds)
                    }
                )
                .padding(.horizontal, 16)
            }

            if !item.isPGC, let v = vm.view {
                let activeCid = currentCid > 0 ? currentCid : v.cid
                if let season = v.ugcSeason, season.id > 0 {
                    VideoSeasonCard(source: .season(season, currentCid: activeCid)) { aid, bvid, cid in
                        guard cid != activeCid else { return }
                        let next = FeedItemDTO(
                            aid: aid ?? 0,
                            bvid: bvid ?? "",
                            cid: cid,
                            title: "", cover: "", author: "",
                            durationSec: 0, play: 0, danmaku: 0
                        )
                        router.open(next, mode: .replaceCurrent)
                    }
                    .padding(.horizontal, 16)
                } else if v.pages.count > 1 {
                    VideoSeasonCard(source: .pages(aid: v.aid, bvid: v.bvid, pages: v.pages, currentCid: activeCid)) { aid, bvid, cid in
                        guard cid != activeCid else { return }
                        let next = FeedItemDTO(
                            aid: aid ?? v.aid,
                            bvid: (bvid?.isEmpty == false ? bvid : v.bvid) ?? "",
                            cid: cid,
                            title: "", cover: "", author: "",
                            durationSec: 0, play: 0, danmaku: 0
                        )
                        router.open(next, mode: .replaceCurrent)
                    }
                        .padding(.horizontal, 16)
                }
            }

            if !item.isPGC, let tags = vm.view?.tags, !tags.isEmpty {
                VideoTagsView(tags: tags)
                    .padding(.horizontal, 16)
            }

            if vm.isLoading, vm.view == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 30)
            } else if let err = vm.errorText, vm.view == nil {
                emptyState(title: "详情加载失败", symbol: "exclamationmark.triangle", message: err)
                    .padding(.vertical, 20)
            }
        }
    }

    @ViewBuilder
    private var pgcIntroBody: some View {
        if pgcLoading && pgcSeason == nil {
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 24)
        } else if let pgcErrorText, pgcSeason == nil {
            emptyState(title: "番剧详情加载失败", symbol: "exclamationmark.triangle", message: pgcErrorText)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        } else if let season = pgcSeason {
            PgcSeasonIntroView(
                season: season,
                currentEpID: effectivePgcEpisodeID,
                onPickEpisode: { episode in
                    router.open(makePgcFeedItem(season: season, episode: episode), mode: .replaceCurrent)
                }
            )
            .padding(.horizontal, 16)
        }
    }

    private func refreshMetadata(trigger: String = "pull-to-refresh") async {
        if item.isPGC {
            await loadPgcSeasonIfNeeded(force: true)
            await commentListViewModel.refresh(oid: pgcCommentOID, kind: pgcCommentKind)
            return
        }
        guard !isRefreshingMetadata else { return }
        isRefreshingMetadata = true
        lastMetadataRefreshAt = Date()
        defer { isRefreshingMetadata = false }

        let targetAid = commentOID
        let targetBvid = refreshBVID

        AppLog.info("video", "播放页详情刷新触发", metadata: [
            "trigger": trigger,
            "aid": String(targetAid),
            "tab": tab.rawValue,
        ])

        await vm.refresh(aid: targetAid, bvid: targetBvid)

        let resolvedAid = commentOID
        let resolvedBvid = refreshBVID
        if let stat = vm.view?.stat {
            interaction.reset(stat: stat)
        }

        async let hydrateTask: Void = interaction.hydrate(
            aid: resolvedAid,
            bvid: resolvedBvid,
            ownerMid: vm.view?.owner.mid
        )
        async let commentsTask: Void = commentListViewModel.refresh(oid: resolvedAid)
        _ = await (hydrateTask, commentsTask)
    }

    private var effectivePgcSeasonID: Int64 {
        currentSeasonID > 0 ? currentSeasonID : item.seasonID
    }

    private var effectivePgcEpisodeID: Int64 {
        currentEpisodeID > 0 ? currentEpisodeID : item.epID
    }

    private var pgcCommentOID: Int64 {
        item.aid > 0 ? item.aid : (pgcSeason?.episodes.first(where: { $0.epID == effectivePgcEpisodeID })?.aid ?? 0)
    }

    private var pgcCommentKind: Int32 {
        1
    }

    private func loadPgcSeasonIfNeeded(force: Bool = false) async {
        let seasonID = effectivePgcSeasonID
        let epID = effectivePgcEpisodeID
        guard seasonID > 0 || epID > 0 else { return }
        if !force, let loaded = pgcSeason,
           (seasonID <= 0 || loaded.seasonID == seasonID),
           (epID <= 0 || loaded.episodes.contains(where: { $0.epID == epID })) {
            return
        }
        pgcLoading = true
        pgcErrorText = nil
        defer { pgcLoading = false }
        do {
            let season = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.pgcSeason(seasonID: seasonID, epID: epID)
            }.value
            pgcSeason = season
        } catch {
            pgcErrorText = (error as NSError).localizedDescription
            AppLog.error("player", "PGC 详情加载失败", error: error, metadata: [
                "seasonID": String(seasonID),
                "epID": String(epID),
            ])
        }
    }

    private func makePgcFeedItem(season: PgcSeasonDTO, episode: PgcEpisodeDTO) -> FeedItemDTO {
        let seasonTitle = season.seasonTitle.isEmpty ? season.title : season.seasonTitle
        let epTitle = episode.longTitle.isEmpty ? episode.title : episode.longTitle
        let title = [seasonTitle, epTitle].filter { !$0.isEmpty }.joined(separator: " · ")
        return FeedItemDTO(
            aid: episode.aid,
            bvid: episode.bvid,
            cid: episode.cid,
            title: title.isEmpty ? seasonTitle : title,
            cover: episode.cover.isEmpty ? season.cover : episode.cover,
            author: season.upName,
            durationSec: episode.durationSec,
            play: season.stat.view,
            danmaku: season.stat.danmaku,
            pubdate: episode.pubTime,
            epID: episode.epID,
            seasonID: season.seasonID,
            isPGC: true
        )
    }

    private func handleDetailScrollOffsetChange(_ newValue: CGFloat) {
        let clampedOffset = max(0, newValue)
        detailScrollOffset = clampedOffset
        onScrollOffsetChange?(clampedOffset)

        if clampedOffset <= Self.upwardRefreshResetOffset {
            didTriggerUpwardRefreshSinceTop = false
            return
        }

        guard clampedOffset >= Self.upwardRefreshTriggerOffset,
              !didTriggerUpwardRefreshSinceTop,
              !isRefreshingMetadata,
              Date().timeIntervalSince(lastMetadataRefreshAt) >= Self.metadataRefreshCooldown else {
            return
        }

        didTriggerUpwardRefreshSinceTop = true
        Task {
            await refreshMetadata(trigger: "upward-swipe")
        }
    }
}

private struct DetailScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private final class VideoDetailScrollContexts: ObservableObject {
    private var contexts: [VideoDetailContent.Tab: InterruptibleScrollContext] = [:]

    func context(for tab: VideoDetailContent.Tab) -> InterruptibleScrollContext {
        if let existing = contexts[tab] {
            return existing
        }
        let context = InterruptibleScrollContext()
        contexts[tab] = context
        return context
    }
}

private struct PlayerDetailFloatingControlCluster: View {
    private static let systemTabBarHeight: CGFloat = 50
    private static let systemTabBarIPadVisualLift: CGFloat = 8
    private static let systemTabBarPhoneVisualLift: CGFloat = 16

    let tabs: [VideoDetailContent.Tab]
    @Binding var selection: VideoDetailContent.Tab
    let onReselectCurrentTab: () -> Void

    private var systemTabBarVisualLift: CGFloat {
        UIDevice.current.userInterfaceIdiom == .phone
            ? Self.systemTabBarPhoneVisualLift
            : Self.systemTabBarIPadVisualLift
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GeometryReader { proxy in
                let availableHeight = max(1, proxy.size.height)
                let barHeight = min(Self.systemTabBarHeight, availableHeight)
                let centeredY = max(0, (availableHeight - barHeight) / 2)
                let y = min(max(0, centeredY + systemTabBarVisualLift), max(0, availableHeight - barHeight))
                PlayerDetailSystemTabBar(
                    tabs: tabs,
                    selection: $selection,
                    onReselectCurrentTab: onReselectCurrentTab
                )
                .frame(maxWidth: .infinity)
                .frame(height: barHeight)
                .offset(y: y)
            }
            .frame(height: Self.systemTabBarHeight + systemTabBarVisualLift * 2)
        } else {
            PlayerDetailFloatingTabs(
                tabs: tabs,
                selection: $selection,
                onReselectCurrentTab: onReselectCurrentTab
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }
}

@available(iOS 26.0, *)
private struct PlayerDetailSystemTabBar: UIViewRepresentable {
    let tabs: [VideoDetailContent.Tab]
    @Binding var selection: VideoDetailContent.Tab
    let onReselectCurrentTab: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, onReselectCurrentTab: onReselectCurrentTab)
    }

    func makeUIView(context: Context) -> UITabBar {
        let tabBar = UITabBar(frame: .zero)
        tabBar.delegate = context.coordinator
        tabBar.tintColor = IbiliTheme.accentUIColor
        tabBar.unselectedItemTintColor = .secondaryLabel
        tabBar.itemPositioning = .automatic
        updateItems(on: tabBar, coordinator: context.coordinator)
        return tabBar
    }

    func updateUIView(_ uiView: UITabBar, context: Context) {
        updateItems(on: uiView, coordinator: context.coordinator)
    }

    private func updateItems(on tabBar: UITabBar, coordinator: Coordinator) {
        let resolvedItems = nativeItems
        coordinator.items = resolvedItems
        tabBar.tintColor = IbiliTheme.accentUIColor
        tabBar.unselectedItemTintColor = .secondaryLabel
        tabBar.setItems(resolvedItems.map(\.tabBarItem), animated: false)
        if let selectedItem = resolvedItems.first(where: { $0.tab == selection }) {
            tabBar.selectedItem = selectedItem.tabBarItem
        }
    }

    private var nativeItems: [NativeItem] {
        tabs.map { tab in
            NativeItem(
                kind: .tab(tab),
                tabBarItem: UITabBarItem(
                    title: tab.rawValue,
                    image: UIImage(systemName: tab.systemImage),
                    tag: tab.hashValue
                )
            )
        }
    }

    final class Coordinator: NSObject, UITabBarDelegate {
        var selection: Binding<VideoDetailContent.Tab>
        var onReselectCurrentTab: () -> Void
        var items: [NativeItem] = []

        init(selection: Binding<VideoDetailContent.Tab>, onReselectCurrentTab: @escaping () -> Void) {
            self.selection = selection
            self.onReselectCurrentTab = onReselectCurrentTab
        }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            guard let matchedItem = items.first(where: { $0.tabBarItem == item }) else { return }
            guard case .tab(let tab) = matchedItem.kind else { return }

            if selection.wrappedValue == tab {
                onReselectCurrentTab()
            } else {
                selection.wrappedValue = tab
            }
        }
    }

    struct NativeItem: Equatable {
        enum Kind: Equatable {
            case tab(VideoDetailContent.Tab)
        }

        let kind: Kind
        let tabBarItem: UITabBarItem

        var tab: VideoDetailContent.Tab? {
            guard case .tab(let tab) = kind else { return nil }
            return tab
        }

        static func == (lhs: NativeItem, rhs: NativeItem) -> Bool {
            lhs.kind == rhs.kind
        }
    }
}

private struct PlayerDetailFloatingTabs: View {
    let tabs: [VideoDetailContent.Tab]
    @Binding var selection: VideoDetailContent.Tab
    let onReselectCurrentTab: () -> Void

    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tabs) { tab in
                let isSelected = selection == tab
                Button {
                    if isSelected {
                        onReselectCurrentTab()
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            selection = tab
                        }
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? IbiliTheme.accent : IbiliTheme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(IbiliTheme.accent.opacity(0.16))
                                    .matchedGeometryEffect(id: "player.detail.floating.tab", in: indicator)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(PlayerDetailFloatingTabsBackground())
    }
}

private struct PlayerDetailFloatingTabsBackground: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            Capsule()
                .fill(.regularMaterial)
                .glassEffect(.regular, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5))
        } else {
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5))
        }
    }
}
