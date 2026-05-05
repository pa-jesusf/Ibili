import SwiftUI

/// Top-level comment list. Each row taps into a `CommentThreadSheet`
/// when the comment has nested replies.
///
/// Rendering strategy: the parent video-detail page already lives inside
/// a single `ScrollView`; we use `LazyVStack` so SwiftUI only composes
/// rows currently in (or near) the viewport. Avatar fetches go through
/// `RemoteImage` (NSCache-backed) so they survive scroll-recycle. Bilibili
/// emote / picture / jump-link parsing happens once at row level via
/// `RichReplyText` + `ReplyPictureGrid`.
struct CommentListView: View {
    let oid: Int64
    /// `kind` arg for the comment API. 1 = video, 11 = image post,
    /// 17 = word/forward dynamic, 12 = article. Defaults to video so
    /// existing call sites keep their current behaviour.
    var kind: Int32 = 1
    @StateObject private var ownedViewModel = CommentListViewModel()
    private let providedViewModel: CommentListViewModel?
    @State private var thread: ReplyItemDTO?
    @State private var showSendSheet = false
    @EnvironmentObject private var session: AppSession

    init(oid: Int64,
         kind: Int32 = 1,
         viewModel: CommentListViewModel? = nil) {
        self.oid = oid
        self.kind = kind
        self.providedViewModel = viewModel
    }

    private var vm: CommentListViewModel {
        providedViewModel ?? ownedViewModel
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("评论")
                    .font(.headline)
                Text("\(vm.total)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(IbiliTheme.textSecondary)
                Spacer()
                Menu {
                    Button { vm.sort = 1 } label: {
                        Label("热门", systemImage: vm.sort == 1 ? "checkmark" : "")
                    }
                    Button { vm.sort = 2 } label: {
                        Label("时间", systemImage: vm.sort == 2 ? "checkmark" : "")
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(vm.sort == 1 ? "热门" : "时间")
                        Image(systemName: "chevron.down").imageScale(.small)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(IbiliTheme.textSecondary)
                }
            }
            .padding(.bottom, 8)

            // Composer entry — tapping anywhere opens the comment send
            // sheet. Only shown to logged-in users; otherwise the
            // anonymous reader sees a hint to sign in.
            Button {
                if session.isLoggedIn { showSendSheet = true }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .imageScale(.small)
                        .foregroundStyle(IbiliTheme.accent)
                    Text(session.isLoggedIn ? "发条友善的评论…" : "登录后即可发表评论")
                        .font(.footnote)
                        .foregroundStyle(IbiliTheme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(IbiliTheme.surface)
                )
            }
            .buttonStyle(.plain)
            .disabled(!session.isLoggedIn)
            .padding(.bottom, 12)

            if let top = vm.top {
                CommentRow(item: top, upperMid: vm.upperMid, isPinned: true,
                           onLike: { Task { await vm.toggleLike(rpid: top.rpid) } }) { thread = top }
                Divider()
            }

            ForEach(vm.items) { item in
                CommentRow(item: item, upperMid: vm.upperMid, isPinned: false,
                           onLike: { Task { await vm.toggleLike(rpid: item.rpid) } }) { thread = item }
                    .onAppear {
                        if item.id == vm.items.last?.id, !vm.isEnd {
                            Task { await vm.loadMore() }
                        }
                    }
                Divider()
            }

            if vm.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 12)
            } else if vm.isEnd, !vm.items.isEmpty {
                HStack { Spacer(); Text("已经到底了").font(.caption).foregroundStyle(.secondary); Spacer() }
                    .padding(.vertical, 12)
            } else if vm.items.isEmpty, !vm.isLoading {
                emptyState(title: "暂无评论", symbol: "bubble.left.and.bubble.right")
                    .padding(.vertical, 30)
            }
        }
        .task(id: oid) { vm.bind(oid: oid, kind: kind) }
        .sheet(item: $thread) { root in
            CommentThreadSheet(root: root)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSendSheet) {
            CommentSendSheet(
                oid: oid,
                kind: kind,
                selfMid: session.mid,
                selfName: ""
            ) { echo in
                vm.prependLocal(echo)
            }
        }
    }
}

/// One row in the comment list. Clamped to 6 lines; tapping opens the
/// thread sheet for full replies.
struct CommentRow: View {
    let item: ReplyItemDTO
    let upperMid: Int64
    let isPinned: Bool
    var onLike: (() -> Void)? = nil
    let onOpenThread: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(url: item.face,
                        targetPointSize: CGSize(width: 32, height: 32),
                        quality: 75)
                .frame(width: 32, height: 32)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.uname)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(item.mid == upperMid ? IbiliTheme.accent : IbiliTheme.textPrimary)
                    if item.mid == upperMid {
                        Text("UP")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(IbiliTheme.accent))
                    }
                    if isPinned {
                        Text("置顶")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(IbiliTheme.accent)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(Capsule().stroke(IbiliTheme.accent, lineWidth: 0.5))
                    }
                    Spacer()
                }
                RichReplyText(message: item.message,
                              emotes: item.emotes,
                              jumpUrls: item.jumpUrls,
                              lineLimit: 6)
                    .font(.footnote)
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = item.message
                        } label: { Label("复制全部", systemImage: "doc.on.doc") }
                        Button {
                            SelectableTextPresenter.present(text: item.message, title: "选择复制评论")
                        } label: { Label("选择复制", systemImage: "selection.pin.in.out") }
                    }
                if !item.pictures.isEmpty {
                    ReplyPictureGrid(urls: item.pictures)
                        .padding(.top, 2)
                }
                HStack(spacing: 14) {
                    Button {
                        onLike?()
                    } label: {
                        Label(BiliFormat.compactCount(item.like),
                              systemImage: item.action == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .foregroundStyle(item.action == 1 ? IbiliTheme.accent : IbiliTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(onLike == nil)
                    if item.replyCount > 0 {
                        Button {
                            onOpenThread()
                        } label: {
                            Label("\(item.replyCount) 条回复", systemImage: "arrowshape.turn.up.left")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(IbiliTheme.textSecondary)
                    }
                    Spacer()
                    if item.ctime > 0 {
                        Text(BiliFormat.relativeDate(item.ctime))
                    }
                }
                .font(.caption)
                .foregroundStyle(IbiliTheme.textSecondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.replyCount > 0 { onOpenThread() }
        }
    }
}

/// Picture attachment grid for a reply. Capped at 60% of screen width
/// (per design spec) so multi-image attachments don't dominate the row.
/// 1 → single tile, 2 → side-by-side, 3+ → 3-column. Tapping any tile
/// opens `ImagePreviewSheet` with pinch-zoom + save-to-album.
struct ReplyPictureGrid: View {
    let urls: [String]

    @State private var preview: PreviewSelection?

    private struct PreviewSelection: Identifiable {
        let id = UUID()
        let index: Int
    }

    var body: some View {
        let cols = urls.count == 1 ? 1 : (urls.count == 2 ? 2 : 3)
        let target = UIScreen.main.bounds.width * 0.6
        let tileSide = (target - CGFloat(cols - 1) * 4) / CGFloat(cols)
        let columns = Array(
            repeating: GridItem(.fixed(tileSide), spacing: 4),
            count: cols
        )
        HStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, u in
                    Button { preview = .init(index: i) } label: {
                        RemoteImage(url: u,
                                    contentMode: .fill,
                                    targetPointSize: CGSize(width: tileSide, height: tileSide),
                                    quality: 75)
                            .frame(width: tileSide, height: tileSide)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .frame(width: tileSide, height: tileSide)
                    .contentShape(ReplyPictureHitShape(inset: 3, cornerRadius: 6))
                    .buttonStyle(.plain)
                }
            }
            .frame(width: target, alignment: .leading)
            Spacer(minLength: 0)
        }
        .fullScreenCover(item: $preview) { sel in
            ImagePreviewSheet(urls: urls, initialIndex: sel.index)
        }
    }
}

private struct ReplyPictureHitShape: Shape {
    let inset: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: inset, dy: inset)
        let adjustedRadius = max(0, cornerRadius - inset)
        return RoundedRectangle(cornerRadius: adjustedRadius, style: .continuous)
            .path(in: insetRect)
    }
}
