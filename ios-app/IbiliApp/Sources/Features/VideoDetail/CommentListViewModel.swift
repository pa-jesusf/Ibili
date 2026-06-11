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
    @Published var sort: Int32 = 1 {
        didSet {
            guard sort != oldValue else { return }
            reset()
        }
    }
    @Published var errorText: String?

    private var oid: Int64 = 0
    private var kind: Int32 = 1
    private var nextOffset: String = ""
    private var generation: UInt64 = 0
    private var loadedReplyIDs = Set<Int64>()

    var prefetchTriggerID: Int64? {
        guard !isEnd, !items.isEmpty else { return nil }
        let index = max(0, items.count - 4)
        return items[index].rpid
    }

    func bind(oid: Int64, kind: Int32 = 1) {
        let isSameTarget = self.oid == oid && self.kind == kind
        self.oid = oid
        self.kind = kind
        if isSameTarget {
            if top == nil, items.isEmpty, !isLoading {
                errorText = nil
                Task { await loadMore() }
            }
            return
        }
        reset()
    }

    func reset() {
        generation &+= 1
        let requestGeneration = generation
        items.removeAll()
        loadedReplyIDs.removeAll()
        top = nil
        total = 0
        upperMid = 0
        nextOffset = ""
        isLoading = false
        isEnd = false
        errorText = nil
        Task { await loadMore(expectedGeneration: requestGeneration) }
    }

    func refresh(oid: Int64, kind: Int32 = 1) async {
        self.oid = oid
        self.kind = kind
        generation &+= 1
        let requestGeneration = generation
        guard oid > 0 else { return }
        isLoading = true
        errorText = nil
        defer {
            if requestGeneration == generation {
                isLoading = false
            }
        }
        do {
            let page = try await Task.detached(priority: .userInitiated) { [oid, kind, sort] in
                try CoreClient.shared.replyMain(oid: oid, kind: kind, sort: sort, nextOffset: "")
            }.value
            guard requestGeneration == generation, self.oid == oid, self.kind == kind else { return }
            top = page.top
            total = page.total
            upperMid = page.upperMid
            replaceItems(page.items, pinnedTop: page.top)
            nextOffset = page.cursorNext
            isEnd = page.isEnd || page.cursorNext.isEmpty
            AppLog.info("comments", "评论刷新成功", metadata: [
                "oid": String(oid),
                "sort": String(sort),
                "count": String(page.items.count),
            ])
        } catch {
            guard requestGeneration == generation, self.oid == oid, self.kind == kind else { return }
            errorText = (error as NSError).localizedDescription
            AppLog.error("comments", "评论刷新失败", error: error, metadata: ["oid": String(oid)])
        }
    }

    func loadMore() async {
        await loadMore(expectedGeneration: nil)
    }

    private func loadMore(expectedGeneration: UInt64?) async {
        let requestGeneration = expectedGeneration ?? generation
        guard requestGeneration == generation else { return }
        guard oid > 0, !isLoading, !isEnd else { return }
        let requestOid = oid
        let requestKind = kind
        let requestSort = sort
        let requestOffset = nextOffset
        isLoading = true
        defer {
            if requestGeneration == generation {
                isLoading = false
            }
        }
        do {
            let page = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.replyMain(
                    oid: requestOid,
                    kind: requestKind,
                    sort: requestSort,
                    nextOffset: requestOffset
                )
            }.value
            guard requestGeneration == generation,
                  self.oid == requestOid,
                  self.kind == requestKind,
                  self.sort == requestSort else { return }
            if requestOffset.isEmpty {
                top = page.top
                total = page.total
                upperMid = page.upperMid
            }
            appendItems(page.items, pinnedTop: top)
            nextOffset = page.cursorNext
            isEnd = page.isEnd || page.cursorNext.isEmpty
        } catch {
            guard requestGeneration == generation,
                  self.oid == requestOid,
                  self.kind == requestKind,
                  self.sort == requestSort else { return }
            errorText = (error as NSError).localizedDescription
            AppLog.error("comments", "评论加载失败", error: error, metadata: ["oid": String(requestOid)])
        }
    }

    /// Toggle like on a reply. Optimistic — flips local `action` and
    /// nudges `like` immediately, then calls `interaction.reply_like`.
    /// Rolls back on failure.
    func toggleLike(rpid: Int64) async {
        let nextAction: Int32 = currentAction(for: rpid) == 1 ? 0 : 1
        applyLikeDelta(rpid: rpid, action: nextAction)
        do {
            try await Task.detached(priority: .userInitiated) { [oid, kind] in
                try CoreClient.shared.replyLike(oid: oid, kind: kind, rpid: rpid, action: nextAction)
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
        if item.rpid > 0, let existing = items.firstIndex(where: { $0.rpid == item.rpid }) {
            items[existing] = item
            return
        }
        if item.rpid > 0 {
            loadedReplyIDs.insert(item.rpid)
        }
        items.insert(item, at: 0)
        total += 1
    }

    /// A nested reply was posted from the list. Keep the root row fresh
    /// without forcing a full comment refresh.
    func noteLocalReply(_ reply: ReplyItemDTO, underRoot rootRpid: Int64) {
        if top?.rpid == rootRpid {
            top = top?.withReplyAdded(reply)
            return
        }
        if let idx = items.firstIndex(where: { $0.rpid == rootRpid }) {
            items[idx] = items[idx].withReplyAdded(reply)
        }
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

    private func replaceItems(_ incoming: [ReplyItemDTO], pinnedTop: ReplyItemDTO?) {
        loadedReplyIDs.removeAll(keepingCapacity: true)
        items = uniqueFreshItems(from: incoming, pinnedTop: pinnedTop)
    }

    private func appendItems(_ incoming: [ReplyItemDTO], pinnedTop: ReplyItemDTO?) {
        let fresh = uniqueFreshItems(from: incoming, pinnedTop: pinnedTop)
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh)
    }

    private func uniqueFreshItems(from incoming: [ReplyItemDTO], pinnedTop: ReplyItemDTO?) -> [ReplyItemDTO] {
        let pinnedID = pinnedTop?.rpid
        var fresh: [ReplyItemDTO] = []
        fresh.reserveCapacity(incoming.count)
        for item in incoming {
            guard item.rpid > 0 else { continue }
            guard item.rpid != pinnedID else { continue }
            guard loadedReplyIDs.insert(item.rpid).inserted else { continue }
            fresh.append(item)
        }
        return fresh
    }
}
