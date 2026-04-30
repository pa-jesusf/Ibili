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

    /// Toggle like on a reply. Optimistic — flips local `action` and
    /// nudges `like` immediately, then calls `interaction.reply_like`.
    /// Rolls back on failure.
    func toggleLike(rpid: Int64) async {
        let nextAction: Int32 = currentAction(for: rpid) == 1 ? 0 : 1
        applyLikeDelta(rpid: rpid, action: nextAction)
        do {
            try await Task.detached(priority: .userInitiated) { [oid] in
                try CoreClient.shared.replyLike(oid: oid, kind: 1, rpid: rpid, action: nextAction)
            }.value
        } catch {
            // rollback
            applyLikeDelta(rpid: rpid, action: nextAction == 1 ? 0 : 1)
            errorText = (error as NSError).localizedDescription
            AppLog.error("comments", "点赞失败", error: error, metadata: ["rpid": String(rpid)])
        }
    }

    private func currentAction(for rpid: Int64) -> Int32 {        if top?.rpid == rpid { return top?.action ?? 0 }
        return items.first(where: { $0.rpid == rpid })?.action ?? 0
    }

    /// Insert a freshly-submitted reply at the top of the list so the
    /// user sees their own comment immediately — saves a full page
    /// refetch round-trip after `replyAdd`.
    func prependLocal(_ item: ReplyItemDTO) {
        items.insert(item, at: 0)
        total += 1
    }

    private func applyLikeDelta(rpid: Int64, action: Int32) {
        if top?.rpid == rpid, var t = top {
            let prev = t.action
            if prev != action {
                t.action = action
                t.like = max(0, t.like + (action == 1 ? 1 : -1))
                top = t
            }
            return
        }
        if let idx = items.firstIndex(where: { $0.rpid == rpid }) {
            let prev = items[idx].action
            if prev != action {
                items[idx].action = action
                items[idx].like = max(0, items[idx].like + (action == 1 ? 1 : -1))
            }
        }
    }
}
