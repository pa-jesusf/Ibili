import Foundation

/// View-model for the comment list. Cursor-based for the top-level
/// list (`reply.main` returns `pagination_str.next_offset` we round-trip
/// into the next call). Sort is 1 (热门) or 2 (时间).
@MainActor
final class CommentListViewModel: ObservableObject {
    @Published private(set) var items: [ReplyItemDTO] = []
    @Published private(set) var top: ReplyItemDTO?
    @Published private(set) var total: Int64 = 0
    @Published private(set) var upperMid: Int64 = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isEnd = false
    @Published var sort: Int32 = 1 { didSet { reset() } }
    @Published var errorText: String?

    private var oid: Int64 = 0
    private var nextOffset: String = ""

    func bind(oid: Int64) {
        if self.oid == oid { return }
        self.oid = oid
        reset()
    }

    func reset() {
        items.removeAll()
        top = nil
        nextOffset = ""
        isEnd = false
        Task { await loadMore() }
    }

    func loadMore() async {
        guard oid > 0, !isLoading, !isEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await Task.detached(priority: .userInitiated) { [oid, sort, nextOffset] in
                try CoreClient.shared.replyMain(oid: oid, kind: 1, sort: sort, nextOffset: nextOffset)
            }.value
            if nextOffset.isEmpty {
                top = page.top
                total = page.total
                upperMid = page.upperMid
            }
            items.append(contentsOf: page.items)
            nextOffset = page.cursorNext
            isEnd = page.isEnd || page.cursorNext.isEmpty
        } catch {
            errorText = (error as NSError).localizedDescription
            AppLog.error("comments", "评论加载失败", error: error, metadata: ["oid": String(oid)])
        }
    }
}
