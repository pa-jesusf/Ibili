import SwiftUI
import UIKit

/// Per-uploader space page (用户空间). Layout mirrors PiliPlus / the
/// stock Bilibili web profile:
///
///   ┌─────────────────────────────┐
///   │     [avatar]                │
///   │     RanWang2778             │
///   │     up 主签名 (sign)         │
///   │     [+ 关注]                │
///   │     66      596    Lv4      │
///   │    关注    粉丝   等级       │
///   ├─────────────────────────────┤
///   │   [ 动态 ]   [ 投稿 ]        │ ← segmented control
///   ├─────────────────────────────┤
///   │   …content list…            │
///   ├─────────────────────────────┤
///   │  🔍 搜索该用户的内容          │ ← bottom-anchored search bar
///   └─────────────────────────────┘
///
/// The right-side toolbar sort button only applies to the 投稿 tab —
/// it switches the upstream `order=` between pubdate / click / stow.
/// Search drives the `keyword` arg on the same endpoint, so typing a
/// term filters the archive list to matching videos. Searching inside
/// the 动态 tab is a no-op for now (Bilibili does have
/// `/x/polymer/web-dynamic/v1/feed/space/search`, deferred to a later
/// pass).
struct UserSpaceView: View {
    let mid: Int64

    @StateObject private var vm = UserSpaceViewModel()
    @State private var tab: Tab = .archives
    @State private var keyword: String = ""
    @FocusState private var searchFocused: Bool

    @EnvironmentObject private var router: DeepLinkRouter

    enum Tab: Hashable { case dynamics, archives }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        contentList
                    } header: {
                        VStack(spacing: 12) {
                            header
                            tabBar
                        }
                        .padding(.bottom, 8)
                        .background(IbiliTheme.background)
                    }
                }
                .padding(.bottom, 80)
            }
            searchBar
        }
        .background(IbiliTheme.background.ignoresSafeArea())
        .navigationTitle("用户空间")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if tab == .archives {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: Binding(
                            get: { vm.archiveOrder },
                            set: { newVal in
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
        .task(id: mid) {
            await vm.loadHeader(mid: mid)
            await vm.refreshArchives(mid: mid, keyword: "")
            await vm.refreshDynamics(mid: mid)
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
                .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 0.5))
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
            followButton
                .padding(.top, 4)
            statsRow
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private var followButton: some View {
        // Optimistic toggle: we don't yet pre-fetch the relation
        // status (would need `/x/relation/relations`), so the button
        // starts in a neutral "+ 关注" state and flips to "已关注"
        // after a successful tap.
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

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("动态", isOn: tab == .dynamics) { tab = .dynamics }
            tabButton("投稿", isOn: tab == .archives) { tab = .archives }
        }
        .padding(4)
        .background(Capsule().fill(Color.black.opacity(0.18)))
        .padding(.horizontal, 16)
    }

    private func tabButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? .white : IbiliTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isOn ? IbiliTheme.accent : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Content list

    @ViewBuilder
    private var contentList: some View {
        switch tab {
        case .archives:
            archivesList
        case .dynamics:
            dynamicsList
        }
    }

    private var archivesList: some View {
        LazyVStack(spacing: 4) {
            ForEach(Array(vm.archives.enumerated()), id: \.element.id) { idx, item in
                Button {
                    router.pending = FeedItemDTO(
                        aid: item.aid, bvid: item.bvid, cid: 0,
                        title: item.title, cover: item.cover,
                        author: item.author, durationSec: 0,
                        play: item.play, danmaku: item.danmaku
                    )
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
                    .overlay(alignment: .bottomLeading) {
                        if item.created > 0 {
                            Text(BiliFormat.relativeDate(item.created))
                                .font(.caption2)
                                .foregroundStyle(IbiliTheme.textSecondary)
                                .padding(.leading, 144)
                                .padding(.bottom, 8)
                        }
                    }
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
                DynamicItemCard(item: item)
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
        .background(
            Capsule().fill(.regularMaterial)
                .overlay(Capsule().stroke(.white.opacity(0.06), lineWidth: 0.5))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - View model

@MainActor
final class UserSpaceViewModel: ObservableObject {
    @Published var card: UserCardDTO?
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

    func loadHeader(mid: Int64) async {
        let result: UserCardDTO? = await Task.detached {
            try? CoreClient.shared.userCard(mid: mid)
        }.value
        self.card = result
    }

    func toggleFollow(mid: Int64) async {
        followBusy = true
        defer { followBusy = false }
        // act: 1 = follow, 2 = unfollow (matches existing CoreClient).
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
        // `count` is total across pages; stop when we've consumed all
        // or the server returns an empty incremental page.
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
