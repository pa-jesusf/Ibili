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
    @StateObject private var vm = CommentListViewModel()
    @State private var thread: ReplyItemDTO?

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
            .padding(.bottom, 12)

            if let top = vm.top {
                CommentRow(item: top, upperMid: vm.upperMid, isPinned: true) { thread = top }
                Divider()
            }

            ForEach(vm.items) { item in
                CommentRow(item: item, upperMid: vm.upperMid, isPinned: false) { thread = item }
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
        .task(id: oid) { vm.bind(oid: oid) }
        .sheet(item: $thread) { root in
            CommentThreadSheet(root: root)
                .presentationDetents([.medium, .large])
        }
    }
}

/// One row in the comment list. Clamped to 6 lines; tapping opens the
/// thread sheet for full replies.
struct CommentRow: View {
    let item: ReplyItemDTO
    let upperMid: Int64
    let isPinned: Bool
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
                    Label(BiliFormat.compactCount(item.like), systemImage: "hand.thumbsup")
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

/// Picture attachment grid for a reply. 1 → wide, 2 → side-by-side,
/// 3+ → 3-column. Each tile uses `RemoteImage` so re-scrolling doesn't
/// re-fetch.
struct ReplyPictureGrid: View {
    let urls: [String]

    var body: some View {
        let cols = urls.count == 1 ? 1 : (urls.count == 2 ? 2 : 3)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: cols)
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(urls.enumerated()), id: \.offset) { _, u in
                GeometryReader { geo in
                    RemoteImage(url: u,
                                contentMode: .fill,
                                targetPointSize: CGSize(width: geo.size.width, height: geo.size.width),
                                quality: 75)
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
    }
}
