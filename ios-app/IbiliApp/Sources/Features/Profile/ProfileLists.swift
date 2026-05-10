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

private func normalizedProfileSearchQuery(_ query: String) -> String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func profileFields(_ fields: [String], match query: String) -> Bool {
    let trimmed = normalizedProfileSearchQuery(query)
    guard !trimmed.isEmpty else { return true }
    return fields.contains { $0.localizedCaseInsensitiveContains(trimmed) }
}

private struct ProfileInlineSearchBar: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(IbiliTheme.textSecondary)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

// MARK: - History

/// 历史记录: cursor-paged list backed by `/x/web-interface/history/cursor`.
/// Each row uses `CompactVideoRow` with a resume-progress bar overlaid
/// on the cover, mirroring Apple TV's "Up Next" pattern.
struct HistoryListView: View {
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var vm = HistoryListViewModel()
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?

    private var isSearching: Bool {
        !normalizedProfileSearchQuery(searchText).isEmpty
    }

    private var displayedItems: [HistoryItemDTO] {
        isSearching ? vm.searchItems : vm.items
    }

    private var displayedIsLoading: Bool {
        isSearching ? vm.searchIsLoading : vm.isLoading
    }

    private var displayedIsEnd: Bool {
        isSearching ? vm.searchIsEnd : vm.isEnd
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfileInlineSearchBar(placeholder: "搜索历史记录", text: $searchText)
            Group {
                if displayedItems.isEmpty && displayedIsLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayedItems.isEmpty {
                    emptyState(title: isSearching ? "没有搜索结果" : "暂无观看记录", symbol: "clock")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
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
                                    if !displayedIsEnd, index >= max(0, displayedItems.count - 3) {
                                        Task {
                                            if isSearching {
                                                await vm.loadMoreSearch(keyword: normalizedProfileSearchQuery(searchText))
                                            } else {
                                                await vm.loadMore()
                                            }
                                        }
                                    }
                                }
                                if index < displayedItems.count - 1 {
                                    Divider().padding(.leading, 144)
                                }
                            }
                            if displayedIsLoading {
                                ProgressView().padding()
                            } else if displayedIsEnd {
                                Text("已经到底了").font(.caption).foregroundStyle(.secondary).padding()
                            }
                        }
                    }
                }
            }
        }
        .background(IbiliTheme.background)
        .navigationTitle("历史记录")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadInitial() }
        .onChange(of: searchText) { newValue in
            scheduleSearch(newValue)
        }
        .onDisappear {
            searchTask?.cancel()
        }
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

    private func scheduleSearch(_ rawQuery: String) {
        searchTask?.cancel()
        let keyword = normalizedProfileSearchQuery(rawQuery)
        guard !keyword.isEmpty else {
            vm.clearSearch()
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await vm.search(keyword: keyword)
        }
    }
}

@MainActor
final class HistoryListViewModel: ObservableObject {
    @Published var items: [HistoryItemDTO] = []
    @Published var isLoading = false
    @Published var isEnd = false
    @Published var searchItems: [HistoryItemDTO] = []
    @Published var searchIsLoading = false
    @Published var searchIsEnd = false
    private var nextMax: Int64 = 0
    private var nextViewAt: Int64 = 0
    private var searchKeyword = ""
    private var searchPage: Int64 = 1

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

    func clearSearch() {
        searchKeyword = ""
        searchPage = 1
        searchItems.removeAll()
        searchIsLoading = false
        searchIsEnd = false
    }

    func search(keyword: String) async {
        guard !keyword.isEmpty else {
            clearSearch()
            return
        }
        if keyword != searchKeyword {
            searchKeyword = keyword
            searchPage = 1
            searchItems.removeAll()
            searchIsEnd = false
        }
        await fetchSearch(reset: true)
    }

    func loadMoreSearch(keyword: String) async {
        guard keyword == searchKeyword, !keyword.isEmpty, !searchIsLoading, !searchIsEnd else { return }
        await fetchSearch(reset: false)
    }

    private func fetchSearch(reset: Bool) async {
        guard !searchKeyword.isEmpty, !searchIsLoading else { return }
        if reset {
            searchPage = 1
            searchIsEnd = false
        }
        searchIsLoading = true
        let keyword = searchKeyword
        let pageNumber = searchPage
        let page: HistoryPageDTO? = await Task.detached {
            try? CoreClient.shared.userHistorySearch(keyword: keyword, page: pageNumber)
        }.value
        guard keyword == searchKeyword else { return }
        searchIsLoading = false
        guard let page else { searchIsEnd = true; return }
        if reset { searchItems = page.items } else { searchItems.append(contentsOf: page.items) }
        if page.nextMax > 0 {
            searchPage = page.nextMax
        } else {
            searchIsEnd = true
        }
    }
}

// MARK: - Watch later

struct WatchLaterListView: View {
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var vm = WatchLaterListViewModel()
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?

    private var isSearching: Bool {
        !normalizedProfileSearchQuery(searchText).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfileInlineSearchBar(placeholder: "搜索稍后再看", text: $searchText)
            Group {
                if vm.items.isEmpty && vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.items.isEmpty {
                    emptyState(
                        title: isSearching ? "没有搜索结果" : "稍后再看是空的",
                        symbol: "list.bullet.rectangle.portrait",
                        message: isSearching ? nil : "在视频详情页点击「稍后再看」后即可在这里看到"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .background(IbiliTheme.background)
        .navigationTitle("稍后再看")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .refreshable { await vm.load(keyword: normalizedProfileSearchQuery(searchText), force: true) }
        .onChange(of: searchText) { newValue in
            scheduleSearch(newValue)
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func fraction(_ item: WatchLaterItemDTO) -> Double {
        guard item.durationSec > 0, item.progressSec > 0 else { return 0 }
        if item.progressSec < 0 { return 1 }
        return min(1, Double(item.progressSec) / Double(item.durationSec))
    }

    private func scheduleSearch(_ rawQuery: String) {
        searchTask?.cancel()
        let keyword = normalizedProfileSearchQuery(rawQuery)
        searchTask = Task {
            try? await Task.sleep(nanoseconds: keyword.isEmpty ? 0 : 300_000_000)
            guard !Task.isCancelled else { return }
            await vm.load(keyword: keyword, force: true)
        }
    }
}

@MainActor
final class WatchLaterListViewModel: ObservableObject {
    @Published var items: [WatchLaterItemDTO] = []
    @Published var isLoading = false
    private var loaded = false
    private var keyword = ""

    func load(keyword rawKeyword: String = "", force: Bool = false) async {
        let nextKeyword = normalizedProfileSearchQuery(rawKeyword)
        if loaded && !force && nextKeyword == keyword { return }
        keyword = nextKeyword
        isLoading = true
        let query = keyword
        let result: [WatchLaterItemDTO] = await Task.detached {
            (try? CoreClient.shared.userWatchLaterList(keyword: query)) ?? []
        }.value
        guard query == keyword else { return }
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
    @State private var searchText = ""

    private var filteredFolders: [FavFolderInfoDTO] {
        let keyword = normalizedProfileSearchQuery(searchText)
        guard !keyword.isEmpty else { return folders }
        return folders.filter { profileFields([$0.title], match: keyword) }
    }

    private var isSearching: Bool {
        !normalizedProfileSearchQuery(searchText).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfileInlineSearchBar(placeholder: "搜索收藏夹", text: $searchText)
            Group {
                if folders.isEmpty && isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredFolders.isEmpty {
                    emptyState(title: isSearching ? "没有搜索结果" : "暂无收藏夹", symbol: "star")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredFolders) { folder in
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
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?

    private var isSearching: Bool {
        !normalizedProfileSearchQuery(searchText).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfileInlineSearchBar(placeholder: "搜索收藏夹内容", text: $searchText)
            Group {
                if vm.items.isEmpty && vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.items.isEmpty {
                    emptyState(title: isSearching ? "没有搜索结果" : "收藏夹是空的", symbol: "star")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                        Task {
                                            await vm.loadMore(
                                                folderId: folderId,
                                                keyword: normalizedProfileSearchQuery(searchText)
                                            )
                                        }
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
        }
        .background(IbiliTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadInitial(folderId: folderId) }
        .onChange(of: searchText) { newValue in
            scheduleSearch(newValue)
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func scheduleSearch(_ rawQuery: String) {
        searchTask?.cancel()
        let keyword = normalizedProfileSearchQuery(rawQuery)
        searchTask = Task {
            try? await Task.sleep(nanoseconds: keyword.isEmpty ? 0 : 300_000_000)
            guard !Task.isCancelled else { return }
            await vm.search(folderId: folderId, keyword: keyword)
        }
    }
}

@MainActor
final class FavoriteResourcesViewModel: ObservableObject {
    @Published var items: [FavResourceItemDTO] = []
    @Published var isLoading = false
    @Published var isEnd = false
    private var page: Int64 = 1
    private var keyword = ""

    func loadInitial(folderId: Int64) async {
        guard items.isEmpty else { return }
        page = 1
        isEnd = false
        await fetch(folderId: folderId, keyword: "")
    }

    func loadMore(folderId: Int64, keyword rawKeyword: String = "") async {
        guard !isLoading, !isEnd else { return }
        await fetch(folderId: folderId, keyword: normalizedProfileSearchQuery(rawKeyword))
    }

    func search(folderId: Int64, keyword rawKeyword: String) async {
        let nextKeyword = normalizedProfileSearchQuery(rawKeyword)
        guard nextKeyword != keyword || page != 1 || !items.isEmpty else { return }
        keyword = nextKeyword
        page = 1
        isEnd = false
        items.removeAll()
        await fetch(folderId: folderId, keyword: nextKeyword)
    }

    private func fetch(folderId: Int64, keyword query: String) async {
        isLoading = true
        let p = page
        let expectedKeyword = query
        let result: FavResourcePageDTO? = await Task.detached {
            try? CoreClient.shared.userFavResources(mediaId: folderId, page: p, keyword: expectedKeyword)
        }.value
        guard expectedKeyword == keyword else { return }
        isLoading = false
        guard let result else { isEnd = true; return }
        items.append(contentsOf: result.items)
        if result.hasMore { page += 1 } else { isEnd = true }
    }
}

// MARK: - Subscriptions

struct SubscriptionFolderListView: View {
    let mid: Int64
    @StateObject private var vm = SubscriptionFolderListViewModel()
    @State private var searchText = ""

    private var displayedItems: [SubscriptionFolderDTO] {
        let keyword = normalizedProfileSearchQuery(searchText)
        guard !keyword.isEmpty else { return vm.items }
        return vm.items.filter {
            profileFields([$0.title, $0.intro, $0.upperName], match: keyword)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfileInlineSearchBar(placeholder: "搜索我的订阅", text: $searchText)
            Group {
                if vm.items.isEmpty && vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayedItems.isEmpty {
                    emptyState(title: normalizedProfileSearchQuery(searchText).isEmpty ? "暂无订阅" : "没有搜索结果",
                               symbol: "rectangle.stack")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                                NavigationLink {
                                    SubscriptionResourcesView(folder: item)
                                } label: {
                                    SubscriptionFolderRow(
                                        item: item,
                                        onCancel: { Task { await vm.cancel(item) } }
                                    )
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    if normalizedProfileSearchQuery(searchText).isEmpty,
                                       !vm.isEnd,
                                       index >= max(0, displayedItems.count - 4) {
                                        Task { await vm.loadMore(mid: mid) }
                                    }
                                }
                            }
                            if vm.isLoading { ProgressView().padding() }
                        }
                        .padding(12)
                    }
                }
            }
        }
        .background(IbiliTheme.background)
        .navigationTitle("我的订阅")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadInitial(mid: mid) }
        .refreshable { await vm.reload(mid: mid) }
    }
}

private struct SubscriptionFolderRow: View {
    let item: SubscriptionFolderDTO
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: item.cover,
                        contentMode: .fill,
                        targetPointSize: CGSize(width: 220, height: 140),
                        quality: 76)
                .frame(width: 104, height: 66)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                if !item.upperName.isEmpty {
                    Label(item.upperName, systemImage: "person.crop.circle")
                        .font(.caption2)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(1)
                }
                Text("\(item.mediaCount) 个视频")
                    .font(.caption2)
                    .foregroundStyle(IbiliTheme.textSecondary)
            }
            Spacer(minLength: 0)
            Button(role: .destructive, action: onCancel) {
                Image(systemName: "trash")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(IbiliTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

@MainActor
final class SubscriptionFolderListViewModel: ObservableObject {
    @Published var items: [SubscriptionFolderDTO] = []
    @Published var isLoading = false
    @Published var isEnd = false
    private var page: Int64 = 1

    func loadInitial(mid: Int64) async {
        guard items.isEmpty else { return }
        await fetch(mid: mid, reset: true)
    }

    func reload(mid: Int64) async {
        await fetch(mid: mid, reset: true)
    }

    func loadMore(mid: Int64) async {
        guard !isLoading, !isEnd else { return }
        await fetch(mid: mid, reset: false)
    }

    func cancel(_ item: SubscriptionFolderDTO) async {
        let old = items
        items.removeAll { $0.id == item.id }
        do {
            try await Task.detached {
                try CoreClient.shared.userSubscriptionCancel(id: item.folderID, type: item.type)
            }.value
        } catch {
            items = old
        }
    }

    private func fetch(mid: Int64, reset: Bool) async {
        guard !isLoading else { return }
        if reset {
            page = 1
            isEnd = false
            items.removeAll()
        }
        isLoading = true
        let p = page
        let result: SubscriptionFolderPageDTO? = await Task.detached {
            try? CoreClient.shared.userSubscriptions(mid: mid, page: p)
        }.value
        isLoading = false
        guard let result else { isEnd = true; return }
        items.append(contentsOf: result.items)
        if result.hasMore { page += 1 } else { isEnd = true }
    }
}

struct SubscriptionResourcesView: View {
    let folder: SubscriptionFolderDTO
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var vm = SubscriptionResourcesViewModel()

    var body: some View {
        Group {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty {
                emptyState(title: "订阅内容为空", symbol: "rectangle.stack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                pushVideo(router,
                                          aid: item.aid, bvid: item.bvid, cid: item.cid,
                                          title: item.title, cover: item.cover,
                                          author: folder.upperName,
                                          durationSec: item.durationSec,
                                          play: item.play, danmaku: item.danmaku)
                            } label: {
                                CompactVideoRow(
                                    cover: item.cover,
                                    title: item.title,
                                    author: folder.upperName,
                                    durationSec: item.durationSec,
                                    play: item.play,
                                    danmaku: item.danmaku
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .onAppear {
                                if !vm.isEnd, index >= max(0, vm.items.count - 3) {
                                    Task { await vm.loadMore(id: folder.folderID) }
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
        .navigationTitle(folder.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadInitial(id: folder.folderID) }
        .refreshable { await vm.reload(id: folder.folderID) }
    }
}

@MainActor
final class SubscriptionResourcesViewModel: ObservableObject {
    @Published var items: [SubscriptionResourceDTO] = []
    @Published var isLoading = false
    @Published var isEnd = false
    private var page: Int64 = 1

    func loadInitial(id: Int64) async {
        guard items.isEmpty else { return }
        await fetch(id: id, reset: true)
    }

    func reload(id: Int64) async {
        await fetch(id: id, reset: true)
    }

    func loadMore(id: Int64) async {
        guard !isLoading, !isEnd else { return }
        await fetch(id: id, reset: false)
    }

    private func fetch(id: Int64, reset: Bool) async {
        guard !isLoading else { return }
        if reset {
            page = 1
            isEnd = false
            items.removeAll()
        }
        isLoading = true
        let p = page
        let result: SubscriptionResourcePageDTO? = await Task.detached {
            try? CoreClient.shared.userSubscriptionResources(id: id, page: p)
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
    @EnvironmentObject private var router: DeepLinkRouter
    @State private var searchText = ""

    private var isSearching: Bool {
        !normalizedProfileSearchQuery(searchText).isEmpty
    }

    private var displayedItems: [BangumiFollowItemDTO] {
        let keyword = normalizedProfileSearchQuery(searchText)
        guard !keyword.isEmpty else { return vm.items }
        return vm.items.filter {
            profileFields(
                [
                    $0.title,
                    $0.progress,
                    $0.evaluate,
                    $0.newEpIndexShow,
                    $0.renewalTime,
                ],
                match: keyword
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfileInlineSearchBar(placeholder: "搜索我的追番", text: $searchText)
            Group {
                if vm.items.isEmpty && vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayedItems.isEmpty {
                    emptyState(title: isSearching ? "没有搜索结果" : "暂无追番", symbol: "tv")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(displayedItems) { item in
                                Button {
                                    router.openPgc(seasonID: item.seasonId)
                                } label: {
                                    BangumiRow(item: item)
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    if isSearching,
                                       displayedItems.last?.id == item.id,
                                       !vm.isEnd,
                                       displayedItems.count < 20 {
                                        Task { await vm.loadMore(mid: mid) }
                                    }
                                }
                            }
                            if vm.isLoading { ProgressView().padding() }
                        }
                        .padding(12)
                    }
                }
            }
        }
        .background(IbiliTheme.background)
        .navigationTitle("我的追番")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadInitial(mid: mid) }
        .onChange(of: searchText) { newValue in
            guard !normalizedProfileSearchQuery(newValue).isEmpty else { return }
            Task { await vm.loadUntilSearchHasCandidates(mid: mid, keyword: newValue) }
        }
    }
}

private struct BangumiRow: View {
    let item: BangumiFollowItemDTO

    var body: some View {
        PgcPosterCardView(
            data: PgcPosterCardData(
                id: item.seasonId,
                title: item.title,
                cover: item.cover,
                primaryLine: followPrimaryLine,
                secondaryLine: item.progress,
                description: item.evaluate
            ),
            cardWidth: UIScreen.main.bounds.width - 24,
            imageQuality: 78,
            style: .compact
        )
    }

    private var followPrimaryLine: String {
        let latest = item.newEpIndexShow.trimmingCharacters(in: .whitespacesAndNewlines)
        let renewal = item.renewalTime.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latest.isEmpty else { return renewal }
        guard item.isFinish == 0, !renewal.isEmpty else { return latest }
        return "\(latest) · \(renewal)"
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
        isEnd = false
        await fetch(mid: mid)
    }

    func loadMore(mid: Int64) async {
        guard !isLoading, !isEnd else { return }
        await fetch(mid: mid)
    }

    func loadUntilSearchHasCandidates(mid: Int64, keyword rawKeyword: String) async {
        let keyword = normalizedProfileSearchQuery(rawKeyword)
        guard !keyword.isEmpty else { return }
        var attempts = 0
        while !isEnd && attempts < 3 {
            let matches = items.filter {
                profileFields(
                    [
                        $0.title,
                        $0.progress,
                        $0.evaluate,
                        $0.newEpIndexShow,
                        $0.renewalTime,
                    ],
                    match: keyword
                )
            }
            if matches.count >= 12 { return }
            await loadMore(mid: mid)
            attempts += 1
        }
    }

    private func fetch(mid: Int64) async {
        guard !isLoading else { return }
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
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation

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
                        Group {
                            if isInPlayerHostNavigation {
                                Button {
                                    router.openUserSpace(mid: user.mid)
                                } label: {
                                    RelationRow(user: user)
                                }
                            } else {
                                NavigationLink {
                                    UserSpaceView(mid: user.mid)
                                } label: {
                                    RelationRow(user: user)
                                }
                            }
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
