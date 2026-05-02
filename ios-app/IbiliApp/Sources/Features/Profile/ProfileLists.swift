import SwiftUI

// MARK: - Shared video-tap helper
//
// Each list routes a `FeedItemDTO` through the shared player router so
// player-layer behaviour stays consistent across every surface.
@MainActor
private func pushVideo(
    _ router: DeepLinkRouter,
    aid: Int64, bvid: String, cid: Int64,
    title: String, cover: String, author: String,
    durationSec: Int64, play: Int64 = 0, danmaku: Int64 = 0
) {
    router.open(FeedItemDTO(
        aid: aid, bvid: bvid, cid: cid,
        title: title, cover: cover, author: author,
        durationSec: durationSec, play: play, danmaku: danmaku
    ))
}

// MARK: - History

/// 历史记录: cursor-paged list backed by `/x/web-interface/history/cursor`.
/// Each row uses `CompactVideoRow` with a resume-progress bar overlaid
/// on the cover, mirroring Apple TV's "Up Next" pattern.
struct HistoryListView: View {
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var vm = HistoryListViewModel()

    var body: some View {
        Group {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty {
                emptyState(title: "暂无观看记录", symbol: "clock")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                pushVideo(router,
                                          aid: item.aid, bvid: item.bvid, cid: item.cid,
                                          title: item.title, cover: item.cover,
                                          author: item.author, durationSec: item.durationSec)
                            } label: {
                                CompactVideoRow(
                                    cover: item.cover,
                                    title: item.title,
                                    author: item.author,
                                    durationSec: item.durationSec,
                                    play: 0, danmaku: 0,
                                    progress: progressFraction(item),
                                    durationOverride: progressLabel(item)
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .onAppear {
                                if !vm.isEnd, index >= max(0, vm.items.count - 3) {
                                    Task { await vm.loadMore() }
                                }
                            }
                            if index < vm.items.count - 1 {
                                Divider().padding(.leading, 144)
                            }
                        }
                        if vm.isLoading {
                            ProgressView().padding()
                        } else if vm.isEnd {
                            Text("已经到底了").font(.caption).foregroundStyle(.secondary).padding()
                        }
                    }
                }
            }
        }
        .background(IbiliTheme.background)
        .navigationTitle("历史记录")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadInitial() }
    }

    private func progressFraction(_ item: HistoryItemDTO) -> Double {
        guard item.durationSec > 0, item.progressSec > 0 else { return 0 }
        if item.progressSec < 0 { return 1 } // -1 = 已看完
        return min(1, Double(item.progressSec) / Double(item.durationSec))
    }

    private func progressLabel(_ item: HistoryItemDTO) -> String? {
        if item.progressSec < 0 { return "已看完" }
        if item.progressSec > 0 {
            return "看到 \(BiliFormat.duration(item.progressSec))"
        }
        return nil
    }
}

@MainActor
final class HistoryListViewModel: ObservableObject {
    @Published var items: [HistoryItemDTO] = []
    @Published var isLoading = false
    @Published var isEnd = false
    private var nextMax: Int64 = 0
    private var nextViewAt: Int64 = 0

    func loadInitial() async {
        guard items.isEmpty else { return }
        await fetch(reset: true)
    }

    func loadMore() async {
        guard !isLoading, !isEnd else { return }
        await fetch(reset: false)
    }

    private func fetch(reset: Bool) async {
        if reset { nextMax = 0; nextViewAt = 0; isEnd = false }
        isLoading = true
        let max = nextMax, viewAt = nextViewAt
        let page: HistoryPageDTO? = await Task.detached {
            try? CoreClient.shared.userHistory(max: max, viewAt: viewAt)
        }.value
        isLoading = false
        guard let page else { isEnd = true; return }
        if reset { items = page.items } else { items.append(contentsOf: page.items) }
        nextMax = page.nextMax
        nextViewAt = page.nextViewAt
        // Bilibili signals "no more" by returning nextMax == 0 *and*
        // an empty / short page. Either condition alone happens
        // mid-stream on busy accounts.
        if (page.nextMax == 0 && page.nextViewAt == 0) || page.items.isEmpty {
            isEnd = true
        }
    }
}

// MARK: - Watch later

struct WatchLaterListView: View {
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var vm = WatchLaterListViewModel()

    var body: some View {
        Group {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty {
                emptyState(title: "稍后再看是空的", symbol: "list.bullet.rectangle.portrait",
                           message: "在视频详情页点击「稍后再看」后即可在这里看到")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                pushVideo(router,
                                          aid: item.aid, bvid: item.bvid, cid: item.cid,
                                          title: item.title, cover: item.cover,
                                          author: item.author, durationSec: item.durationSec)
                            } label: {
                                CompactVideoRow(
                                    cover: item.cover,
                                    title: item.title,
                                    author: item.author,
                                    durationSec: item.durationSec,
                                    play: 0, danmaku: 0,
                                    progress: fraction(item)
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            if index < vm.items.count - 1 {
                                Divider().padding(.leading, 144)
                            }
                        }
                    }
                }
            }
        }
        .background(IbiliTheme.background)
        .navigationTitle("稍后再看")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .refreshable { await vm.load(force: true) }
    }

    private func fraction(_ item: WatchLaterItemDTO) -> Double {
        guard item.durationSec > 0, item.progressSec > 0 else { return 0 }
        if item.progressSec < 0 { return 1 }
        return min(1, Double(item.progressSec) / Double(item.durationSec))
    }
}

@MainActor
final class WatchLaterListViewModel: ObservableObject {
    @Published var items: [WatchLaterItemDTO] = []
    @Published var isLoading = false
    private var loaded = false

    func load(force: Bool = false) async {
        if loaded && !force { return }
        isLoading = true
        let result: [WatchLaterItemDTO] = await Task.detached {
            (try? CoreClient.shared.userWatchLaterList()) ?? []
        }.value
        items = result
        isLoading = false
        loaded = true
    }
}

// MARK: - Favourites: folder list → resource list

struct FavoritesFolderListView: View {
    let mid: Int64
    @State private var folders: [FavFolderInfoDTO] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            if folders.isEmpty && isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if folders.isEmpty {
                emptyState(title: "暂无收藏夹", symbol: "star")
            } else {
                List {
                    ForEach(folders) { folder in
                        NavigationLink {
                            FavoriteResourcesView(folderId: folder.id, title: folder.title)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(IbiliTheme.accent)
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.title).font(.body)
                                    Text("\(folder.mediaCount) 个内容")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(IbiliTheme.background)
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard folders.isEmpty else { return }
            isLoading = true
            let result: [FavFolderInfoDTO] = await Task.detached { [mid] in
                (try? CoreClient.shared.favFolders(rid: 0, upMid: mid)) ?? []
            }.value
            folders = result
            isLoading = false
        }
    }
}

struct FavoriteResourcesView: View {
    let folderId: Int64
    let title: String
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var vm = FavoriteResourcesViewModel()

    var body: some View {
        Group {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty {
                emptyState(title: "收藏夹是空的", symbol: "star")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                pushVideo(router,
                                          aid: item.aid, bvid: item.bvid, cid: item.cid,
                                          title: item.title, cover: item.cover,
                                          author: item.author, durationSec: item.durationSec,
                                          play: item.play, danmaku: item.danmaku)
                            } label: {
                                CompactVideoRow(
                                    cover: item.cover,
                                    title: item.title,
                                    author: item.author,
                                    durationSec: item.durationSec,
                                    play: item.play,
                                    danmaku: item.danmaku
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .onAppear {
                                if !vm.isEnd, index >= max(0, vm.items.count - 3) {
                                    Task { await vm.loadMore(folderId: folderId) }
                                }
                            }
                            if index < vm.items.count - 1 {
                                Divider().padding(.leading, 144)
                            }
                        }
                        if vm.isLoading { ProgressView().padding() }
                    }
                }
            }
        }
        .background(IbiliTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadInitial(folderId: folderId) }
    }
}

@MainActor
final class FavoriteResourcesViewModel: ObservableObject {
    @Published var items: [FavResourceItemDTO] = []
    @Published var isLoading = false
    @Published var isEnd = false
    private var page: Int64 = 1

    func loadInitial(folderId: Int64) async {
        guard items.isEmpty else { return }
        page = 1
        isEnd = false
        await fetch(folderId: folderId)
    }

    func loadMore(folderId: Int64) async {
        guard !isLoading, !isEnd else { return }
        await fetch(folderId: folderId)
    }

    private func fetch(folderId: Int64) async {
        isLoading = true
        let p = page
        let result: FavResourcePageDTO? = await Task.detached {
            try? CoreClient.shared.userFavResources(mediaId: folderId, page: p)
        }.value
        isLoading = false
        guard let result else { isEnd = true; return }
        items.append(contentsOf: result.items)
        if result.hasMore { page += 1 } else { isEnd = true }
    }
}

// MARK: - Bangumi (追番)

struct BangumiFollowListView: View {
    let mid: Int64
    @StateObject private var vm = BangumiFollowListViewModel()

    var body: some View {
        Group {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty {
                emptyState(title: "暂无追番", symbol: "tv")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(vm.items) { item in
                            BangumiRow(item: item)
                        }
                        if vm.isLoading { ProgressView().padding() }
                    }
                    .padding(12)
                }
            }
        }
        .background(IbiliTheme.background)
        .navigationTitle("我的追番")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadInitial(mid: mid) }
    }
}

private struct BangumiRow: View {
    let item: BangumiFollowItemDTO

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: item.cover,
                        contentMode: .fill,
                        targetPointSize: CGSize(width: 180, height: 240),
                        quality: 75)
                .frame(width: 90, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                if !item.progress.isEmpty {
                    Text(item.progress)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.accent)
                }
                if !item.evaluate.isEmpty {
                    Text(item.evaluate)
                        .font(.caption2)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(IbiliTheme.surface)
        )
    }
}

@MainActor
final class BangumiFollowListViewModel: ObservableObject {
    @Published var items: [BangumiFollowItemDTO] = []
    @Published var isLoading = false
    @Published var isEnd = false
    private var page: Int64 = 1

    func loadInitial(mid: Int64) async {
        guard items.isEmpty else { return }
        page = 1
        await fetch(mid: mid)
    }

    private func fetch(mid: Int64) async {
        isLoading = true
        let p = page
        let result: BangumiFollowPageDTO? = await Task.detached {
            try? CoreClient.shared.userBangumiFollow(vmid: mid, kind: 1, status: 0, page: p)
        }.value
        isLoading = false
        guard let result else { isEnd = true; return }
        items.append(contentsOf: result.items)
        if result.hasMore { page += 1 } else { isEnd = true }
    }
}

// MARK: - Relation (关注 / 粉丝)

struct RelationListView: View {
    enum Scope { case followings, followers }
    let vmid: Int64
    let scope: Scope
    let title: String
    @StateObject private var vm = RelationListViewModel()

    var body: some View {
        Group {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty {
                emptyState(title: scope == .followings ? "暂未关注任何人" : "暂无粉丝",
                           symbol: "person.2",
                           message: "若对方设置了隐私保护，列表也会显示为空")
            } else {
                List {
                    ForEach(vm.items) { user in
                        NavigationLink {
                            UserSpaceView(mid: user.mid)
                        } label: {
                            RelationRow(user: user)
                        }
                        .listRowBackground(IbiliTheme.surface)
                    }
                    if !vm.isEnd {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .listRowBackground(Color.clear)
                            .onAppear { Task { await vm.loadMore(vmid: vmid, scope: scope) } }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(IbiliTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadInitial(vmid: vmid, scope: scope) }
    }
}

private struct RelationRow: View {
    let user: RelationUserDTO

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: user.face,
                        contentMode: .fill,
                        targetPointSize: CGSize(width: 80, height: 80),
                        quality: 75)
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name).font(.callout.weight(.medium))
                if !user.sign.isEmpty {
                    Text(user.sign)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
final class RelationListViewModel: ObservableObject {
    @Published var items: [RelationUserDTO] = []
    @Published var isLoading = false
    @Published var isEnd = false
    private var page: Int64 = 1

    func loadInitial(vmid: Int64, scope: RelationListView.Scope) async {
        guard items.isEmpty else { return }
        page = 1
        await fetch(vmid: vmid, scope: scope)
    }

    func loadMore(vmid: Int64, scope: RelationListView.Scope) async {
        guard !isLoading, !isEnd else { return }
        await fetch(vmid: vmid, scope: scope)
    }

    private func fetch(vmid: Int64, scope: RelationListView.Scope) async {
        isLoading = true
        let p = page
        let result: RelationPageDTO? = await Task.detached {
            switch scope {
            case .followings: return try? CoreClient.shared.userFollowings(vmid: vmid, page: p)
            case .followers: return try? CoreClient.shared.userFollowers(vmid: vmid, page: p)
            }
        }.value
        isLoading = false
        guard let result else { isEnd = true; return }
        items.append(contentsOf: result.items)
        if result.items.isEmpty || Int64(items.count) >= result.total {
            isEnd = true
        } else {
            page += 1
        }
    }
}
