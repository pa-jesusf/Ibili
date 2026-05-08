import SwiftUI

enum HomeFeedSection: String, CaseIterable, Identifiable {
    case recommend
    case hot
    case live

    var id: Self { self }

    var title: String {
        switch self {
        case .recommend: return "推荐"
        case .hot: return "热门"
        case .live: return "直播"
        }
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    let section: HomeFeedSection
    @Published var items: [FeedItemDTO] = []
    @Published var isLoading = false
    @Published var isEnd = false
    @Published var errorText: String?

    private var idx: Int64 = 0
    private var page: Int64 = 1

    init(section: HomeFeedSection) {
        self.section = section
    }

    func loadInitial() async {
        guard items.isEmpty else { return }
        await load(reset: true)
    }

    func refresh() async {
        await load(reset: true)
    }

    func loadMore() async {
        guard !isLoading, !isEnd else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        isLoading = true
        errorText = nil
        if reset {
            isEnd = false
            idx = 0
            page = 1
        }

        switch section {
        case .recommend:
            await loadRecommend(reset: reset)
        case .hot:
            await loadHot(reset: reset)
        case .live:
            break
        }

        isLoading = false
    }

    private func loadRecommend(reset: Bool) async {
        let targetIdx: Int64 = reset ? 0 : idx
        AppLog.info("home", reset ? "开始加载首页推荐" : "开始加载更多首页推荐", metadata: [
            "idx": String(targetIdx),
            "section": section.rawValue,
        ])
        do {
            let page = try await Task.detached {
                try CoreClient.shared.feedHome(idx: targetIdx, ps: 20)
            }.value
            let fresh = mergeFresh(page.items, reset: reset)
            if reset { items = fresh }
            else { items.append(contentsOf: fresh) }
            idx = page.items.last?.aid ?? idx
            isEnd = fresh.isEmpty
            AppLog.info("home", reset ? "首页推荐加载成功" : "首页推荐追加成功", metadata: [
                "count": String(fresh.count),
                "nextIdx": String(idx),
                "section": section.rawValue,
            ])
        } catch {
            errorText = error.localizedDescription
            AppLog.error("home", reset ? "首页推荐加载失败" : "首页推荐追加失败", error: error, metadata: [
                "idx": String(targetIdx),
                "section": section.rawValue,
            ])
        }
    }

    private func loadHot(reset: Bool) async {
        let targetPage: Int64 = reset ? 1 : page
        AppLog.info("home", reset ? "开始加载首页热门" : "开始加载更多首页热门", metadata: [
            "page": String(targetPage),
            "section": section.rawValue,
        ])
        do {
            let page = try await Task.detached {
                try CoreClient.shared.feedPopular(pn: targetPage, ps: 20)
            }.value
            let fresh = mergeFresh(page.items, reset: reset)
            if reset { items = fresh }
            else { items.append(contentsOf: fresh) }
            self.page = targetPage + 1
            isEnd = fresh.isEmpty
            AppLog.info("home", reset ? "首页热门加载成功" : "首页热门追加成功", metadata: [
                "count": String(fresh.count),
                "nextPage": String(self.page),
                "section": section.rawValue,
            ])
        } catch {
            errorText = error.localizedDescription
            AppLog.error("home", reset ? "首页热门加载失败" : "首页热门追加失败", error: error, metadata: [
                "page": String(targetPage),
                "section": section.rawValue,
            ])
        }
    }

    private func mergeFresh(_ incoming: [FeedItemDTO], reset: Bool) -> [FeedItemDTO] {
        guard !reset else { return incoming }
        let existing = Set(items.map(FeedIdentity.init))
        return incoming.filter { !existing.contains(FeedIdentity($0)) }
    }
}

@MainActor
final class LiveHomeViewModel: ObservableObject {
    @Published var items: [LiveFeedItemDTO] = []
    @Published var isLoading = false
    @Published var isEnd = false
    @Published var errorText: String?

    private var page: Int64 = 1

    func loadInitial() async {
        guard items.isEmpty else { return }
        await load(reset: true)
    }

    func refresh() async {
        await load(reset: true)
    }

    func loadMore() async {
        guard !isLoading, !isEnd else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        isLoading = true
        errorText = nil
        if reset {
            isEnd = false
            page = 1
        }
        let targetPage = page
        do {
            let response = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.liveFeed(page: targetPage)
            }.value
            let fresh = mergeFresh(response.items, reset: reset)
            if reset {
                items = fresh
            } else {
                items.append(contentsOf: fresh)
            }
            page = targetPage + 1
            isEnd = !response.hasMore || fresh.isEmpty
        } catch {
            errorText = error.localizedDescription
            isEnd = false
        }
        isLoading = false
    }

    private func mergeFresh(_ incoming: [LiveFeedItemDTO], reset: Bool) -> [LiveFeedItemDTO] {
        guard !reset else { return incoming }
        let existing = Set(items.map(\.roomID))
        return incoming.filter { !existing.contains($0.roomID) }
    }
}

private struct FeedIdentity: Hashable {
    let aid: Int64
    let bvid: String
    let cid: Int64

    init(_ item: FeedItemDTO) {
        aid = item.aid
        bvid = item.bvid
        cid = item.cid
    }
}
