import SwiftUI

/// Sheet showing the full reply thread for a single root comment.
struct CommentThreadSheet: View {
    let root: ReplyItemDTO

    @State private var replies: [ReplyItemDTO] = []
    @State private var page: Int64 = 1
    @State private var isLoading = false
    @State private var isEnd = false
    @State private var total: Int64 = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    CommentRow(item: root, upperMid: 0, isPinned: false) {}
                        .padding(.horizontal, 16)
                    Divider()
                    ForEach(replies) { r in
                        CommentRow(item: r, upperMid: 0, isPinned: false) {}
                            .padding(.horizontal, 16)
                        Divider()
                    }
                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.vertical, 12)
                    }
                }
            }
            .navigationTitle("\(total) 条回复")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await loadMore() }
    }

    private func loadMore() async {
        guard !isLoading, !isEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let p = try await Task.detached(priority: .userInitiated) { [root, page] in
                try CoreClient.shared.replyDetail(oid: root.oid, kind: 1, root: root.rpid, page: page)
            }.value
            if page == 1 { total = p.total }
            replies.append(contentsOf: p.items)
            isEnd = p.isEnd
            page += 1
        } catch {
            isEnd = true
            AppLog.error("comments", "评论详情加载失败", error: error)
        }
    }
}
