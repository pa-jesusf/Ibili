import SwiftUI
import UIKit

struct HomeView: View {
    @State private var section: HomeFeedSection = .recommend
    @State private var headerCollapseProgress: CGFloat = 0
    @State private var switcherCollapseProgress: CGFloat = 0
    @StateObject private var recommendVM: HomeViewModel
    @StateObject private var hotVM: HomeViewModel
    @StateObject private var liveVM = LiveHomeViewModel()
    @StateObject private var prefetch = FeedPrefetchCoordinator()
    @EnvironmentObject private var tabReselect: TabReselectSignals

    init() {
        _recommendVM = StateObject(wrappedValue: HomeViewModel(section: .recommend))
        _hotVM = StateObject(wrappedValue: HomeViewModel(section: .hot))
    }

    var body: some View {
        PageChrome(
            title: "主页",
            tabs: Array(HomeFeedSection.allCases),
            tabTitle: { $0.title },
            selection: $section,
            headerCollapseProgress: $headerCollapseProgress,
            switcherCollapseProgress: $switcherCollapseProgress
        ) {
            switch section {
            case .recommend, .hot:
                HomeFeedPage(
                    section: $section,
                    collapseProgress: $headerCollapseProgress,
                    switcherProgress: $switcherCollapseProgress,
                    vm: activeViewModel,
                    prefetch: prefetch,
                    scrollToTopSignal: tabReselect.home
                )
            case .live:
                HomeLiveFeedPage(
                    section: $section,
                    collapseProgress: $headerCollapseProgress,
                    switcherProgress: $switcherCollapseProgress,
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
    @Binding var switcherProgress: CGFloat
    @ObservedObject var vm: HomeViewModel
    let prefetch: FeedPrefetchCoordinator
    let scrollToTopSignal: Int

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation
    @Environment(\.prefersSplitRootSelection) private var prefersSplitRootSelection
    @Environment(\.splitFeedColumnLimit) private var splitFeedColumnLimit
    @State private var userSpaceMID: Int64?
    @State private var toast: String?
    @State private var toastWork: DispatchWorkItem?
    @State private var lastScrollOffset: CGFloat = 0
    @State private var collapseState = FeedScrollCollapseState()

    var body: some View {
        let recommendSource = settings.homeRecommendSource
        feedGrid
        .background {
            if !isInPlayerHostNavigation {
                NavigationLink(
                    isActive: Binding(
                        get: { userSpaceMID != nil },
                        set: { if !$0 { userSpaceMID = nil } }
                    ),
                    destination: {
                        if let mid = userSpaceMID {
                            UserSpaceView(mid: mid)
                        }
                    },
                    label: { EmptyView() }
                )
                .opacity(0)
                .allowsHitTesting(false)
            }
        }
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

            ZStack {
                HomeFeedCollectionView(
                    items: vm.items.map(HomeFeedCardContent.video),
                    columns: cols,
                    imageQuality: settings.resolvedImageQuality(),
                    showsDurationAtTopTrailing: usesTopTrailingDuration,
                    meta: settings.homeCardMeta,
                    scrollToTopSignal: scrollToTopSignal,
                    isRefreshing: vm.isLoading && !vm.items.isEmpty,
                    onTap: { item in
                        guard case .video(let feedItem) = item else { return }
                        openFeedItem(feedItem)
                    },
                    onTouchDown: { item in
                        guard case .video(let feedItem) = item else { return }
                        prefetch.touchDown(feedItem)
                    },
                    onAction: { item, action in
                        handleCardAction(item: item, action: action)
                    },
                    onRefresh: {
                        Task { await vm.refresh(recommendSource: settings.homeRecommendSource) }
                    },
                    onReachEnd: {
                        Task { await vm.loadMore(recommendSource: settings.homeRecommendSource) }
                    },
                    onVisibleItemsChange: { visible in
                        prefetch.visibleItemsChanged(visible)
                    },
                    onScrollOffsetChange: handleScrollOffset
                )
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .modifier(ProMotionScrollHint())

                if vm.items.isEmpty && vm.isLoading {
                    ProgressView()
                        .tint(IbiliTheme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 28)
                } else if let err = vm.errorText, vm.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                        Text(err).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("重试") { Task { await vm.refresh(recommendSource: settings.homeRecommendSource) } }
                            .buttonStyle(.borderedProminent).tint(IbiliTheme.accent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                }
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

    private func openFeedItem(_ item: FeedItemDTO) {
        if prefersSplitRootSelection {
            router.select(item)
        } else {
            router.open(item)
        }
    }

    private func handleCardAction(item: FeedItemDTO, action: HomeFeedCardAction) {
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

    private func handleScrollOffset(_ rawOffset: CGFloat) {
        let next = collapseState.update(rawOffset: rawOffset)
        lastScrollOffset = next.offset
        collapseProgress = next.headerProgress
        switcherProgress = next.switcherProgress
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
            userSpaceMID = mid
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
    private func prefetchCovers(around item: FeedItemDTO, cardWidth: CGFloat) {
        let lookahead = 18
        guard let idx = vm.items.firstIndex(where: { $0.aid == item.aid }) else { return }
        let start = min(idx + 1, vm.items.count)
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
    @Binding var switcherProgress: CGFloat
    @ObservedObject var vm: LiveHomeViewModel
    let scrollToTopSignal: Int

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.prefersSplitRootSelection) private var prefersSplitRootSelection
    @Environment(\.splitFeedColumnLimit) private var splitFeedColumnLimit
    @State private var lastScrollOffset: CGFloat = 0
    @State private var collapseState = FeedScrollCollapseState()

    var body: some View {
        GeometryReader { geo in
            let resolvedCols = settings.effectiveColumns(horizontal: hSizeClass, width: geo.size.width)
            let cols = splitFeedColumnLimit.map { min(resolvedCols, $0) } ?? resolvedCols
            ZStack {
                HomeFeedCollectionView(
                    items: vm.items.map(HomeFeedCardContent.live),
                    columns: cols,
                    imageQuality: settings.resolvedImageQuality(),
                    showsDurationAtTopTrailing: false,
                    meta: settings.homeCardMeta,
                    scrollToTopSignal: scrollToTopSignal,
                    isRefreshing: vm.isLoading && !vm.items.isEmpty,
                    onTap: { item in
                        guard case .live(let liveItem) = item else { return }
                        openLiveItem(liveItem)
                    },
                    onTouchDown: { _ in },
                    onAction: { _, _ in },
                    onRefresh: {
                        Task { await vm.refresh() }
                    },
                    onReachEnd: {
                        Task { await vm.loadMore() }
                    },
                    onVisibleItemsChange: { _ in },
                    onScrollOffsetChange: handleLiveScrollOffset
                )
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .modifier(ProMotionScrollHint())

                if vm.items.isEmpty && vm.isLoading {
                    ProgressView()
                        .tint(IbiliTheme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                } else if vm.items.isEmpty {
                    emptyState(title: "暂无直播", symbol: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .transaction { $0.animation = nil }
        }
        .task { await vm.loadInitial() }
    }

    private func openLiveItem(_ item: LiveFeedItemDTO) {
        let cover = item.systemCover.isEmpty ? item.cover : item.systemCover
        if prefersSplitRootSelection {
            router.selectLive(
                roomID: item.roomID,
                title: item.title,
                cover: cover,
                anchorName: item.uname
            )
        } else {
            router.openLive(
                roomID: item.roomID,
                title: item.title,
                cover: cover,
                anchorName: item.uname
            )
        }
    }

    private func handleLiveScrollOffset(_ rawOffset: CGFloat) {
        let next = collapseState.update(rawOffset: rawOffset)
        lastScrollOffset = next.offset
        collapseProgress = next.headerProgress
        switcherProgress = next.switcherProgress
    }
}
