import SwiftUI

extension EnvironmentValues {
    var commentViewportHeight: CGFloat? {
        get { self[CommentViewportHeightKey.self] }
        set { self[CommentViewportHeightKey.self] = newValue }
    }

    var commentContentWidth: CGFloat? {
        get { self[CommentContentWidthKey.self] }
        set { self[CommentContentWidthKey.self] = newValue }
    }
}

private struct CommentViewportHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct CommentContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct CommentComposerContext: Identifiable {
    let id = UUID()
    let root: ReplyItemDTO?
    let parent: ReplyItemDTO?

    static var topLevel: CommentComposerContext {
        CommentComposerContext(root: nil, parent: nil)
    }

    static func reply(root: ReplyItemDTO, parent: ReplyItemDTO) -> CommentComposerContext {
        CommentComposerContext(root: root, parent: parent)
    }
}

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
    @State private var composer: CommentComposerContext?
    @State private var userSpaceMID: Int64?
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation

    init(oid: Int64,
         kind: Int32 = 1,
         viewModel: CommentListViewModel? = nil) {
        self.oid = oid
        self.kind = kind
        self.providedViewModel = viewModel
    }

    private var currentViewModel: CommentListViewModel {
        providedViewModel ?? ownedViewModel
    }

    var body: some View {
        Group {
            if let providedViewModel {
                CommentListContent(
                    oid: oid,
                    kind: kind,
                    viewModel: providedViewModel,
                    thread: $thread,
                    onCompose: { composer = .topLevel },
                    onReply: { root, parent in composer = .reply(root: root, parent: parent) },
                    onOpenUser: openUserSpace
                )
            } else {
                CommentListContent(
                    oid: oid,
                    kind: kind,
                    viewModel: ownedViewModel,
                    thread: $thread,
                    onCompose: { composer = .topLevel },
                    onReply: { root, parent in composer = .reply(root: root, parent: parent) },
                    onOpenUser: openUserSpace
                )
            }
        }
        .sheet(item: $thread) { root in
            CommentThreadSheet(
                root: root,
                kind: kind,
                upperMid: currentViewModel.upperMid,
                onOpenUser: { mid in
                    thread = nil
                    DispatchQueue.main.async {
                        openUserSpace(mid: mid)
                    }
                },
                onLocalReply: { echo, rootRpid in
                    currentViewModel.noteLocalReply(echo, underRoot: rootRpid)
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $composer) { context in
            CommentSendSheet(
                oid: oid,
                kind: kind,
                selfMid: session.mid,
                selfName: "",
                root: context.root?.rpid ?? 0,
                parent: context.parent?.rpid ?? 0,
                replyToName: context.parent?.uname
            ) { echo in
                if let root = context.root {
                    currentViewModel.noteLocalReply(echo, underRoot: root.rpid)
                } else {
                    currentViewModel.prependLocal(echo)
                }
            }
        }
        .background {
            if !isInPlayerHostNavigation {
                NavigationLink(
                    isActive: Binding(
                        get: { userSpaceMID != nil },
                        set: { if !$0 { userSpaceMID = nil } }
                    ),
                    destination: {
                        if let mid = userSpaceMID {
                            UserSpaceView(mid: mid)
                        }
                    },
                    label: { EmptyView() }
                )
                .opacity(0)
                .allowsHitTesting(false)
            }
        }
    }

    private func openUserSpace(mid: Int64) {
        guard mid > 0 else { return }
        if isInPlayerHostNavigation {
            router.openUserSpace(mid: mid)
        } else {
            userSpaceMID = mid
        }
    }
}

private struct CommentListContent: View {
    let oid: Int64
    let kind: Int32
    @ObservedObject var viewModel: CommentListViewModel
    @Binding var thread: ReplyItemDTO?
    let onCompose: () -> Void
    let onReply: (ReplyItemDTO, ReplyItemDTO) -> Void
    let onOpenUser: (Int64) -> Void
    @EnvironmentObject private var session: AppSession

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("评论")
                    .font(.headline)
                Text("\(viewModel.total)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(IbiliTheme.textSecondary)
                Spacer()
                Menu {
                    Button { viewModel.sort = 1 } label: {
                        Label("热门", systemImage: viewModel.sort == 1 ? "checkmark" : "")
                    }
                    Button { viewModel.sort = 2 } label: {
                        Label("时间", systemImage: viewModel.sort == 2 ? "checkmark" : "")
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(viewModel.sort == 1 ? "热门" : "时间")
                        Image(systemName: "chevron.down").imageScale(.small)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(IbiliTheme.textSecondary)
                }
            }
            .padding(.bottom, 8)

            Button {
                if session.isLoggedIn { onCompose() }
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

            if let top = viewModel.top {
                CommentRow(item: top, upperMid: viewModel.upperMid, isPinned: true,
                           onLike: { Task { await viewModel.toggleLike(rpid: top.rpid) } },
                           onReply: session.isLoggedIn ? { onReply(top, top) } : nil,
                           onOpenUser: onOpenUser) { thread = top }
                Divider()
            }

            ForEach(viewModel.items) { item in
                CommentRow(item: item, upperMid: viewModel.upperMid, isPinned: false,
                           onLike: { Task { await viewModel.toggleLike(rpid: item.rpid) } },
                           onReply: session.isLoggedIn ? { onReply(item, item) } : nil,
                           onOpenUser: onOpenUser) { thread = item }
                    .onAppear {
                        if item.id == viewModel.items.last?.id, !viewModel.isEnd {
                            Task { await viewModel.loadMore() }
                        }
                    }
                Divider()
            }

            if viewModel.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 12)
            } else if viewModel.isEnd, !viewModel.items.isEmpty {
                HStack { Spacer(); Text("已经到底了").font(.caption).foregroundStyle(.secondary); Spacer() }
                    .padding(.vertical, 12)
            } else if viewModel.items.isEmpty, !viewModel.isLoading {
                emptyState(title: "暂无评论", symbol: "bubble.left.and.bubble.right")
                    .padding(.vertical, 30)
            }
        }
        .onAppear {
            viewModel.bind(oid: oid, kind: kind)
        }
        .onChange(of: oid) { newValue in
            viewModel.bind(oid: newValue, kind: kind)
        }
        .onChange(of: kind) { newValue in
            viewModel.bind(oid: oid, kind: newValue)
        }
    }
}

/// One row in the comment list. Clamped to 6 lines; tapping opens the
/// thread sheet for full replies.
struct CommentRow: View {
    let item: ReplyItemDTO
    let upperMid: Int64
    let isPinned: Bool
    var messageLineLimit: Int? = 6
    var allowsThreadPresentation: Bool = true
    var showsPreviewReplies: Bool = true
    var onLike: (() -> Void)? = nil
    var onReply: (() -> Void)? = nil
    var onOpenUser: ((Int64) -> Void)? = nil
    let onOpenThread: () -> Void

    @State private var isMessageTruncated = false
    @EnvironmentObject private var settings: AppSettings

    private var canOpenThread: Bool {
        allowsThreadPresentation && (item.replyCount > 0 || isMessageTruncated)
    }

    private var shouldShowReplyBox: Bool {
        showsPreviewReplies && item.replyCount > 0
    }

    private var previewReplies: [ReplyItemDTO] {
        guard settings.commentShowPreviewReplies else { return [] }
        return Array(item.previewReplies.prefix(3))
    }

    private var displayLocation: String {
        CommentLocationFormatter.displayText(item.location)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 5) {
                Button {
                    onOpenUser?(item.mid)
                } label: {
                    RemoteImage(url: item.face,
                                targetPointSize: CGSize(width: 32, height: 32),
                                quality: 75)
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(item.mid <= 0 || onOpenUser == nil)

                if settings.commentShowLevel, item.level > 0 {
                    CommentLevelBadge(level: item.level)
                }
            }
            .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.uname)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(item.mid == upperMid ? IbiliTheme.accent : IbiliTheme.textPrimary)
                    if settings.commentShowUPBadge, upperMid > 0, item.mid == upperMid {
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
                HStack(spacing: 4) {
                    if item.ctime > 0 {
                        Text(BiliFormat.relativeDate(item.ctime))
                    }
                    if settings.commentShowLocation, !displayLocation.isEmpty {
                        Text("· \(displayLocation)")
                    }
                    if settings.commentShowUPBadge, item.upActionLike {
                        Text("· UP主赞过")
                    }
                    if settings.commentShowUPBadge, item.upActionReply {
                        Text("· UP主回复过")
                    }
                }
                .font(.caption2)
                .foregroundStyle(IbiliTheme.textSecondary)
                .lineLimit(1)
                RichReplyText(message: item.message,
                              emotes: item.emotes,
                              jumpUrls: item.jumpUrls,
                              lineLimit: messageLineLimit,
                              font: .footnote,
                              textColor: IbiliTheme.textPrimary,
                              onTruncationChange: { isMessageTruncated = $0 })
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
                    if let onReply {
                        Button {
                            onReply()
                        } label: {
                            Label("回复", systemImage: "arrowshape.turn.up.left")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(IbiliTheme.textSecondary)
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(IbiliTheme.textSecondary)

                if shouldShowReplyBox {
                    CommentPreviewReplyBox(
                        root: item,
                        upperMid: upperMid,
                        replies: previewReplies,
                        onOpenThread: onOpenThread,
                        onOpenUser: onOpenUser
                    )
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if canOpenThread { onOpenThread() }
        }
    }
}

private struct CommentLevelBadge: View {
    let level: Int32

    private var style: LevelStyle {
        LevelStyle(level: level)
    }

    var body: some View {
        Text("LV\(min(max(level, 0), 6))")
            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
            .foregroundStyle(style.foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 28, height: 13)
            .background(
                Capsule(style: .continuous)
                    .fill(style.background)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(style.border, lineWidth: 0.6)
                    )
            )
            .shadow(color: style.background.opacity(0.18), radius: 3, x: 0, y: 1)
            .accessibilityLabel("等级\(min(max(level, 0), 6))")
    }

    private struct LevelStyle {
        let foreground: Color
        let background: Color
        let border: Color

        init(level: Int32) {
            switch level {
            case 6...:
                foreground = .white
                background = Color(red: 0.95, green: 0.25, blue: 0.37)
                border = Color(red: 1.0, green: 0.72, blue: 0.78)
            case 5:
                foreground = .white
                background = Color(red: 0.94, green: 0.44, blue: 0.17)
                border = Color(red: 1.0, green: 0.77, blue: 0.48)
            case 4:
                foreground = .white
                background = Color(red: 0.87, green: 0.62, blue: 0.12)
                border = Color(red: 1.0, green: 0.84, blue: 0.42)
            case 3:
                foreground = .white
                background = Color(red: 0.25, green: 0.68, blue: 0.36)
                border = Color(red: 0.63, green: 0.87, blue: 0.56)
            case 2:
                foreground = .white
                background = Color(red: 0.17, green: 0.58, blue: 0.86)
                border = Color(red: 0.55, green: 0.78, blue: 1.0)
            case 1:
                foreground = .white
                background = Color(red: 0.45, green: 0.50, blue: 0.62)
                border = Color(red: 0.70, green: 0.74, blue: 0.84)
            default:
                foreground = IbiliTheme.textSecondary
                background = Color(.tertiarySystemFill)
                border = Color(.separator).opacity(0.35)
            }
        }
    }
}

private enum CommentLocationFormatter {
    static func displayText(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["IP属地：", "IP属地:", "IP属地 ", "IP 属地：", "IP 属地:"]
        var didStrip = true
        while didStrip {
            didStrip = false
            for prefix in prefixes where text.hasPrefix(prefix) {
                text.removeFirst(prefix.count)
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                didStrip = true
            }
        }
        return text
    }
}

private struct CommentPreviewReplyBox: View {
    let root: ReplyItemDTO
    let upperMid: Int64
    let replies: [ReplyItemDTO]
    let onOpenThread: () -> Void
    var onOpenUser: ((Int64) -> Void)?

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: replies.isEmpty ? 0 : 5) {
            ForEach(replies) { reply in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(reply.uname)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(IbiliTheme.accent)
                            .lineLimit(1)
                            .onTapGesture {
                                if reply.mid > 0 {
                                    onOpenUser?(reply.mid)
                                }
                            }

                        if settings.commentShowUPBadge, upperMid > 0, reply.mid == upperMid {
                            Text("UP")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 0.5)
                                .background(Capsule().fill(IbiliTheme.accent))
                        }
                    }
                    Text("：")
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textPrimary.opacity(0.86))
                    RichReplyText(message: reply.message,
                                  emotes: reply.emotes,
                                  jumpUrls: reply.jumpUrls,
                                  lineLimit: 1,
                                  font: .caption,
                                  textColor: IbiliTheme.textPrimary.opacity(0.86),
                                  onTruncationChange: { _ in })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenThread()
                }
            }

            Button(action: onOpenThread) {
                Text("\(settings.commentShowUPBadge && root.upActionReply ? "UP主等人 " : "")共\(root.replyCount)条回复")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(IbiliTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(IbiliTheme.surface)
        )
    }
}

/// Picture attachment grid for a reply. Capped at 60% of screen width
/// (per design spec) so multi-image attachments don't dominate the row.
/// 1 → single tile, 2 → side-by-side, 3+ → 3-column. Tapping any tile
/// opens `ImagePreviewSheet` with pinch-zoom + save-to-album.
struct ReplyPictureGrid: View {
    private let rawURLs: [String]

    @State private var preview: PreviewSelection?
    @Environment(\.commentViewportHeight) private var commentViewportHeight
    @Environment(\.commentContentWidth) private var commentContentWidth

    init(urls: [String]) {
        rawURLs = urls
    }

    private struct PreviewSelection: Identifiable {
        let id = UUID()
        let index: Int
    }

    var body: some View {
        let availableWidth = stableAvailableWidth
        let metrics = gridMetrics(availableWidth: availableWidth)
        gridContent(availableWidth: availableWidth, metrics: metrics)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: metrics.gridHeight, alignment: .topLeading)
            .fullScreenCover(item: $preview) { sel in
                ImagePreviewSheet(images: previewImages(tileSide: metrics.tileSide), initialIndex: sel.index)
            }
    }

    private var stableAvailableWidth: CGFloat {
        // Parent views provide the comment list's stable width. Subtract the
        // fixed avatar column used by CommentRow so image tiles no longer need
        // their own GeometryReader while scrolling.
        let rowAccessoryWidth: CGFloat = 32 + 10
        let fallback = UIScreen.main.bounds.width - 32
        return max(1, (commentContentWidth ?? fallback) - rowAccessoryWidth)
    }

    private func previewImages(tileSide: CGFloat) -> [CommentImagePreviewItem] {
        rawURLs.map {
            CommentImagePreviewItem(originalURL: $0, cachedThumbnailSide: tileSide)
        }
    }

    private func gridMetrics(availableWidth: CGFloat) -> (tileSide: CGFloat, gridWidth: CGFloat, gridHeight: CGFloat, cols: Int) {
        let cols = rawURLs.count == 1 ? 1 : (rawURLs.count == 2 ? 2 : 3)
        let spacing: CGFloat = 4
        let target = availableWidth * 0.6
        let maxTileSide = availableWidth * 0.3
        let naturalTileSide = (target - CGFloat(cols - 1) * spacing) / CGFloat(cols)
        let rowCount = max(1, Int(ceil(Double(rawURLs.count) / Double(cols))))
        let maxGridHeight = max(48, (commentViewportHeight ?? availableWidth) / 3)
        let maxTileSideByHeight = (maxGridHeight - CGFloat(rowCount - 1) * spacing) / CGFloat(rowCount)
        let tileSide = max(24, min(maxTileSide, naturalTileSide, maxTileSideByHeight))
        let gridWidth = tileSide * CGFloat(cols) + CGFloat(cols - 1) * spacing
        let gridHeight = tileSide * CGFloat(rowCount) + CGFloat(rowCount - 1) * spacing
        return (tileSide, gridWidth, gridHeight, cols)
    }

    private func gridContent(availableWidth: CGFloat,
                             metrics: (tileSide: CGFloat, gridWidth: CGFloat, gridHeight: CGFloat, cols: Int)) -> some View {
        let spacing: CGFloat = 4
        let columns = Array(
            repeating: GridItem(.fixed(metrics.tileSide), spacing: spacing),
            count: metrics.cols
        )
        let images = previewImages(tileSide: metrics.tileSide)
        return HStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, image in
                    Button { preview = .init(index: i) } label: {
                        RemoteImage(url: image.originalURL,
                                    contentMode: .fill,
                                    targetPointSize: CGSize(width: metrics.tileSide, height: metrics.tileSide),
                                    quality: 75)
                            .frame(width: metrics.tileSide, height: metrics.tileSide)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .frame(width: metrics.tileSide, height: metrics.tileSide)
                    .contentShape(ReplyPictureHitShape(inset: 3, cornerRadius: 6))
                    .buttonStyle(.plain)
                }
            }
            .frame(width: min(availableWidth * 0.6, metrics.gridWidth), alignment: .leading)
            Spacer(minLength: 0)
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
