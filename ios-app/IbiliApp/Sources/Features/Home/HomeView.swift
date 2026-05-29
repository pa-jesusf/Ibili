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

    init() {
        _recommendVM = StateObject(wrappedValue: HomeViewModel(section: .recommend))
        _hotVM = StateObject(wrappedValue: HomeViewModel(section: .hot))
    }

    var body: some View {
        Group {
            switch section {
            case .recommend, .hot:
                HomeFeedPage(
                    section: $section,
                    collapseProgress: $headerCollapseProgress,
                    switcherProgress: $switcherCollapseProgress,
                    vm: activeViewModel,
                    prefetch: prefetch
                )
            case .live:
                HomeLiveFeedPage(
                    section: $section,
                    collapseProgress: $headerCollapseProgress,
                    switcherProgress: $switcherCollapseProgress,
                    vm: liveVM
                )
            }
        }
        .background(IbiliTheme.background.ignoresSafeArea())
        .overlay(alignment: .top) {
            FeedNavigationBackgroundOverlay(collapseProgress: headerCollapseProgress)
        }
        .overlay(alignment: .top) {
            FeedFloatingSegmentedControlOverlay(
                tabs: Array(HomeFeedSection.allCases),
                title: { $0.title },
                selection: $section,
                collapseProgress: switcherCollapseProgress,
                positionProgress: headerCollapseProgress
            )
        }
        .toolbar(.hidden, for: .navigationBar)
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

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation
    @Environment(\.prefersSplitRootSelection) private var prefersSplitRootSelection
    @Environment(\.splitFeedColumnLimit) private var splitFeedColumnLimit
    @State private var userSpaceMID: Int64?
    @State private var toast: String?
    @State private var toastWork: DispatchWorkItem?

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
        .refreshable {
            await vm.refresh(recommendSource: recommendSource)
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
            let hPad: CGFloat = 12
            let spacing: CGFloat = 12
            let totalSpacing = spacing * CGFloat(cols - 1) + hPad * 2
            let cardW = max(1, floor((geo.size.width - totalSpacing) / CGFloat(cols)))
            let rowSpacing: CGFloat = 14
            let gridItems = Array(
                repeating: GridItem(.fixed(cardW), spacing: spacing, alignment: .top),
                count: cols
            )

            ScrollView {
                if #unavailable(iOS 18.0) {
                    ScrollHeaderOffsetReader(coordinateSpace: "home-feed-scroll")
                }

                FeedTitleHeader(
                    title: "主页",
                    collapseProgress: collapseProgress,
                    showsBackground: false
                )

                if vm.items.isEmpty && vm.isLoading {
                    ProgressView()
                        .tint(IbiliTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                } else if let err = vm.errorText, vm.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                        Text(err).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("重试") { Task { await vm.refresh(recommendSource: settings.homeRecommendSource) } }
                            .buttonStyle(.borderedProminent).tint(IbiliTheme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                } else {
                    LazyVGrid(columns: gridItems, spacing: rowSpacing) {
                        ForEach(vm.items) { item in
                            ZStack(alignment: .bottomTrailing) {
                                Button {
                                    if prefersSplitRootSelection {
                                        router.select(item)
                                    } else {
                                        router.open(item)
                                    }
                                } label: {
                                    VideoCardView(
                                        item: item,
                                        cardWidth: cardW,
                                        imageQuality: settings.resolvedImageQuality(),
                                        showsDurationAtTopTrailing: usesTopTrailingDuration,
                                        meta: settings.homeCardMeta
                                    )
                                }
                                .buttonStyle(TouchDownReportingButtonStyle {
                                    prefetch.touchDown(item)
                                })

                                VideoCardOverflowMenu(
                                    bvid: item.bvid,
                                    author: item.author,
                                    ownerMID: item.ownerMID,
                                    dislikeReasons: item.dislikeReasons,
                                    feedbackReasons: item.feedbackReasons,
                                    onCopyBVID: { copyBVID(item.bvid) },
                                    onWatchLater: { addWatchLater(aid: item.aid) },
                                    onVisitOwner: { openOwner(mid: item.ownerMID) },
                                    onPlainDislike: { markNotInterested(item: item) },
                                    onUndoDislike: { undoNotInterested(item: item) },
                                    onDislikeReason: { reason in submitFeedDislike(item: item, reason: reason, isFeedback: false) },
                                    onFeedbackReason: { reason in submitFeedDislike(item: item, reason: reason, isFeedback: true) },
                                    onBlockOwner: { blockOwner(mid: item.ownerMID, author: item.author) }
                                )
                                .padding(.trailing, 4)
                                .padding(.bottom, 4)
                            }
                            .frame(width: cardW, alignment: .topLeading)
                            .onAppear {
                                prefetch.cardAppeared(item, allItems: vm.items)
                                prefetchCovers(around: item, cardWidth: cardW)
                                if !vm.isEnd, item.aid == vm.items.last?.aid {
                                    Task { await vm.loadMore(recommendSource: settings.homeRecommendSource) }
                                }
                            }
                            .onDisappear { prefetch.cardDisappeared(item) }
                        }
                    }
                    .padding(.horizontal, hPad)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                    if vm.isLoading && !vm.items.isEmpty {
                        ProgressView().padding()
                    } else if vm.isEnd, !vm.items.isEmpty {
                        Text("已经到底了")
                            .font(.caption)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 18)
                    }
                }
            }
            .coordinateSpace(name: "home-feed-scroll")
            .modifier(ScrollOffsetCollapseDriver(progress: $collapseProgress, switcherProgress: $switcherProgress))
            .modifier(ProMotionScrollHint())
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

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.prefersSplitRootSelection) private var prefersSplitRootSelection
    @Environment(\.splitFeedColumnLimit) private var splitFeedColumnLimit

    var body: some View {
        GeometryReader { geo in
            let resolvedCols = settings.effectiveColumns(horizontal: hSizeClass, width: geo.size.width)
            let cols = splitFeedColumnLimit.map { min(resolvedCols, $0) } ?? resolvedCols
            let hPad: CGFloat = 12
            let spacing: CGFloat = 12
            let totalSpacing = spacing * CGFloat(cols - 1) + hPad * 2
            let cardW = max(1, floor((geo.size.width - totalSpacing) / CGFloat(cols)))
            let rowSpacing: CGFloat = 14
            let gridItems = Array(
                repeating: GridItem(.fixed(cardW), spacing: spacing, alignment: .top),
                count: cols
            )

            ScrollView {
                if #unavailable(iOS 18.0) {
                    ScrollHeaderOffsetReader(coordinateSpace: "home-feed-scroll")
                }

                FeedTitleHeader(
                    title: "主页",
                    collapseProgress: collapseProgress,
                    showsBackground: false
                )

                if vm.items.isEmpty && vm.isLoading {
                    ProgressView()
                        .tint(IbiliTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                } else if let err = vm.errorText, vm.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                        Text(err).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("重试") { Task { await vm.refresh() } }
                            .buttonStyle(.borderedProminent).tint(IbiliTheme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                } else {
                    LazyVGrid(columns: gridItems, spacing: rowSpacing) {
                        ForEach(vm.items) { item in
                            Button {
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
                            } label: {
                                LiveCardView(
                                    item: item,
                                    cardWidth: cardW,
                                    imageQuality: settings.resolvedImageQuality()
                                )
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                prefetchCovers(around: item, cardWidth: cardW)
                                if !vm.isEnd, item.roomID == vm.items.last?.roomID {
                                    Task { await vm.loadMore() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, hPad)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                    if vm.isLoading && !vm.items.isEmpty {
                        ProgressView().padding()
                    } else if vm.isEnd, !vm.items.isEmpty {
                        Text("已经到底了")
                            .font(.caption)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 18)
                    }
                }
            }
            .coordinateSpace(name: "home-feed-scroll")
            .modifier(ScrollOffsetCollapseDriver(progress: $collapseProgress, switcherProgress: $switcherProgress))
            .modifier(ProMotionScrollHint())
            .transaction { $0.animation = nil }
        }
        .task { await vm.loadInitial() }
        .refreshable { await vm.refresh() }
    }

    private func prefetchCovers(around item: LiveFeedItemDTO, cardWidth: CGFloat) {
        let lookahead = 18
        guard let idx = vm.items.firstIndex(where: { $0.roomID == item.roomID }) else { return }
        let start = min(idx + 1, vm.items.count)
        let end = min(start + lookahead, vm.items.count)
        guard start < end else { return }
        let covers = vm.items[start..<end].map { $0.systemCover.isEmpty ? $0.cover : $0.systemCover }
        let size = CGSize(width: cardWidth, height: (cardWidth / VideoCoverView.aspectRatio).rounded())
        CoverImagePrefetcher.shared.prefetch(covers,
                                             targetPointSize: size,
                                             quality: settings.resolvedImageQuality())
    }
}
