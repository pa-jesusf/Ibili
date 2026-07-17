import SwiftUI
import UIKit

struct HomeView: View {
    @Binding private var section: HomeFeedSection
    @State private var collectionChromeState = FeedChromeScrollState()
    @State private var liveChromeState = FeedChromeScrollState()
    @StateObject private var recommendVM: HomeViewModel
    @StateObject private var hotVM: HomeViewModel
    @StateObject private var liveVM = LiveHomeViewModel()
    @StateObject private var prefetch = FeedPrefetchCoordinator()
    @EnvironmentObject private var tabReselect: TabReselectSignals

    init(section: Binding<HomeFeedSection>) {
        _section = section
        _recommendVM = StateObject(wrappedValue: HomeViewModel(section: .recommend))
        _hotVM = StateObject(wrappedValue: HomeViewModel(section: .hot))
    }

    var body: some View {
        switch section {
        case .recommend, .hot:
            FeedCollectionChrome(
                title: "主页",
                tabs: Array(HomeFeedSection.allCases),
                tabTitle: { $0.title },
                selection: $section,
                scrollState: collectionChromeState
            ) {
                HomeFeedPage(
                    section: $section,
                    vm: activeViewModel,
                    prefetch: prefetch,
                    scrollToTopSignal: tabReselect.home,
                    scrollState: collectionChromeState
                )
            }
        case .live:
            FeedCollectionChrome(
                title: "主页",
                tabs: Array(HomeFeedSection.allCases),
                tabTitle: { $0.title },
                selection: $section,
                scrollState: liveChromeState
            ) {
                HomeLiveFeedPage(
                    vm: liveVM,
                    scrollToTopSignal: tabReselect.home,
                    scrollState: liveChromeState
                )
            }
        }
    }

    private var activeViewModel: HomeViewModel {
        switch section {
        case .recommend:
            return recommendVM
        case .hot, .live:
            return hotVM
        }
    }
}

private struct HomeFeedPage: View {
    @Binding var section: HomeFeedSection
    @ObservedObject var vm: HomeViewModel
    let prefetch: FeedPrefetchCoordinator
    let scrollToTopSignal: Int
    let scrollState: FeedChromeScrollState

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.rootContentNavigation) private var rootNavigation
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation
    @Environment(\.prefersSplitRootSelection) private var prefersSplitRootSelection
    @Environment(\.splitFeedColumnLimit) private var splitFeedColumnLimit
    @State private var toast: String?
    @State private var toastWork: DispatchWorkItem?

    var body: some View {
        let recommendSource = settings.homeRecommendSource
        collectionSurface
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.72)))
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: toast)
        .task(id: vm.section) {
            await vm.loadInitial(recommendSource: recommendSource)
        }
        .onChange(of: settings.homeRecommendSource.rawValue) { _ in
            guard vm.section == .recommend else { return }
            Task { await vm.refresh(recommendSource: settings.homeRecommendSource) }
        }
        .onAppear {
            updatePrefetchSettings()
        }
        .onChange(of: settings.cdnService.rawValue) { _ in
            updatePrefetchSettings()
        }
        .onChange(of: settings.preferredQn) { _ in
            updatePrefetchSettings()
            PlayUrlPrefetcher.shared.clear()
        }
        .onChange(of: settings.preferredAudioQn) { _ in
            updatePrefetchSettings()
            PlayUrlPrefetcher.shared.clear()
        }
    }

    private func openFeedItem(_ item: FeedItemDTO) {
        if isInPlayerHostNavigation {
            router.open(item)
        } else if prefersSplitRootSelection {
            router.select(item)
        } else {
            rootNavigation.openPlayer(item)
        }
    }

    private var collectionSurface: some View {
        GeometryReader { geo in
            let resolvedColumns = settings.effectiveColumns(horizontal: hSizeClass, width: geo.size.width)
            let columns = splitFeedColumnLimit.map { min(resolvedColumns, $0) } ?? resolvedColumns
            let usesTopTrailingDuration = UIDevice.current.userInterfaceIdiom == .phone && columns >= 3

            HomeFeedCollectionView(
                items: vm.items,
                columns: columns,
                imageQuality: settings.resolvedImageQuality(),
                meta: settings.homeCardMeta,
                usesTopTrailingDuration: usesTopTrailingDuration,
                isLoading: vm.isLoading,
                isEnd: vm.isEnd,
                scrollToTopSignal: scrollToTopSignal,
                scrollState: scrollState,
                onRefresh: {
                    Task { await vm.refresh(recommendSource: settings.homeRecommendSource) }
                },
                onLoadMore: {
                    Task { await vm.loadMore(recommendSource: settings.homeRecommendSource) }
                },
                onOpen: openFeedItem,
                onTouchDown: prefetch.touchDown,
                onViewportChanged: updateVisibleItems,
                onMenuAction: handleCardAction
            )
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .modifier(ProMotionScrollHint())
            .overlay {
                if let error = vm.errorText, vm.items.isEmpty, !vm.isLoading {
                    homeErrorState(error)
                }
            }
        }
    }

    private func homeErrorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("重试") { Task { await vm.refresh(recommendSource: settings.homeRecommendSource) } }
                .buttonStyle(.borderedProminent).tint(IbiliTheme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 28)
    }

    private func updateVisibleItems(_ indices: [Int]) {
        guard let first = indices.first, let last = indices.last else {
            prefetch.visibleItemsChanged([])
            return
        }
        let lower = max(0, first - 4)
        let upper = min(vm.items.count, last + 9)
        guard lower < upper else { return }
        prefetch.visibleItemsChanged(Array(vm.items[lower..<upper]))
    }

    private func handleCardAction(item: FeedItemDTO, action: VideoCardOverflowAction) {
        switch action {
        case .copyBVID:
            copyBVID(item.bvid)
        case .watchLater:
            addWatchLater(aid: item.aid)
        case .visitOwner:
            openOwner(mid: item.ownerMID)
        case .plainDislike:
            markNotInterested(item: item)
        case .undoDislike:
            undoNotInterested(item: item)
        case .dislikeReason(let reason):
            submitFeedDislike(item: item, reason: reason, isFeedback: false)
        case .feedbackReason(let reason):
            submitFeedDislike(item: item, reason: reason, isFeedback: true)
        case .blockOwner:
            blockOwner(mid: item.ownerMID, author: item.author)
        }
    }

    private func openOwner(mid: Int64) {
        guard mid > 0 else {
            showToast("无法识别 UP 主")
            return
        }
        if isInPlayerHostNavigation {
            router.openUserSpace(mid: mid)
        } else if prefersSplitRootSelection {
            router.selectUserSpace(mid: mid)
        } else {
            rootNavigation.openUserSpace(mid: mid)
        }
    }

    private func copyBVID(_ bvid: String) {
        let value = bvid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            showToast("此视频暂无 BV 号")
            return
        }
        UIPasteboard.general.string = value
        showToast("已复制 BV 号")
    }

    private func addWatchLater(aid: Int64) {
        guard aid > 0 else { return }
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.watchLaterAdd(aid: aid)
                }.value
                showToast("已添加稍后再看")
            } catch {
                showToast("稍后再看失败")
                AppLog.error("home", "卡片菜单添加稍后再看失败", error: error, metadata: [
                    "aid": String(aid),
                ])
            }
        }
    }

    private func markNotInterested(item: FeedItemDTO) {
        let aid = item.aid
        guard aid > 0 else { return }
        vm.hideItem(aid: aid)
        showToast("已减少此类推荐")
        Task.detached(priority: .utility) {
            do {
                try CoreClient.shared.archiveDislike(aid: aid)
            } catch {
                AppLog.error("home", "卡片菜单不感兴趣同步失败", error: error, metadata: [
                    "aid": String(aid),
                ])
            }
        }
    }

    private func undoNotInterested(item: FeedItemDTO) {
        let aid = item.aid
        let feedGoto = item.feedGoto
        let feedID = item.feedID
        let usesFeedReasons = !item.dislikeReasons.isEmpty || !item.feedbackReasons.isEmpty
        guard aid > 0 else { return }
        showToast("正在撤销")
        Task { @MainActor in
            do {
                try await Task.detached(priority: .utility) {
                    if usesFeedReasons, !feedGoto.isEmpty, feedID > 0 {
                        try CoreClient.shared.feedDislikeCancel(goto: feedGoto, id: feedID)
                    } else {
                        try CoreClient.shared.archiveDislike(aid: aid, dislike: false)
                    }
                }.value
                showToast("已撤销")
            } catch {
                showToast("撤销失败")
                AppLog.error("home", "卡片菜单撤销不感兴趣失败", error: error, metadata: [
                    "aid": String(aid),
                    "feedID": String(feedID),
                    "goto": feedGoto,
                ])
            }
        }
    }

    private func submitFeedDislike(item: FeedItemDTO, reason: FeedDislikeReasonDTO, isFeedback: Bool) {
        let aid = item.aid
        let feedGoto = item.feedGoto
        let feedID = item.feedID
        let reasonID = reason.id
        let toast = reason.toast.trimmingCharacters(in: .whitespacesAndNewlines)
        guard feedID > 0, !feedGoto.isEmpty else {
            markNotInterested(item: item)
            return
        }
        Task { @MainActor in
            do {
                try await Task.detached(priority: .utility) {
                    if isFeedback {
                        try CoreClient.shared.feedDislike(goto: feedGoto, id: feedID, feedbackID: reasonID)
                    } else {
                        try CoreClient.shared.feedDislike(goto: feedGoto, id: feedID, reasonID: reasonID)
                    }
                }.value
                vm.hideItem(aid: aid)
                showToast(toast.isEmpty ? "已减少此类推荐" : toast)
            } catch {
                showToast("提交失败")
                AppLog.error("home", "卡片菜单不感兴趣原因提交失败", error: error, metadata: [
                    "aid": String(aid),
                    "feedID": String(feedID),
                    "goto": feedGoto,
                    "reasonID": String(reasonID),
                    "isFeedback": String(isFeedback),
                ])
            }
        }
    }

    private func blockOwner(mid: Int64, author: String) {
        guard mid > 0 else {
            showToast("无法识别 UP 主")
            return
        }
        let owner = author.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.hideItems(fromOwner: mid)
        showToast("已从当前列表隐藏")
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    // Bilibili relation API: act 5 = 拉黑.
                    try CoreClient.shared.relationModify(fid: mid, act: 5)
                }.value
                showToast(owner.isEmpty ? "已拉黑 UP 主" : "已拉黑 \(owner)")
            } catch {
                showToast("拉黑失败")
                AppLog.error("home", "卡片菜单拉黑失败", error: error, metadata: [
                    "mid": String(mid),
                ])
            }
        }
    }

    private func showToast(_ message: String) {
        toast = message
        toastWork?.cancel()
        let work = DispatchWorkItem { toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func updatePrefetchSettings() {
        prefetch.update(
            preferredQn: Int64(settings.resolvedPreferredVideoQn()),
            preferredAudioQn: Int64(settings.resolvedPreferredAudioQn()),
            cdnSelection: settings.cdnService.rawValue
        )
    }

}

private struct HomeLiveFeedPage: View {
    @ObservedObject var vm: LiveHomeViewModel
    let scrollToTopSignal: Int
    let scrollState: FeedChromeScrollState

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.rootContentNavigation) private var rootNavigation
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation
    @Environment(\.prefersSplitRootSelection) private var prefersSplitRootSelection
    @Environment(\.splitFeedColumnLimit) private var splitFeedColumnLimit

    var body: some View {
        GeometryReader { geo in
            let resolvedCols = settings.effectiveColumns(horizontal: hSizeClass, width: geo.size.width)
            let cols = splitFeedColumnLimit.map { min(resolvedCols, $0) } ?? resolvedCols
            let metrics = HomeSwiftUIGridMetrics(containerWidth: geo.size.width, columns: cols)
            let cardHeight = (metrics.cardWidth / VideoCoverView.aspectRatio).rounded() + 78
            VirtualizedCollectionSurface(
                items: vm.items,
                layout: .grid(
                    columns: cols,
                    horizontalInset: metrics.horizontalPadding,
                    topInset: 8,
                    bottomInset: 32,
                    interitemSpacing: metrics.spacing,
                    rowSpacing: metrics.rowSpacing,
                    height: .absolute(cardHeight)
                ),
                footer: liveFooter,
                showsRefresh: true,
                scrollToTopSignal: scrollToTopSignal,
                prefetchThreshold: 4,
                scrollState: scrollState,
                onRefresh: {
                    Task { await vm.refresh() }
                },
                onLoadMore: {
                    Task { await vm.loadMore() }
                },
                onOpen: openLiveItem,
                onPrefetch: { items, cardWidth in
                    prefetchLiveCovers(items, cardWidth: cardWidth)
                },
                splitTransitionIdentity: { FeedStableIdentity($0) },
                splitTransitionHeight: { _, width in
                    (width / VideoCoverView.aspectRatio).rounded() + 78
                }
            ) { item, cardWidth in
                AnyView(
                    LiveCardView(
                        item: item,
                        cardWidth: cardWidth,
                        imageQuality: settings.resolvedImageQuality()
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                )
            }
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .modifier(ProMotionScrollHint())
            .overlay {
                if let err = vm.errorText, vm.items.isEmpty, !vm.isLoading {
                    VStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.largeTitle)
                        Text(err)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("重试") { Task { await vm.refresh() } }
                            .buttonStyle(.borderedProminent)
                            .tint(IbiliTheme.accent)
                    }
                    .padding(.horizontal, 20)
                } else if vm.items.isEmpty {
                    emptyState(title: "暂无直播", symbol: "dot.radiowaves.left.and.right")
                }
            }
        }
        .task { await vm.loadInitial() }
    }

    private var liveFooter: (() -> AnyView)? {
        guard !vm.items.isEmpty else { return nil }
        if vm.isEnd {
            return {
                AnyView(
                    Text("已经到底了")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                )
            }
        }
        return nil
    }

    private func openLiveItem(_ item: LiveFeedItemDTO) {
        let cover = item.systemCover.isEmpty ? item.cover : item.systemCover
        if isInPlayerHostNavigation {
            router.openLive(
                roomID: item.roomID,
                title: item.title,
                cover: cover,
                anchorName: item.uname
            )
        } else if prefersSplitRootSelection {
            router.selectLive(
                roomID: item.roomID,
                title: item.title,
                cover: cover,
                anchorName: item.uname
            )
        } else {
            rootNavigation.openLive(
                roomID: item.roomID,
                title: item.title,
                cover: cover,
                anchorName: item.uname
            )
        }
    }

    private func prefetchLiveCovers(_ items: [LiveFeedItemDTO], cardWidth: CGFloat) {
        let covers = items.map { item in
            item.systemCover.isEmpty ? item.cover : item.systemCover
        }
        CoverImagePrefetcher.shared.prefetch(
            covers,
            targetPointSize: CGSize(
                width: cardWidth,
                height: (cardWidth / VideoCoverView.aspectRatio).rounded()
            ),
            quality: settings.resolvedImageQuality()
        )
    }

}

private struct HomeSwiftUIGridMetrics {
    let horizontalPadding: CGFloat = 12
    let spacing: CGFloat = 12
    let rowSpacing: CGFloat = 14
    let cardWidth: CGFloat

    init(containerWidth: CGFloat, columns: Int) {
        let clampedColumns = max(1, columns)
        let totalSpacing = spacing * CGFloat(clampedColumns - 1) + horizontalPadding * 2
        cardWidth = max(1, floor((containerWidth - totalSpacing) / CGFloat(clampedColumns)))
    }
}
