import SwiftUI

/// Sheet showing the full reply thread (楼中楼) for a single root comment.
///
/// The sheet runs its own `LazyVStack` and a small page-based loader; we
/// only fetch the next page when the *last* visible row appears, so users
/// who only scan the top of a thread never pay for the rest. Avatars +
/// rich content reuse the same `RemoteImage` / `RichReplyText` pipeline
/// as the main list.
struct CommentThreadSheet: View {
    let root: ReplyItemDTO

    @State private var replies: [ReplyItemDTO] = []
    @State private var rootState: ReplyItemDTO?
    @State private var page: Int64 = 1
    @State private var isLoading = false
    @State private var isEnd = false
    @State private var total: Int64 = 0

    private var currentRootItem: ReplyItemDTO {
        rootState ?? root
    }

    private var navigationTitleText: String {
        if root.replyCount > 0 {
            let visibleTotal = max(total, Int64(root.replyCount))
            return "\(visibleTotal) 条回复"
        }
        return "评论详情"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    threadRow(for: currentRootItem)
                    Divider()
                    ForEach(replies) { r in
                        threadRow(for: r)
                            .onAppear {
                                if r.id == replies.last?.id, !isEnd, !isLoading {
                                    Task { await loadMore() }
                                }
                            }
                        Divider()
                    }
                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.vertical, 12)
                    } else if isEnd, !replies.isEmpty {
                        HStack { Spacer(); Text("已经到底了").font(.caption).foregroundStyle(.secondary); Spacer() }
                            .padding(.vertical, 12)
                    }
                }
            }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            guard root.replyCount > 0 else { return }
            await loadMore()
        }
    }

    private func threadRow(for item: ReplyItemDTO) -> AnyView {
        AnyView(
            CommentRow(item: item,
                       upperMid: 0,
                       isPinned: false,
                       messageLineLimit: nil,
                       allowsThreadPresentation: false,
                       onLike: {
                           Task { await toggleLike(on: item) }
                       },
                       onOpenThread: {})
                .padding(.horizontal, 16)
        )
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

    /// Optimistic toggle for the thread sheet — same shape as
    /// `CommentListViewModel.toggleLike` but local to the sheet's state.
    @MainActor
    private func toggleLike(on target: ReplyItemDTO) async {
        let next: Int32 = (target.action == 1) ? 0 : 1
        applyLike(rpid: target.rpid, action: next)
        do {
            try await Task.detached(priority: .userInitiated) { [oid = root.oid, rpid = target.rpid] in
                try CoreClient.shared.replyLike(oid: oid, kind: 1, rpid: rpid, action: next)
            }.value
        } catch {
            applyLike(rpid: target.rpid, action: next == 1 ? 0 : 1)
            AppLog.error("comments", "点赞失败", error: error, metadata: ["rpid": String(target.rpid)])
        }
    }

    @MainActor
    private func applyLike(rpid: Int64, action: Int32) {
        if (rootState?.rpid ?? root.rpid) == rpid {
            var t = rootState ?? root
            if t.action != action {
                t.action = action
                t.like = max(0, t.like + (action == 1 ? 1 : -1))
                rootState = t
            }
            return
        }
        if let i = replies.firstIndex(where: { $0.rpid == rpid }) {
            if replies[i].action != action {
                replies[i].action = action
                replies[i].like = max(0, replies[i].like + (action == 1 ? 1 : -1))
            }
        }
    }
}
