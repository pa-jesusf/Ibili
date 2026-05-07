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
    @ObservedObject private var vm: VideoDetailViewModel
    private let commentListViewModel: CommentListViewModel
    @ObservedObject private var interaction: VideoInteractionService
    @EnvironmentObject private var router: DeepLinkRouter
    @State private var tab: Tab = .intro
    @State private var detailScrollOffset: CGFloat = 0
    @State private var toastWork: DispatchWorkItem?
    @State private var toast: String?
    @State private var isRefreshingMetadata = false
    @State private var didTriggerUpwardRefreshSinceTop = false
    @State private var lastMetadataRefreshAt = Date.distantPast

    private let topAnchorID = "videoDetailTop"
    private static let upwardRefreshTriggerOffset: CGFloat = 72
    private static let upwardRefreshResetOffset: CGFloat = 8
    private static let metadataRefreshCooldown: TimeInterval = 12
    private static let floatingControlsReservedBottomInset: CGFloat = 24

    init(item: FeedItemDTO,
         detailViewModel: VideoDetailViewModel,
         commentListViewModel: CommentListViewModel,
         interactionService: VideoInteractionService) {
        self.item = item
        self._vm = ObservedObject(wrappedValue: detailViewModel)
        self.commentListViewModel = commentListViewModel
        self._interaction = ObservedObject(wrappedValue: interactionService)
    }

    enum Tab: String, CaseIterable, Identifiable {
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

    var body: some View {
        ScrollViewReader { proxy in
            scrollContent
                .background(IbiliTheme.background)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    PlayerDetailFloatingControlCluster(
                        tabs: Tab.allCases,
                        selection: $tab,
                        onReselectCurrentTab: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                proxy.scrollTo(topAnchorID, anchor: .top)
                            }
                        }
                    )
                }
        }
        .task(id: "\(item.aid):\(item.bvid)") {
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
        vm.view?.aid ?? item.aid
    }

    private var refreshBVID: String {
        let resolved = vm.view?.bvid ?? ""
        return resolved.isEmpty ? item.bvid : resolved
    }

    @ViewBuilder
    private var scrollContent: some View {
        if #available(iOS 18.0, *) {
            ScrollView {
                Color.clear.frame(height: 0).id(topAnchorID)
                contentColumn
            }
            .refreshable {
                await refreshMetadata()
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, newValue in
                handleDetailScrollOffsetChange(newValue)
            }
        } else {
            ScrollView {
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
                            value: -geo.frame(in: .named("video-detail-scroll")).minY
                        )
                }
                .frame(height: 1)
                .id(topAnchorID)
                contentColumn
            }
            .refreshable {
                await refreshMetadata()
            }
            .coordinateSpace(name: "video-detail-scroll")
            .scrollIndicators(.hidden)
            .onPreferenceChange(DetailScrollOffsetPreferenceKey.self) { value in
                handleDetailScrollOffsetChange(value)
            }
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                switch tab {
                case .intro:
                    introBody
                case .replies:
                    CommentListView(oid: commentOID, viewModel: commentListViewModel)
                        .padding(.horizontal, 16)
                case .related:
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
            .padding(.bottom, Self.floatingControlsReservedBottomInset)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var introBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            VideoIntroSection(
                title: vm.view?.title ?? item.title,
                stat: vm.view?.stat,
                pubdate: vm.view?.pubdate ?? 0,
                aid: vm.view?.aid ?? item.aid,
                bvid: vm.view?.bvid ?? item.bvid
            )
            .padding(.horizontal, 16)

            if let stat = vm.view?.stat {
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

            if let owner = vm.view?.owner {
                UploaderCardView(owner: owner, interaction: interaction)
                    .padding(.horizontal, 16)
            }

            if let v = vm.view, !v.desc.isEmpty || !v.descV2.isEmpty {
                VideoDescriptionView(desc: v.desc, descV2: v.descV2)
                    .padding(.horizontal, 16)
            }

            if let v = vm.view {
                let currentCid = v.cid
                if let season = v.ugcSeason, season.id > 0 {
                    VideoSeasonCard(source: .season(season, currentCid: currentCid)) { aid, bvid, cid in
                        guard cid != currentCid else { return }
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
                    VideoSeasonCard(source: .pages(aid: v.aid, bvid: v.bvid, pages: v.pages, currentCid: currentCid)) { aid, bvid, cid in
                        guard cid != currentCid else { return }
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

            if let tags = vm.view?.tags, !tags.isEmpty {
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

    private func refreshMetadata(trigger: String = "pull-to-refresh") async {
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

    private func handleDetailScrollOffsetChange(_ newValue: CGFloat) {
        detailScrollOffset = newValue

        if newValue <= Self.upwardRefreshResetOffset {
            didTriggerUpwardRefreshSinceTop = false
            return
        }

        guard newValue >= Self.upwardRefreshTriggerOffset,
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

private struct PlayerDetailFloatingControlCluster: View {
    private static let systemTabBarBottomOffset: CGFloat = 55

    let tabs: [VideoDetailContent.Tab]
    @Binding var selection: VideoDetailContent.Tab
    let onReselectCurrentTab: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            PlayerDetailSystemTabBar(
                tabs: tabs,
                selection: $selection,
                onReselectCurrentTab: onReselectCurrentTab
            )
            .frame(maxWidth: .infinity)
            .offset(y: Self.systemTabBarBottomOffset)
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

