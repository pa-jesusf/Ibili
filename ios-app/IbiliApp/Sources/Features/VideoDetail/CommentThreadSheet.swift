import SwiftUI

/// Sheet showing the full reply thread (楼中楼) for a single root comment.
///
/// The sheet uses the shared virtualized collection. Ordinary entry uses the
/// Web page API; notification entry uses the server-positioned gRPC window and
/// its opaque continuation offset.
struct CommentThreadSheet: View {
    let root: ReplyItemDTO
    var kind: Int32 = 1
    var upperMid: Int64 = 0
    var focusedReplyRpid: Int64 = 0
    var initialFocusedPage: ReplyPageDTO? = nil
    var onOpenUser: ((Int64) -> Void)? = nil
    var onLocalReply: ((ReplyItemDTO, Int64) -> Void)? = nil

    @State private var replies: [ReplyItemDTO] = []
    @State private var rootState: ReplyItemDTO?
    @State private var page: Int64 = 1
    @State private var isLoading = false
    @State private var isEnd = false
    @State private var total: Int64 = 0
    @State private var targetedNextOffset = ""
    @State private var serverUpperMid: Int64 = 0
    @State private var hasStartedLoading = false
    @State private var composer: CommentThreadComposerContext?
    @EnvironmentObject private var session: AppSession

    private var currentRootItem: ReplyItemDTO {
        rootState ?? root
    }

    private var navigationTitleText: String {
        if currentRootItem.replyCount > 0 {
            let visibleTotal = max(total, Int64(currentRootItem.replyCount))
            return "\(visibleTotal) 条回复"
        }
        return "评论详情"
    }

    var body: some View {
        GeometryReader { proxy in
            NavigationStack {
                VirtualizedCollectionSurface(
                    items: replies,
                    layout: .list(
                        horizontalInset: 0,
                        bottomInset: 12,
                        spacing: 0,
                        estimatedHeight: 180
                    ),
                    header: threadHeader,
                    footer: threadFooter,
                    scrollToItemID: focusedReplyRpid > 0 && focusedReplyRpid != root.rpid
                        ? focusedReplyRpid
                        : nil,
                    prefetchThreshold: 2,
                    onLoadMore: {
                        guard hasStartedLoading else { return }
                        Task { await loadMore() }
                    }
                ) { reply, _ in
                    AnyView(
                        VStack(spacing: 0) {
                            threadRow(for: reply)
                                .background(
                                    reply.rpid == focusedReplyRpid
                                        ? IbiliTheme.accent.opacity(0.10)
                                        : Color.clear
                                )
                            Divider()
                        }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .modifier(ProMotionScrollHint())
                .navigationTitle(navigationTitleText)
                .navigationBarTitleDisplayMode(.inline)
            }
            .environment(\.commentViewportHeight, max(1, proxy.size.height))
            .environment(\.commentContentWidth, max(1, proxy.size.width - 32))
        }
        .task {
            guard root.replyCount > 0 || focusedReplyRpid > 0 else { return }
            hasStartedLoading = true
            if let initialFocusedPage, focusedReplyRpid > 0 {
                applyInitialFocusedPage(initialFocusedPage)
            } else {
                await loadMore()
            }
        }
        .sheet(item: $composer) { context in
            CommentSendSheet(
                oid: currentRootItem.oid,
                kind: kind,
                selfMid: session.mid,
                selfName: "",
                root: currentRootItem.rpid,
                parent: context.parent.rpid,
                replyToName: context.parent.uname
            ) { echo in
                insertLocalReply(echo)
            }
        }
    }

    private var threadHeader: () -> AnyView {
        {
            AnyView(
                VStack(spacing: 0) {
                    threadRow(for: currentRootItem)
                    Divider()
                }
            )
        }
    }

    private var threadFooter: (() -> AnyView)? {
        if isLoading {
            return {
                AnyView(
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                )
            }
        }
        if isEnd, !replies.isEmpty {
            return {
                AnyView(
                    Text("已经到底了")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                )
            }
        }
        return nil
    }

    private func threadRow(for item: ReplyItemDTO) -> AnyView {
        AnyView(
            CommentRow(item: item,
                       upperMid: serverUpperMid > 0 ? serverUpperMid : upperMid,
                       isPinned: false,
                       messageLineLimit: nil,
                       allowsThreadPresentation: false,
                       showsPreviewReplies: false,
                       onLike: {
                           Task { await toggleLike(on: item) }
                       },
                       onReply: session.isLoggedIn ? {
                           composer = CommentThreadComposerContext(parent: item)
                       } : nil,
                       onOpenUser: onOpenUser,
                       onOpenThread: {})
                .padding(.horizontal, 16)
        )
    }

    private func loadMore() async {
        guard !isLoading, !isEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let rootRpid = currentRootItem.rpid
            let oid = currentRootItem.oid
            let p: ReplyPageDTO
            if focusedReplyRpid > 0 {
                let target = targetedNextOffset.isEmpty && replies.isEmpty ? focusedReplyRpid : 0
                let offset = targetedNextOffset
                p = try await Task.detached(priority: .userInitiated) { [oid, kind, rootRpid] in
                    try CoreClient.shared.replyDetailTarget(
                        oid: oid,
                        kind: kind,
                        root: rootRpid,
                        targetRpid: target,
                        nextOffset: offset
                    )
                }.value
                targetedNextOffset = p.cursorNext
                if p.upperMid > 0 { serverUpperMid = p.upperMid }
                if let serverRoot = p.top { rootState = serverRoot }
            } else {
                p = try await Task.detached(priority: .userInitiated) { [oid, kind, rootRpid, page] in
                    try CoreClient.shared.replyDetail(oid: oid, kind: kind, root: rootRpid, page: page)
                }.value
                page += 1
            }
            if replies.isEmpty { total = p.total }
            let existing = Set(replies.map(\.rpid))
            replies.append(contentsOf: p.items.filter { !existing.contains($0.rpid) })
            isEnd = p.isEnd
        } catch {
            isEnd = true
            AppLog.error("comments", "评论详情加载失败", error: error)
        }
    }

    @MainActor
    private func applyInitialFocusedPage(_ page: ReplyPageDTO) {
        rootState = page.top ?? root
        replies = page.items
        total = page.total
        targetedNextOffset = page.cursorNext
        serverUpperMid = page.upperMid
        isEnd = page.isEnd
    }

    /// Optimistic toggle for the thread sheet — same shape as
    /// `CommentListViewModel.toggleLike` but local to the sheet's state.
    @MainActor
    private func toggleLike(on target: ReplyItemDTO) async {
        let next: Int32 = (target.action == 1) ? 0 : 1
        applyLike(rpid: target.rpid, action: next)
        do {
            try await Task.detached(priority: .userInitiated) { [oid = root.oid, kind, rpid = target.rpid] in
                try CoreClient.shared.replyLike(oid: oid, kind: kind, rpid: rpid, action: next)
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

    @MainActor
    private func insertLocalReply(_ reply: ReplyItemDTO) {
        replies.insert(reply, at: 0)
        total += 1
        rootState = (rootState ?? root).withReplyAdded(reply)
        onLocalReply?(reply, root.rpid)
    }
}

private struct CommentThreadComposerContext: Identifiable {
    let id = UUID()
    let parent: ReplyItemDTO
}
