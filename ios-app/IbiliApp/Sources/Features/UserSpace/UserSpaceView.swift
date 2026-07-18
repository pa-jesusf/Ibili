import SwiftUI
import UIKit

/// Per-uploader space page (用户空间).
///
/// Layout (top → bottom):
///
///   • Header (avatar / name / sign / follow button / 关注·粉丝·投稿)
///   • 动态 / 投稿 segmented capsule (iOS 26 liquid glass)
///   • [Search field — only on 投稿 tab, iOS 26 liquid glass]
///   • Content list (scrolls under the header — header is part of
///     the scroll content rather than a pinned section, matching the
///     stock iOS profile pages so users can read further down without
///     a permanent header taking up vertical real estate).
///
/// Top-right toolbar carries the sort menu (only when 投稿 is active).
/// We hide the bottom tab bar via `.toolbar(.hidden, for: .tabBar)`
/// so the floating Liquid-Glass tab bar of `MainTabView` doesn't
/// peek through.
///
/// Dynamic details use the root content navigator when this page lives in a
/// tab stack, and the media-session navigator when it lives inside the player
/// host. Video/live entries always start or extend the media session.
private enum UserSpaceCollectionItem: Identifiable, Hashable {
    enum ID: Hashable {
        case archive(Int64)
        case dynamic(String)
    }

    case archive(SpaceArcItemDTO)
    case dynamic(DynamicItemDTO)

    var id: ID {
        switch self {
        case .archive(let item): return .archive(item.id)
        case .dynamic(let item): return .dynamic(item.idStr)
        }
    }
}

private struct UserSpaceHeaderVersion: Hashable {
    let mid: Int64
    let card: UserCardDTO?
    let live: UserLiveRoomDTO?
    let isFollowed: Bool
    let followBusy: Bool
}

struct UserSpaceView: View {
    let mid: Int64

    @StateObject private var vm = UserSpaceViewModel()
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation
    @Environment(\.prefersSplitRootSelection) private var prefersSplitRootSelection
    @Environment(\.rootContentNavigation) private var rootNavigation
    @State private var tab: Tab = .archives
    @State private var keyword: String = ""

    enum Tab: Hashable, Identifiable, CaseIterable {
        case dynamics, archives
        var id: Self { self }
        var title: String {
            switch self {
            case .dynamics: return "动态"
            case .archives: return "投稿"
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            VirtualizedCollectionSurface(
                items: collectionItems,
                layout: collectionLayout(containerWidth: proxy.size.width),
                header: { AnyView(collectionHeader) },
                headerVersion: collectionHeaderVersion,
                footer: collectionFooter,
                prefetchThreshold: 3,
                onLoadMore: loadMore,
                onPrefetch: prefetch,
                splitTransitionIdentity: splitTransitionIdentity,
                splitTransitionTargets: splitTransitionTargets,
                contentVersion: tab
            ) { item, itemWidth in
                AnyView(collectionRow(item, itemWidth: itemWidth))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .modifier(ProMotionScrollHint())
        }
        .background(IbiliTheme.background.ignoresSafeArea())
        .navigationTitle("用户空间")
        .navigationBarTitleDisplayMode(.inline)
        // Hide the floating tab bar — UserSpaceView is full-page.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if tab == .archives {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: Binding(
                            get: { vm.archiveOrder },
                            set: { newVal in
                                guard newVal != vm.archiveOrder else { return }
                                vm.archiveOrder = newVal
                                Task { await vm.refreshArchives(mid: mid, keyword: keyword) }
                            }
                        )) {
                            Text("最新发布").tag("pubdate")
                            Text("最多播放").tag("click")
                            Text("最多收藏").tag("stow")
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: tab)
        // `task` runs once per view-identity. It does *not* re-run on
        // navigation-pop (which is what we want — bouncing back from
        // dynamic detail must not refetch and rebuild the page from
        // scratch). The `id: mid` parameter only re-runs the work if
        // the user-space identity itself changes.
        .task(id: mid) {
            await vm.bootstrap(mid: mid)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            RemoteImage(url: vm.card?.face ?? "",
                        contentMode: .fill,
                        targetPointSize: CGSize(width: 96, height: 96),
                        quality: 90)
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                .overlay(Circle().stroke(vm.userLive?.isLive == true ? IbiliTheme.accent : .white.opacity(0.1),
                                         lineWidth: vm.userLive?.isLive == true ? 3 : 0.5))
                .overlay(alignment: .bottom) {
                    if vm.userLive?.isLive == true {
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(IbiliTheme.accent))
                            .offset(y: 8)
                    }
                }
                .contentShape(Circle())
                .onTapGesture {
                    guard let live = vm.userLive, live.isLive else { return }
                    if isInPlayerHostNavigation {
                        router.openLive(roomID: live.roomID, title: live.title, cover: live.cover, anchorName: vm.card?.name ?? "")
                    } else if prefersSplitRootSelection {
                        router.selectLive(roomID: live.roomID, title: live.title, cover: live.cover, anchorName: vm.card?.name ?? "")
                    } else {
                        rootNavigation.openLive(roomID: live.roomID, title: live.title, cover: live.cover, anchorName: vm.card?.name ?? "")
                    }
                }
                .padding(.top, 4)
            Text(vm.card?.name ?? "—")
                .font(.title3.weight(.bold))
            if let sign = vm.card?.sign, !sign.isEmpty {
                Text(sign)
                    .font(.footnote)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .lineLimit(3)
            }
            followButton.padding(.top, 4)
            statsRow.padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private var followButton: some View {
        Button {
            Task { await vm.toggleFollow(mid: mid) }
        } label: {
            HStack(spacing: 4) {
                if vm.followBusy { ProgressView().tint(.white) }
                else if vm.isFollowed { Image(systemName: "checkmark") }
                else { Image(systemName: "plus") }
                Text(vm.isFollowed ? "已关注" : "关注")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .background(Capsule().fill(vm.isFollowed ? Color.gray : IbiliTheme.accent))
        }
        .disabled(vm.followBusy)
    }

    private var statsRow: some View {
        HStack(spacing: 36) {
            stat(label: "关注", value: vm.card.map { BiliFormat.compactCount($0.following) } ?? "—")
            stat(label: "粉丝", value: vm.card.map { BiliFormat.compactCount($0.follower) } ?? "—")
            stat(label: "投稿", value: vm.card.map { BiliFormat.compactCount($0.archiveCount) } ?? "—")
        }
        .padding(.bottom, 4)
    }

    private func stat(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.weight(.bold))
            Text(label).font(.caption2).foregroundStyle(IbiliTheme.textSecondary)
        }
    }

    // MARK: Tabs

    @ViewBuilder
    private var tabBar: some View {
        if #available(iOS 26.0, *) {
            NativeIsolatedPicker(
                items: Array(Tab.allCases),
                title: { $0.title },
                selection: $tab
            )
            .frame(height: 50)
        } else {
            IbiliSegmentedTabs(
                tabs: Tab.allCases,
                title: { $0.title },
                selection: $tab
            )
        }
    }

    // MARK: Content list

    private var collectionItems: [UserSpaceCollectionItem] {
        switch tab {
        case .archives:
            return vm.archives.map(UserSpaceCollectionItem.archive)
        case .dynamics:
            return vm.dynamics.map(UserSpaceCollectionItem.dynamic)
        }
    }

    private var collectionHeader: some View {
        VStack(spacing: 0) {
            header
            tabBar
                .padding(.top, 14)
                .padding(.horizontal, 16)
            UserSpaceArchiveSearchBar(
                tab: $tab,
                keyword: $keyword,
                onSubmit: { query in
                    Task { await vm.refreshArchives(mid: mid, keyword: query) }
                }
            )
            Color.clear.frame(height: 12)
        }
    }

    private var collectionHeaderVersion: AnyHashable {
        UserSpaceHeaderVersion(
            mid: mid,
            card: vm.card,
            live: vm.userLive,
            isFollowed: vm.isFollowed,
            followBusy: vm.followBusy
        )
    }

    private func collectionLayout(containerWidth: CGFloat) -> VirtualizedCollectionLayout {
        switch tab {
        case .archives:
            return .list(
                horizontalInset: 12,
                bottomInset: 32,
                spacing: 4,
                estimatedHeight: 112
            )
        case .dynamics:
            return .list(
                horizontalInset: DynamicLayout.outerPad,
                topInset: 8,
                bottomInset: 32,
                spacing: 14,
                estimatedHeight: 360,
                maximumItemWidth: DynamicLayout.cardWidth(containerWidth: containerWidth)
            )
        }
    }

    @ViewBuilder
    private func collectionRow(_ item: UserSpaceCollectionItem, itemWidth: CGFloat) -> some View {
        switch item {
        case .archive(let archive):
            Button {
                openArchive(archive)
            } label: {
                CompactVideoRow(
                    cover: archive.cover,
                    title: archive.title,
                    author: "",
                    durationSec: 0,
                    play: archive.play,
                    danmaku: archive.comment,
                    durationOverride: archive.durationLabel.isEmpty ? nil : archive.durationLabel
                )
            }
            .buttonStyle(.plain)

        case .dynamic(let dynamic):
            DynamicItemCard(
                item: dynamic,
                contentWidth: DynamicLayout.contentWidth(cardWidth: itemWidth),
                onOpenVideo: openVideo,
                onOpenDetail: openDynamic
            )
            .environmentObject(router)
            .environment(\.isInPlayerHostNavigation, isInPlayerHostNavigation)
            .environment(\.prefersSplitRootSelection, prefersSplitRootSelection)
            .environment(\.rootContentNavigation, rootNavigation)
        }
    }

    private var collectionFooter: (() -> AnyView)? {
        switch tab {
        case .archives:
            if vm.archivesLoading {
                return loadingFooter
            }
            if vm.archives.isEmpty {
                let title = keyword.isEmpty ? "暂无投稿" : "未匹配到视频"
                return emptyFooter(title: title, symbol: "rectangle.stack")
            }
            if vm.archivesEnd {
                return endFooter
            }

        case .dynamics:
            if vm.dynamicsLoading {
                return loadingFooter
            }
            if vm.dynamics.isEmpty {
                return emptyFooter(title: "暂无动态", symbol: "sparkles")
            }
            if vm.dynamicsEnd {
                return endFooter
            }
        }
        return nil
    }

    private var loadingFooter: () -> AnyView {
        {
            AnyView(
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            )
        }
    }

    private var endFooter: () -> AnyView {
        {
            AnyView(
                Text("已经到底了")
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            )
        }
    }

    private func emptyFooter(title: String, symbol: String) -> () -> AnyView {
        {
            AnyView(
                emptyState(title: title, symbol: symbol)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            )
        }
    }

    private func loadMore() {
        switch tab {
        case .archives:
            Task { await vm.loadMoreArchives(mid: mid, keyword: keyword) }
        case .dynamics:
            Task { await vm.loadMoreDynamics(mid: mid) }
        }
    }

    private func prefetch(_ items: [UserSpaceCollectionItem], itemWidth: CGFloat) {
        let archives = items.compactMap { item -> SpaceArcItemDTO? in
            if case .archive(let archive) = item { return archive }
            return nil
        }
        if !archives.isEmpty {
            CoverImagePrefetcher.shared.prefetch(
                archives.map(\.cover),
                targetPointSize: CGSize(width: 120, height: 68),
                quality: 76
            )
        }
        let dynamics = items.compactMap { item -> DynamicItemDTO? in
            if case .dynamic(let dynamic) = item { return dynamic }
            return nil
        }
        if !dynamics.isEmpty {
            DynamicMediaPrefetcher.prefetch(dynamics, cardWidth: itemWidth)
        }
    }

    private func openArchive(_ item: SpaceArcItemDTO) {
        openVideo(FeedItemDTO(
            aid: item.aid,
            bvid: item.bvid,
            cid: 0,
            title: item.title,
            cover: item.cover,
            author: item.author,
            durationSec: 0,
            play: item.play,
            danmaku: item.danmaku
        ))
    }

    private func openVideo(_ item: FeedItemDTO) {
        if isInPlayerHostNavigation {
            router.open(item)
        } else if prefersSplitRootSelection {
            router.select(item)
        } else {
            rootNavigation.openPlayer(item)
        }
    }

    private func openDynamic(_ item: DynamicItemDTO) {
        if isInPlayerHostNavigation {
            router.openDynamicDetail(item)
        } else if prefersSplitRootSelection {
            router.selectDynamicDetail(item)
        } else {
            rootNavigation.openDynamicDetail(item)
        }
    }

    private func splitTransitionIdentity(_ item: UserSpaceCollectionItem) -> FeedStableIdentity? {
        switch item {
        case .archive(let archive):
            let identity = FeedStableIdentity(aid: archive.aid, bvid: archive.bvid, cid: 0)
            return identity.isValid ? identity : nil
        case .dynamic(let dynamic):
            return DynamicSplitTransition.identity(dynamic)
        }
    }

    private func splitTransitionTargets(_ item: UserSpaceCollectionItem) -> Set<SplitFeedTransitionTarget> {
        switch item {
        case .archive:
            guard let identity = splitTransitionIdentity(item) else { return [] }
            return [.media(identity)]
        case .dynamic(let dynamic):
            return DynamicSplitTransition.targets(dynamic)
        }
    }
}

private struct UserSpaceArchiveSearchBar: View {
    @Binding var tab: UserSpaceView.Tab
    @Binding var keyword: String
    let onSubmit: (String) -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        if tab == .archives {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(IbiliTheme.textSecondary)
                TextField("搜索该用户的内容", text: $keyword)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .onSubmit { onSubmit(keyword) }
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        onSubmit("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(IbiliTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(GlassCapsuleModifier())
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

// MARK: - Material capsule

/// Shared material capsule used by the user-space search surface. Keep the
/// implementation boring and local: the global page chrome owns the larger
/// navigation glass treatment.
private struct GlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.5))
        } else {
            content
                .background(
                    Capsule().fill(.regularMaterial)
                        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.5))
                )
        }
    }
}

// MARK: - View model

@MainActor
final class UserSpaceViewModel: ObservableObject {
    @Published var card: UserCardDTO?
    @Published var userLive: UserLiveRoomDTO?
    @Published var isFollowed = false
    @Published var followBusy = false

    @Published var archives: [SpaceArcItemDTO] = []
    @Published var archivesLoading = false
    @Published var archivesEnd = false
    @Published var archiveOrder: String = "pubdate"
    private var archivePage: Int64 = 1
    private var archiveKeyword: String = ""

    @Published var dynamics: [DynamicItemDTO] = []
    @Published var dynamicsLoading = false
    @Published var dynamicsEnd = false
    private var dynamicOffset: String = ""

    /// Idempotent first-load. `task(id: mid)` would otherwise re-run
    /// our work on `.task` re-attach — we want at most one bootstrap
    /// per view identity.
    private var didBootstrap = false
    func bootstrap(mid: Int64) async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await loadHeader(mid: mid)
        await refreshArchives(mid: mid, keyword: "")
        await refreshDynamics(mid: mid)
    }

    func loadHeader(mid: Int64) async {
        async let cardResult: UserCardDTO? = Task.detached {
            try? CoreClient.shared.userCard(mid: mid)
        }.value
        async let liveResult: UserLiveRoomDTO? = Task.detached {
            try? CoreClient.shared.userLive(mid: mid)
        }.value
        let loadedCard = await cardResult
        self.card = loadedCard
        self.isFollowed = loadedCard?.isFollowed ?? false
        AppLog.debug("profile", "用户空间关注态加载完成", metadata: [
            "mid": String(mid),
            "hasCard": String(loadedCard != nil),
            "isFollowed": String(self.isFollowed),
        ])
        self.userLive = await liveResult
    }

    func toggleFollow(mid: Int64) async {
        followBusy = true
        defer { followBusy = false }
        let act: Int32 = isFollowed ? 2 : 1
        let ok: Bool = await Task.detached {
            do {
                try CoreClient.shared.relationModify(fid: mid, act: act)
                return true
            } catch {
                return false
            }
        }.value
        if ok { isFollowed.toggle() }
    }

    // MARK: Archives

    func refreshArchives(mid: Int64, keyword: String) async {
        archives = []
        archivePage = 1
        archivesEnd = false
        archiveKeyword = keyword
        await fetchArchives(mid: mid)
    }

    func loadMoreArchives(mid: Int64, keyword: String) async {
        if archivesEnd || archivesLoading { return }
        archivePage += 1
        await fetchArchives(mid: mid)
    }

    private func fetchArchives(mid: Int64) async {
        archivesLoading = true
        defer { archivesLoading = false }
        let p = archivePage, kw = archiveKeyword, order = archiveOrder
        let result: SpaceArcSearchPageDTO? = await Task.detached {
            try? CoreClient.shared.spaceArcSearch(mid: mid, keyword: kw, order: order, page: p)
        }.value
        guard let result else { archivesEnd = true; return }
        let existing = Set(archives.map { $0.aid })
        let fresh = result.items.filter { !existing.contains($0.aid) }
        archives.append(contentsOf: fresh)
        if fresh.isEmpty || Int64(archives.count) >= result.count {
            archivesEnd = true
        }
    }

    // MARK: Dynamics

    func refreshDynamics(mid: Int64) async {
        dynamics = []
        dynamicOffset = ""
        dynamicsEnd = false
        await fetchDynamics(mid: mid)
    }

    func loadMoreDynamics(mid: Int64) async {
        if dynamicsEnd || dynamicsLoading { return }
        await fetchDynamics(mid: mid)
    }

    private func fetchDynamics(mid: Int64) async {
        dynamicsLoading = true
        defer { dynamicsLoading = false }
        let off = dynamicOffset
        let result: DynamicFeedPageDTO? = await Task.detached {
            try? CoreClient.shared.spaceDynamicFeed(hostMid: mid, offset: off)
        }.value
        guard let result else { dynamicsEnd = true; return }
        let existing = Set(dynamics.map { $0.idStr })
        let fresh = result.items.filter { !existing.contains($0.idStr) }
        dynamics.append(contentsOf: fresh)
        dynamicOffset = result.offset
        if !result.hasMore || fresh.isEmpty { dynamicsEnd = true }
    }
}
