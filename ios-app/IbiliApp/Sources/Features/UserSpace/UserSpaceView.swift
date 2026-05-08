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
/// Dynamic-detail pushes stay on the enclosing navigation stack so the
/// user-space page itself keeps its local back stack, while video opens
/// go through the global player router to reuse the app-wide player
/// session lifecycle and PiP restore path.
struct UserSpaceView: View {
    let mid: Int64

    @StateObject private var vm = UserSpaceViewModel()
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation
    @State private var tab: Tab = .archives
    @State private var keyword: String = ""
    @FocusState private var searchFocused: Bool
    /// Hoisted nav state for "tap dynamic → push DynamicDetailView".
    /// Keeping the destination state at this view (rather than inside
    /// each lazy `DynamicItemCard`) is important: a
    /// `NavigationLink(isActive:)` whose binding lives on a cell's
    /// `@State` can have its `isActive` flipped back to `false` when
    /// the cell is recycled, which collapses the entire push above
    /// it — manifesting as "tap dynamic → back jumps to home".
    @State private var pushDynamic: DynamicItemDTO?

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
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                tabBar
                    .padding(.top, 14)
                    .padding(.horizontal, 16)
                if tab == .archives {
                    searchBar
                        .padding(.top, 12)
                        .padding(.horizontal, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Color.clear.frame(height: 12)
                content
            }
            .padding(.bottom, 32)
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
        // Hidden NavigationLink at the page level for dynamics. Because
        // it's declared on `UserSpaceView` itself (not inside a lazy
        // cell), its binding is stable across cell recycling and across
        // navigation pops.
        .background {
            if !isInPlayerHostNavigation {
                NavigationLink(
                    isActive: Binding(
                        get: { pushDynamic != nil },
                        set: { if !$0 { pushDynamic = nil } }
                    ),
                    destination: {
                        if let d = pushDynamic { DynamicDetailView(item: d) }
                    },
                    label: { EmptyView() }
                )
                .opacity(0)
                .allowsHitTesting(false)
            }
        }
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
                    router.openLive(
                        roomID: live.roomID,
                        title: live.title,
                        cover: live.cover,
                        anchorName: vm.card?.name ?? ""
                    )
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

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .archives: archivesList
        case .dynamics: dynamicsList
        }
    }

    private var archivesList: some View {
        LazyVStack(spacing: 4) {
            ForEach(Array(vm.archives.enumerated()), id: \.element.id) { idx, item in
                Button {
                    router.open(FeedItemDTO(
                        aid: item.aid, bvid: item.bvid, cid: 0,
                        title: item.title, cover: item.cover,
                        author: item.author, durationSec: 0,
                        play: item.play, danmaku: item.danmaku
                    ))
                } label: {
                    CompactVideoRow(
                        cover: item.cover,
                        title: item.title,
                        author: "",
                        durationSec: 0,
                        play: item.play,
                        danmaku: item.comment,
                        durationOverride: item.durationLabel.isEmpty ? nil : item.durationLabel
                    )
                    .padding(.horizontal, 12)
                }
                .buttonStyle(.plain)
                .onAppear {
                    if !vm.archivesEnd, idx >= vm.archives.count - 3 {
                        Task { await vm.loadMoreArchives(mid: mid, keyword: keyword) }
                    }
                }
            }
            if vm.archivesLoading && vm.archives.isEmpty {
                ProgressView().padding(.vertical, 40)
            } else if vm.archives.isEmpty && !vm.archivesLoading {
                emptyState(title: keyword.isEmpty ? "暂无投稿" : "未匹配到视频",
                           symbol: "rectangle.stack")
                    .padding(.vertical, 40)
            } else if vm.archivesEnd, !vm.archives.isEmpty {
                Text("已经到底了").font(.caption).foregroundStyle(IbiliTheme.textSecondary)
                    .padding(.vertical, 16)
            } else if vm.archivesLoading {
                ProgressView().padding(.vertical, 16)
            }
        }
    }

    private var dynamicsList: some View {
        LazyVStack(spacing: 14) {
            ForEach(Array(vm.dynamics.enumerated()), id: \.element.id) { idx, item in
                DynamicItemCard(
                    item: item,
                    onOpenVideo: { feedItem in router.open(feedItem) },
                    onOpenDetail: { dyn in
                        if isInPlayerHostNavigation {
                            router.openDynamicDetail(dyn)
                        } else {
                            pushDynamic = dyn
                        }
                    }
                )
                .onAppear {
                    if !vm.dynamicsEnd, idx >= vm.dynamics.count - 3 {
                        Task { await vm.loadMoreDynamics(mid: mid) }
                    }
                }
            }
            if vm.dynamicsLoading && vm.dynamics.isEmpty {
                ProgressView().padding(.vertical, 40)
            } else if vm.dynamics.isEmpty && !vm.dynamicsLoading {
                emptyState(title: "暂无动态", symbol: "sparkles")
                    .padding(.vertical, 40)
            } else if vm.dynamicsEnd, !vm.dynamics.isEmpty {
                Text("已经到底了").font(.caption).foregroundStyle(IbiliTheme.textSecondary)
                    .padding(.vertical, 16)
            } else if vm.dynamicsLoading {
                ProgressView().padding(.vertical, 16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(IbiliTheme.textSecondary)
            TextField("搜索该用户的内容", text: $keyword)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { Task { await vm.refreshArchives(mid: mid, keyword: keyword) } }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    Task { await vm.refreshArchives(mid: mid, keyword: "") }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .modifier(GlassCapsuleModifier())
    }
}

// MARK: - Liquid glass capsule

/// iOS 26 introduces the native `.glassEffect(_:in:)` modifier that
/// renders the new "Liquid Glass" material — same blur + chromatic
/// edge highlight that the system uses for the floating tab bar and
/// control-center tiles. On older systems we fall back to the
/// existing `.ultraThinMaterial` capsule, which is the closest
/// pre-iOS-26 approximation.
private struct GlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Layer a `.regularMaterial` blur *behind* the liquid
            // glass so the effective blur radius is higher and
            // foreground text stays legible — the bare glass effect
            // is intentionally subtle on iOS 26 and our pink-tinted
            // labels can read as low-contrast on bright wallpapers.
            content
                .background(Capsule().fill(.regularMaterial))
                .glassEffect(.regular, in: Capsule())
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
        self.card = await cardResult
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
