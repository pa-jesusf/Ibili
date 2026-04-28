import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var items: [FeedItemDTO] = []
    @Published var isLoading = false
    @Published var errorText: String?

    private var idx: Int64 = 0

    func loadInitial() async {
        guard items.isEmpty else { return }
        await load(reset: true)
    }

    func refresh() async {
        await load(reset: true)
    }

    func loadMore() async {
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        isLoading = true; errorText = nil
        let target: Int64 = reset ? 0 : idx
        AppLog.info("home", reset ? "开始加载首页" : "开始加载更多首页", metadata: [
            "idx": String(target),
        ])
        do {
            let page = try await Task.detached { try CoreClient.shared.feedHome(idx: target, ps: 20) }.value
            if reset { self.items = page.items }
            else { self.items.append(contentsOf: page.items) }
            self.idx = page.items.last?.aid ?? self.idx
            AppLog.info("home", reset ? "首页加载成功" : "首页追加成功", metadata: [
                "count": String(page.items.count),
                "nextIdx": String(self.idx),
            ])
        } catch {
            self.errorText = error.localizedDescription
            AppLog.error("home", reset ? "首页加载失败" : "首页追加失败", error: error, metadata: [
                "idx": String(target),
            ])
        }
        isLoading = false
    }
}
