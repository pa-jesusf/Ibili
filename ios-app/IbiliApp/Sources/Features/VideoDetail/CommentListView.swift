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
    private let usesVirtualizedList: Bool
    private let bottomContentInset: CGFloat
    private let onScrollOffsetChange: ((CGFloat) -> Void)?
    @State private var thread: ReplyItemDTO?
    @State private var composer: CommentComposerContext?
    @State private var userSpaceMID: Int64?
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation

    init(oid: Int64,
         kind: Int32 = 1,
         viewModel: CommentListViewModel? = nil,
         usesVirtualizedList: Bool = false,
         bottomContentInset: CGFloat = 24,
         onScrollOffsetChange: ((CGFloat) -> Void)? = nil) {
        self.oid = oid
        self.kind = kind
        self.providedViewModel = viewModel
        self.usesVirtualizedList = usesVirtualizedList
        self.bottomContentInset = bottomContentInset
        self.onScrollOffsetChange = onScrollOffsetChange
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
                    onOpenUser: openUserSpace,
                    usesVirtualizedList: usesVirtualizedList,
                    bottomContentInset: bottomContentInset,
                    onScrollOffsetChange: onScrollOffsetChange
                )
            } else {
                CommentListContent(
                    oid: oid,
                    kind: kind,
                    viewModel: ownedViewModel,
                    thread: $thread,
                    onCompose: { composer = .topLevel },
                    onReply: { root, parent in composer = .reply(root: root, parent: parent) },
                    onOpenUser: openUserSpace,
                    usesVirtualizedList: usesVirtualizedList,
                    bottomContentInset: bottomContentInset,
                    onScrollOffsetChange: onScrollOffsetChange
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
    let usesVirtualizedList: Bool
    let bottomContentInset: CGFloat
    let onScrollOffsetChange: ((CGFloat) -> Void)?
    @EnvironmentObject private var session: AppSession

    var body: some View {
        Group {
            if usesVirtualizedList {
                virtualizedContent
            } else {
                legacyContent
            }
        }
        .onAppear {
            viewModel.bind(oid: oid, kind: kind)
            prefetchCommentAvatars()
        }
        .onChange(of: oid) { newValue in
            viewModel.bind(oid: newValue, kind: kind)
        }
        .onChange(of: kind) { newValue in
            viewModel.bind(oid: oid, kind: newValue)
        }
        .onChange(of: viewModel.items.count) { _ in
            prefetchCommentAvatars()
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var virtualizedContent: some View {
        CommentCollectionView(
            rows: commentRows,
            upperMid: viewModel.upperMid,
            isLoggedIn: session.isLoggedIn,
            isLoading: viewModel.isLoading,
            onSetSort: { viewModel.sort = $0 },
            onCompose: { if session.isLoggedIn { onCompose() } },
            onLike: { item in Task { await viewModel.toggleLike(rpid: item.rpid) } },
            onReply: { root, parent in
                if session.isLoggedIn {
                    onReply(root, parent)
                }
            },
            onOpenUser: onOpenUser,
            onOpenThread: { thread = $0 },
            onReachEnd: { Task { await viewModel.loadMore() } },
            onRefresh: { Task { await viewModel.refresh(oid: oid, kind: kind) } },
            bottomContentInset: bottomContentInset,
            onScrollOffsetChange: { onScrollOffsetChange?($0) }
        )
    }

    private var legacyContent: some View {
        let prefetchTriggerID = viewModel.prefetchTriggerID
        return LazyVStack(alignment: .leading, spacing: 0) {
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
                        if item.rpid == prefetchTriggerID {
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
    }

    private var commentRows: [CommentCollectionRow] {
        var rows: [CommentCollectionRow] = [
            .header(total: viewModel.total, sort: viewModel.sort),
            .composer(isLoggedIn: session.isLoggedIn),
        ]
        if let top = viewModel.top {
            rows.append(.pinned(top))
        }
        rows.append(contentsOf: viewModel.items.map { .comment($0) })
        if viewModel.isLoading {
            rows.append(.loading)
        } else if viewModel.isEnd, !viewModel.items.isEmpty {
            rows.append(.end)
        } else if viewModel.items.isEmpty {
            rows.append(.empty)
        }
        return rows
    }

    private func prefetchCommentAvatars() {
        var urls: [String] = []
        if let face = viewModel.top?.face, !face.isEmpty {
            urls.append(face)
        }
        urls.append(contentsOf: viewModel.items.suffix(24).map(\.face).filter { !$0.isEmpty })
        guard !urls.isEmpty else { return }
        CoverImagePrefetcher.shared.prefetch(
            urls,
            targetPointSize: CGSize(width: 64, height: 64),
            quality: 75
        )
    }
}

private enum CommentCollectionRow: Hashable, Identifiable {
    case header(total: Int64, sort: Int32)
    case composer(isLoggedIn: Bool)
    case pinned(ReplyItemDTO)
    case comment(ReplyItemDTO)
    case loading
    case end
    case empty

    var id: String {
        switch self {
        case .header:
            return "header"
        case .composer:
            return "composer"
        case .pinned(let item):
            return "pinned-\(item.rpid)"
        case .comment(let item):
            return "comment-\(item.rpid)"
        case .loading:
            return "loading"
        case .end:
            return "end"
        case .empty:
            return "empty"
        }
    }

    var replyItem: ReplyItemDTO? {
        switch self {
        case .pinned(let item), .comment(let item):
            return item
        default:
            return nil
        }
    }
}

private struct CommentCollectionView: UIViewRepresentable {
    let rows: [CommentCollectionRow]
    let upperMid: Int64
    let isLoggedIn: Bool
    let isLoading: Bool
    let onSetSort: (Int32) -> Void
    let onCompose: () -> Void
    let onLike: (ReplyItemDTO) -> Void
    let onReply: (ReplyItemDTO, ReplyItemDTO) -> Void
    let onOpenUser: (Int64) -> Void
    let onOpenThread: (ReplyItemDTO) -> Void
    let onReachEnd: () -> Void
    let onRefresh: () -> Void
    let bottomContentInset: CGFloat
    let onScrollOffsetChange: (CGFloat) -> Void

    @EnvironmentObject var settings: AppSettings
    @Environment(\.commentViewportHeight) var commentViewportHeight

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 12, left: 16, bottom: max(24, bottomContentInset), right: 16)
        layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = context.coordinator
        collectionView.dataSource = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        collectionView.keyboardDismissMode = .interactive
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: CommentCollectionCoordinator.cellID)
        collectionView.refreshControl = context.coordinator.makeRefreshControl()
        context.coordinator.collectionView = collectionView
        context.coordinator.apply(parent: self, forceReload: true)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout,
           abs(layout.sectionInset.bottom - max(24, bottomContentInset)) > 0.5 {
            layout.sectionInset.bottom = max(24, bottomContentInset)
            layout.invalidateLayout()
        }
        context.coordinator.apply(parent: self, forceReload: false)
        if !isLoading {
            collectionView.refreshControl?.endRefreshing()
        }
    }

    func makeCoordinator() -> CommentCollectionCoordinator {
        CommentCollectionCoordinator(parent: self)
    }
}

private final class CommentCollectionCoordinator: NSObject,
                                                  UICollectionViewDataSource,
                                                  UICollectionViewDelegateFlowLayout,
                                                  UICollectionViewDataSourcePrefetching {
    static let cellID = "CommentCollectionCell"

    private var parent: CommentCollectionView
    private var rows: [CommentCollectionRow] = []
    private var lastWidth: CGFloat = 0
    weak var collectionView: UICollectionView?

    init(parent: CommentCollectionView) {
        self.parent = parent
        self.rows = parent.rows
    }

    func makeRefreshControl() -> UIRefreshControl {
        let refresh = UIRefreshControl()
        refresh.tintColor = UIColor(IbiliTheme.accent)
        refresh.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        return refresh
    }

    func apply(parent: CommentCollectionView, forceReload: Bool) {
        self.parent = parent
        let newRows = parent.rows
        guard forceReload || newRows != rows || abs((collectionView?.bounds.width ?? 0) - lastWidth) > 0.5 else { return }
        rows = newRows
        lastWidth = collectionView?.bounds.width ?? 0
        collectionView?.reloadData()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.cellID, for: indexPath)
        guard rows.indices.contains(indexPath.item) else { return cell }
        let row = rows[indexPath.item]
        let width = max(1, collectionView.bounds.width - collectionView.adjustedContentInset.left - collectionView.adjustedContentInset.right - 32)
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.contentConfiguration = UIHostingConfiguration {
            CommentCollectionRowView(
                row: row,
                upperMid: parent.upperMid,
                isLoggedIn: parent.isLoggedIn,
                onSetSort: parent.onSetSort,
                onCompose: parent.onCompose,
                onLike: parent.onLike,
                onReply: parent.onReply,
                onOpenUser: parent.onOpenUser,
                onOpenThread: parent.onOpenThread
            )
            .environmentObject(parent.settings)
            .environment(\.commentContentWidth, width)
            .environment(\.commentViewportHeight, parent.commentViewportHeight)
            .frame(width: width, alignment: .topLeading)
        }
        .margins(.all, 0)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard rows.count > 4, indexPath.item >= rows.count - 4 else { return }
        parent.onReachEnd()
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let avatarURLs = indexPaths.compactMap { indexPath -> String? in
            guard rows.indices.contains(indexPath.item),
                  let face = rows[indexPath.item].replyItem?.face,
                  !face.isEmpty else { return nil }
            return face
        }
        guard !avatarURLs.isEmpty else { return }
        CoverImagePrefetcher.shared.prefetch(
            avatarURLs,
            targetPointSize: CGSize(width: 64, height: 64),
            quality: 75
        )
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {}

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        parent.onScrollOffsetChange(scrollView.contentOffset.y)
    }

    @objc private func refreshPulled() {
        parent.onRefresh()
    }
}

private struct CommentCollectionRowView: View {
    let row: CommentCollectionRow
    let upperMid: Int64
    let isLoggedIn: Bool
    let onSetSort: (Int32) -> Void
    let onCompose: () -> Void
    let onLike: (ReplyItemDTO) -> Void
    let onReply: (ReplyItemDTO, ReplyItemDTO) -> Void
    let onOpenUser: (Int64) -> Void
    let onOpenThread: (ReplyItemDTO) -> Void

    var body: some View {
        switch row {
        case .header(let total, let sort):
            HStack {
                Text("评论")
                    .font(.headline)
                Text("\(total)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(IbiliTheme.textSecondary)
                Spacer()
                Menu {
                    Button { onSetSort(1) } label: {
                        Label("热门", systemImage: sort == 1 ? "checkmark" : "")
                    }
                    Button { onSetSort(2) } label: {
                        Label("时间", systemImage: sort == 2 ? "checkmark" : "")
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(sort == 1 ? "热门" : "时间")
                        Image(systemName: "chevron.down").imageScale(.small)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(IbiliTheme.textSecondary)
                }
            }
            .padding(.bottom, 8)

        case .composer(let isLoggedIn):
            Button {
                if isLoggedIn { onCompose() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .imageScale(.small)
                        .foregroundStyle(IbiliTheme.accent)
                    Text(isLoggedIn ? "发条友善的评论…" : "登录后即可发表评论")
                        .font(.footnote)
                        .foregroundStyle(IbiliTheme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Capsule().fill(IbiliTheme.surface))
            }
            .buttonStyle(.plain)
            .disabled(!isLoggedIn)
            .padding(.bottom, 12)

        case .pinned(let item):
            VStack(spacing: 0) {
                CommentRow(
                    item: item,
                    upperMid: upperMid,
                    isPinned: true,
                    onLike: { onLike(item) },
                    onReply: isLoggedIn ? { onReply(item, item) } : nil,
                    onOpenUser: onOpenUser,
                    onOpenThread: { onOpenThread(item) }
                )
                Divider()
            }

        case .comment(let item):
            VStack(spacing: 0) {
                CommentRow(
                    item: item,
                    upperMid: upperMid,
                    isPinned: false,
                    onLike: { onLike(item) },
                    onReply: isLoggedIn ? { onReply(item, item) } : nil,
                    onOpenUser: onOpenUser,
                    onOpenThread: { onOpenThread(item) }
                )
                Divider()
            }

        case .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 12)

        case .end:
            HStack {
                Spacer()
                Text("已经到底了")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 12)

        case .empty:
            emptyState(title: "暂无评论", symbol: "bubble.left.and.bubble.right")
                .padding(.vertical, 30)
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
                              onTruncationChange: { truncated in
                                  if isMessageTruncated != truncated {
                                      isMessageTruncated = truncated
                                  }
                              })
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
