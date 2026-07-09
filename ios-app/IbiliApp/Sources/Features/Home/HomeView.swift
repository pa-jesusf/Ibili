import SwiftUI
import UIKit

struct HomeView: View {
    @Binding private var section: HomeFeedSection
    @State private var headerCollapseProgress: CGFloat = 0
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
        FeedChrome(
            title: "主页",
            tabs: Array(HomeFeedSection.allCases),
            tabTitle: { $0.title },
            selection: $section,
            headerCollapseProgress: $headerCollapseProgress
        ) {
            switch section {
            case .recommend, .hot:
                HomeFeedPage(
                    section: $section,
                    collapseProgress: $headerCollapseProgress,
                    vm: activeViewModel,
                    prefetch: prefetch,
                    scrollToTopSignal: tabReselect.home
                )
            case .live:
                HomeLiveFeedPage(
                    section: $section,
                    collapseProgress: $headerCollapseProgress,
                    vm: liveVM,
                    scrollToTopSignal: tabReselect.home
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
    @Binding var collapseProgress: CGFloat
    @ObservedObject var vm: HomeViewModel
    let prefetch: FeedPrefetchCoordinator
    let scrollToTopSignal: Int

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
        feedGrid
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
    }

    private var feedGrid: some View {
        GeometryReader { geo in
            let resolvedCols = settings.effectiveColumns(horizontal: hSizeClass, width: geo.size.width)
            let cols = splitFeedColumnLimit.map { min(resolvedCols, $0) } ?? resolvedCols
            let usesTopTrailingDuration = UIDevice.current.userInterfaceIdiom == .phone && cols >= 3
            let metrics = homeGridMetrics(containerWidth: geo.size.width, columns: cols)
            let gridItems = Array(
                repeating: GridItem(.fixed(metrics.cardWidth), spacing: metrics.spacing, alignment: .top),
                count: max(1, cols)
            )

            ZStack {
                feedScrollContent(
                    columns: gridItems,
                    columnCount: cols,
                    metrics: metrics,
                    usesTopTrailingDuration: usesTopTrailingDuration
                )
            }
            .transaction { $0.animation = nil }
            .onAppear {
                prefetch.update(
                    preferredQn: Int64(settings.resolvedPreferredVideoQn()),
                    preferredAudioQn: Int64(settings.resolvedPreferredAudioQn()),
                    cdnSelection: settings.cdnService.rawValue
                )
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
    }

    private func homeGridMetrics(containerWidth: CGFloat, columns: Int) -> HomeSwiftUIGridMetrics {
        HomeSwiftUIGridMetrics(containerWidth: containerWidth, columns: columns)
    }

    private func visibleItems(around index: Int) -> [FeedItemDTO] {
        guard vm.items.indices.contains(index) else { return [] }
        let lower = max(0, index - 4)
        let upper = min(vm.items.count, index + 8)
        return Array(vm.items[lower..<upper])
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

    @ViewBuilder
    private func feedScrollContent(columns: [GridItem],
                                   columnCount: Int,
                                   metrics: HomeSwiftUIGridMetrics,
                                   usesTopTrailingDuration: Bool) -> some View {
        FeedScrollPage(
            title: "主页",
            coordinateSpace: "home-\(vm.section.rawValue)",
            scrollToTopSignal: scrollToTopSignal,
            headerCollapseProgress: $collapseProgress,
            showsRefresh: true,
            onRefresh: {
                await vm.refresh(recommendSource: settings.homeRecommendSource)
            }
        ) {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView()
                    .tint(IbiliTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
            } else if let err = vm.errorText, vm.items.isEmpty {
                homeErrorState(err)
            } else {
                feedItemsGrid(
                    columns: columns,
                    columnCount: columnCount,
                    metrics: metrics,
                    usesTopTrailingDuration: usesTopTrailingDuration
                )
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

    private func feedItemsGrid(columns: [GridItem],
                               columnCount: Int,
                               metrics: HomeSwiftUIGridMetrics,
                               usesTopTrailingDuration: Bool) -> some View {
        PagedCollectionSurface(
            items: vm.items,
            layout: .grid(columns: columns, spacing: metrics.rowSpacing, footerColumnSpan: max(1, columnCount)),
            isLoading: vm.isLoading,
            isEnd: vm.isEnd,
            prefetchThreshold: 4,
            onReachEnd: {
                Task { await vm.loadMore(recommendSource: settings.homeRecommendSource) }
            },
            onItemAppear: { index, item in
                prefetch.visibleItemsChanged(visibleItems(around: index))
                prefetchCovers(aroundIndex: index, cardWidth: metrics.cardWidth)
            }
        ) {
            EmptyView()
        } itemContent: { _, item in
            feedCard(item: item, metrics: metrics, usesTopTrailingDuration: usesTopTrailingDuration)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 32)
    }

    private func feedCard(item: FeedItemDTO,
                          metrics: HomeSwiftUIGridMetrics,
                          usesTopTrailingDuration: Bool) -> some View {
        VideoCardView(
            item: item,
            cardWidth: metrics.cardWidth,
            imageQuality: settings.resolvedImageQuality(),
            showsDurationAtTopTrailing: usesTopTrailingDuration,
            meta: settings.homeCardMeta
        )
        .overlay(alignment: .bottomTrailing) {
            feedCardMenu(for: item)
                .padding(.trailing, 2)
                .padding(.bottom, 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            prefetch.touchDown(item)
            openFeedItem(item)
        }
    }

    private func feedCardMenu(for item: FeedItemDTO) -> some View {
        VideoCardOverflowMenu(
            bvid: item.bvid,
            author: item.author,
            ownerMID: item.ownerMID,
            dislikeReasons: item.dislikeReasons,
            feedbackReasons: item.feedbackReasons,
            onCopyBVID: { handleCardAction(item: item, action: .copyBVID) },
            onWatchLater: { handleCardAction(item: item, action: .watchLater) },
            onVisitOwner: { handleCardAction(item: item, action: .visitOwner) },
            onPlainDislike: { handleCardAction(item: item, action: .plainDislike) },
            onUndoDislike: { handleCardAction(item: item, action: .undoDislike) },
            onDislikeReason: { handleCardAction(item: item, action: .dislikeReason($0)) },
            onFeedbackReason: { handleCardAction(item: item, action: .feedbackReason($0)) },
            onBlockOwner: { handleCardAction(item: item, action: .blockOwner) }
        )
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

    /// Pre-warm cover images ahead of the user's scroll position so
    /// cells already have their covers cached by the time they appear.
    private func prefetchCovers(aroundIndex index: Int, cardWidth: CGFloat) {
        let lookahead = 12
        guard vm.items.indices.contains(index) else { return }
        let start = min(index + 1, vm.items.count)
        let end = min(start + lookahead, vm.items.count)
        guard start < end else { return }
        let covers = vm.items[start..<end].map(\.cover)
        let size = CGSize(width: cardWidth, height: (cardWidth / VideoCoverView.aspectRatio).rounded())
        CoverImagePrefetcher.shared.prefetch(covers,
                                             targetPointSize: size,
                                             quality: settings.resolvedImageQuality())
    }
}

private struct HomeLiveFeedPage: View {
    @Binding var section: HomeFeedSection
    @Binding var collapseProgress: CGFloat
    @ObservedObject var vm: LiveHomeViewModel
    let scrollToTopSignal: Int

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
            let gridItems = Array(
                repeating: GridItem(.fixed(metrics.cardWidth), spacing: metrics.spacing, alignment: .top),
                count: max(1, cols)
            )
            ZStack {
                FeedScrollPage(
                    title: "主页",
                    coordinateSpace: "home-live",
                    scrollToTopSignal: scrollToTopSignal,
                    headerCollapseProgress: $collapseProgress,
                    showsRefresh: true,
                    onRefresh: {
                        await vm.refresh()
                    }
                ) {
                    if vm.items.isEmpty && vm.isLoading {
                        ProgressView()
                            .tint(IbiliTheme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                    } else if let err = vm.errorText, vm.items.isEmpty {
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
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.top, 28)
                    } else if vm.items.isEmpty {
                        emptyState(title: "暂无直播", symbol: "dot.radiowaves.left.and.right")
                            .padding(.top, 28)
                    } else {
                        PagedCollectionSurface(
                            items: vm.items,
                            layout: .grid(columns: gridItems, spacing: metrics.rowSpacing, footerColumnSpan: max(1, cols)),
                            isLoading: vm.isLoading,
                            isEnd: vm.isEnd,
                            prefetchThreshold: 4,
                            onReachEnd: {
                                Task { await vm.loadMore() }
                            }
                        ) {
                            EmptyView()
                        } itemContent: { _, item in
                                LiveCardView(
                                    item: item,
                                    cardWidth: metrics.cardWidth,
                                    imageQuality: settings.resolvedImageQuality()
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .onTapGesture {
                                    openLiveItem(item)
                                }
                        }
                        .padding(.horizontal, metrics.horizontalPadding)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                }
            }
            .transaction { $0.animation = nil }
        }
        .task { await vm.loadInitial() }
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
