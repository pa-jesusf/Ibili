import SwiftUI
import UIKit

// MARK: - Common helpers

/// Cards in the dynamic feed live inside a `LazyVStack` with 12 pt
/// horizontal insets, and the cards themselves carry 14 pt internal
/// padding. We compute the resulting content width once so image
/// fetches request the right pixel budget instead of pulling 4K
/// originals for a 360-pt-wide card.
enum DynamicLayout {
    static let outerPad: CGFloat = 12
    static let cardPad: CGFloat = 14
    static var contentWidth: CGFloat {
        UIScreen.main.bounds.width - 2 * outerPad - 2 * cardPad
    }
}

// MARK: - Tap routing

/// Centralised classification of a dynamic into a navigation action.
/// Keeping this here means the feed and the detail page agree on what
/// "card tap" should do.
enum DynamicTapAction {
    /// Pure video uploads: jump straight to the player overlay.
    case playVideo(aid: Int64, bvid: String, title: String, cover: String)
    /// Anything else (image post / forward / article / live / word):
    /// open the secondary detail page so the user can read the full
    /// text, browse images, and engage with the comment thread.
    case openDetail
}

private func classify(_ item: DynamicItemDTO) -> DynamicTapAction {
    if item.kind == .video, let v = item.video, !(v.bvid.isEmpty && v.aid == 0) {
        return .playVideo(aid: v.aid, bvid: v.bvid, title: v.title, cover: v.cover)
    }
    return .openDetail
}

@MainActor
private func openVideo(_ router: DeepLinkRouter, aid: Int64, bvid: String, title: String, cover: String) {
    router.open(FeedItemDTO(
        aid: aid, bvid: bvid, cid: 0,
        title: title, cover: cover, author: "",
        durationSec: 0, play: 0, danmaku: 0
    ))
}

// MARK: - Feed root

struct DynamicFeedView: View {
    @StateObject private var vm = DynamicFeedViewModel()
    @EnvironmentObject private var router: DeepLinkRouter

    var body: some View {
        Group {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty {
                emptyState(title: "暂无动态", symbol: "sparkles",
                           message: "关注一些 UP 主之后再回来看看")
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                            DynamicItemCard(item: item)
                                .onAppear {
                                    if !vm.isEnd, index >= max(0, vm.items.count - 3) {
                                        Task { await vm.loadMore() }
                                    }
                                }
                        }
                        if vm.isLoading { ProgressView().padding() }
                        else if vm.isEnd { Text("已经到底了").font(.caption).foregroundStyle(.secondary).padding() }
                    }
                    .padding(.horizontal, DynamicLayout.outerPad)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
        }
        .background(IbiliTheme.background)
        .scrollContentBackground(.hidden)
        .task { await vm.loadInitial() }
        .refreshable { await vm.loadInitial(force: true) }
    }
}

// MARK: - Card

struct DynamicItemCard: View {
    let item: DynamicItemDTO
    /// When non-nil, video taps inside the card route through this
    /// closure instead of the global player overlay (`router.pending`).
    /// The user-space page wires this up so video taps push a
    /// `PlayerView` onto its own NavigationStack rather than blowing
    /// away the stack via the deep-link router.
    var onOpenVideo: ((FeedItemDTO) -> Void)? = nil
    /// When non-nil, taps that would open the dynamic detail view
    /// notify the parent instead of using an internal NavigationLink.
    /// Hoisting the navigation state out of the lazy stack avoids a
    /// well-known SwiftUI bug: a hidden `NavigationLink(isActive:)`
    /// living inside a `LazyVStack` cell can have its `isActive`
    /// flicker back to `false` when the cell scrolls off-screen
    /// (`@State` lifecycle resets on cell teardown), which collapses
    /// every push above it — manifesting as "tap dynamic → back jumps
    /// straight to the root tab".
    var onOpenDetail: ((DynamicItemDTO) -> Void)? = nil
    @EnvironmentObject private var router: DeepLinkRouter
    @State private var preview: ImagePreviewState?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DynamicHeader(author: item.author)

            if !item.text.isEmpty {
                Text(item.text)
                    .font(.callout)
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(8)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            DynamicBody(
                item: convertToRef(item),
                kind: item.kind,
                contentWidth: DynamicLayout.contentWidth,
                onPlayVideo: openCardVideo,
                onTapImage: { idx in preview = ImagePreviewState(urls: item.images.map(\.url), index: idx) }
            )

            if let orig = item.orig {
                DynamicForwardPanel(
                    orig: orig,
                    contentWidth: DynamicLayout.contentWidth - 20,
                    onPlayVideo: openOrigVideo,
                    onTapImage: { idx in preview = ImagePreviewState(urls: orig.images.map(\.url), index: idx) },
                    onOpenOrigDetail: openOrigDetail
                )
            }

            DynamicStatBar(stat: item.stat)
        }
        .padding(DynamicLayout.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(IbiliTheme.surface)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { handleCardTap() }
        .background(
            // Hidden NavigationLink driven by `pendingDetail`. Going
            // through this rather than `NavigationLink(value:)` keeps
            // tap routing centralized in `handleCardTap`.
            NavigationLink(
                isActive: Binding(
                    get: { pendingDetail != nil },
                    set: { if !$0 { pendingDetail = nil } }
                ),
                destination: {
                    if let d = pendingDetail { DynamicDetailView(item: d) }
                },
                label: { EmptyView() }
            )
            .opacity(0)
        )
        .fullScreenCover(item: $preview) { state in
            ImagePreviewSheet(urls: state.urls, initialIndex: state.index)
        }
    }

    @State private var pendingDetail: DynamicItemDTO?

    private func handleCardTap() {
        switch classify(item) {
        case .playVideo(let aid, let bvid, let title, let cover):
            let dto = FeedItemDTO(
                aid: aid, bvid: bvid, cid: 0,
                title: title, cover: cover, author: "",
                durationSec: 0, play: 0, danmaku: 0
            )
            if let onOpenVideo { onOpenVideo(dto) }
            else { router.open(dto) }
        case .openDetail:
            if let onOpenDetail { onOpenDetail(item) }
            else { pendingDetail = item }
        }
    }

    private func openCardVideo() {
        guard let v = item.video else { return }
        if let onOpenVideo {
            onOpenVideo(FeedItemDTO(aid: v.aid, bvid: v.bvid, cid: 0,
                                    title: v.title, cover: v.cover, author: "",
                                    durationSec: 0, play: 0, danmaku: 0))
        } else {
            openVideo(router, aid: v.aid, bvid: v.bvid, title: v.title, cover: v.cover)
        }
    }

    private func openOrigVideo() {
        guard let v = item.orig?.video else { return }
        if let onOpenVideo {
            onOpenVideo(FeedItemDTO(aid: v.aid, bvid: v.bvid, cid: 0,
                                    title: v.title, cover: v.cover, author: "",
                                    durationSec: 0, play: 0, danmaku: 0))
        } else {
            openVideo(router, aid: v.aid, bvid: v.bvid, title: v.title, cover: v.cover)
        }
    }

    private func openOrigDetail() {
        if let onOpenDetail { onOpenDetail(item) }
        else { pendingDetail = item }
    }

    private func convertToRef(_ item: DynamicItemDTO) -> DynamicItemRefDTO {
        DynamicItemRefDTO(
            idStr: item.idStr, kind: item.kind, author: item.author,
            stat: item.stat, text: item.text,
            video: item.video, images: item.images
        )
    }
}

private struct ImagePreviewState: Identifiable {
    let id = UUID()
    let urls: [String]
    let index: Int
}

// MARK: - Header

private struct DynamicHeader: View {
    let author: DynamicAuthorDTO

    var body: some View {
        // Wrap the avatar+name+pubLabel in a real `NavigationLink`
        // so the push state lives in the parent NavigationStack,
        // not in a per-cell `@State`. The previous `@State pushSpace`
        // approach reset to `false` every time the lazy cell got
        // recycled, which broke the back-stack ("tap dynamic in user
        // space → back" jumped straight to the tab root).
        NavigationLink {
            UserSpaceView(mid: author.mid)
        } label: {
            HStack(spacing: 10) {
                RemoteImage(url: author.face,
                            contentMode: .fill,
                            targetPointSize: CGSize(width: 36, height: 36),
                            quality: 75)
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(author.name).font(.subheadline.weight(.medium))
                        .foregroundStyle(IbiliTheme.textPrimary)
                        .lineLimit(1)
                    if !author.pubLabel.isEmpty {
                        Text(author.pubLabel)
                            .font(.caption2)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(author.mid <= 0)
    }
}

// MARK: - Body

private struct DynamicBody: View {
    let item: DynamicItemRefDTO
    let kind: DynamicKindDTO
    let contentWidth: CGFloat
    let onPlayVideo: () -> Void
    let onTapImage: (Int) -> Void

    var body: some View {
        switch kind {
        case .video, .pgc, .live:
            if let v = item.video {
                DynamicVideoTile(video: v, contentWidth: contentWidth, isLive: kind == .live)
                    .onTapGesture { onPlayVideo() }
            }
        case .draw:
            DynamicImagesGrid(images: item.images, contentWidth: contentWidth, onTap: onTapImage)
        case .article:
            if let v = item.video {
                ArticleBanner(cover: v.cover, title: v.title, contentWidth: contentWidth)
            }
        case .word, .forward, .unsupported:
            EmptyView()
        }
    }
}

private struct DynamicVideoTile: View {
    let video: DynamicVideoDTO
    let contentWidth: CGFloat
    var isLive: Bool = false

    var body: some View {
        let h = max(1, contentWidth * 9 / 16)
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: video.cover,
                        contentMode: .fill,
                        targetPointSize: CGSize(width: contentWidth, height: h),
                        quality: 80)
                .frame(width: contentWidth, height: h)
                .clipped()
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.55)],
                startPoint: .center, endPoint: .bottom
            )
            .frame(width: contentWidth, height: h)
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if !video.statLabel.isEmpty {
                        Text(video.statLabel)
                    }
                    Spacer(minLength: 0)
                    if !video.durationLabel.isEmpty {
                        Text(video.durationLabel)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(.black.opacity(0.5)))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(10)
            .frame(width: contentWidth, alignment: .leading)
            // Top-left LIVE badge for live-room rcmd cards.
            if isLive {
                HStack {
                    Text("LIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(IbiliTheme.accent))
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(width: contentWidth, height: h, alignment: .topLeading)
            }
        }
        .frame(width: contentWidth, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ArticleBanner: View {
    let cover: String
    let title: String
    let contentWidth: CGFloat

    var body: some View {
        let h = max(1, contentWidth * 9 / 16)
        VStack(alignment: .leading, spacing: 6) {
            if !cover.isEmpty {
                RemoteImage(url: cover, contentMode: .fill,
                            targetPointSize: CGSize(width: contentWidth, height: h), quality: 80)
                    .frame(width: contentWidth, height: h)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
            }
        }
        .frame(width: contentWidth, alignment: .leading)
    }
}

private struct DynamicImagesGrid: View {
    let images: [DynamicImageDTO]
    let contentWidth: CGFloat
    let onTap: (Int) -> Void

    var body: some View {
        let count = images.count
        if count == 0 {
            EmptyView()
        } else if count == 1 {
            singleImage(images[0])
        } else {
            // 2 / 4 → 2-col grid (matches Bilibili layout heuristic),
            // anything else → 3-col. Cells stay square so heights are
            // predictable and the grid never overflows the card.
            let cols = (count == 2 || count == 4) ? 2 : 3
            let spacing: CGFloat = 4
            let cell = (contentWidth - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let layout = Array(repeating: GridItem(.fixed(cell), spacing: spacing), count: cols)
            LazyVGrid(columns: layout, alignment: .leading, spacing: spacing) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                    // Constrain hit-testing to exactly the rendered
                    // square — without `.contentShape` SwiftUI hands
                    // the grid cell's full slack region to whichever
                    // Button it lays out first, which is why a 2-img
                    // post used to register taps far past the visual
                    // boundary of the left image.
                    RemoteImage(url: img.url, contentMode: .fill,
                                targetPointSize: CGSize(width: cell, height: cell), quality: 75)
                        .frame(width: cell, height: cell)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { onTap(idx) }
                }
            }
            .frame(width: contentWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private func singleImage(_ img: DynamicImageDTO) -> some View {
        // Clamp tall portraits / extreme landscapes so a single post
        // can't push subsequent cards off-screen. 0.66 × W is a touch
        // taller than 1:1 (Twitter-style); 1.6 × W ≈ 16:10 landscape.
        let aspect: CGFloat = {
            guard img.width > 0, img.height > 0 else { return 1 }
            let r = CGFloat(img.height) / CGFloat(img.width)
            return min(max(r, 0.5), 1.5)
        }()
        let h = contentWidth * aspect
        RemoteImage(url: img.url, contentMode: .fill,
                    targetPointSize: CGSize(width: contentWidth, height: h), quality: 80)
            .frame(width: contentWidth, height: h)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { onTap(0) }
    }
}

// MARK: - Forward panel

private struct DynamicForwardPanel: View {
    let orig: DynamicItemRefDTO
    let contentWidth: CGFloat
    let onPlayVideo: () -> Void
    let onTapImage: (Int) -> Void
    let onOpenOrigDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onOpenOrigDetail()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.up.right")
                    Text("@\(orig.author.name)")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(IbiliTheme.textSecondary)
            }
            .buttonStyle(.plain)

            if !orig.text.isEmpty {
                Text(orig.text)
                    .font(.footnote)
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DynamicBody(item: orig, kind: orig.kind,
                        contentWidth: contentWidth,
                        onPlayVideo: onPlayVideo,
                        onTapImage: onTapImage)

            if orig.kind == .unsupported {
                Text("暂不支持此类内容")
                    .font(.caption2)
                    .foregroundStyle(IbiliTheme.textSecondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.15))
        )
    }
}

// MARK: - Stat bar

private struct DynamicStatBar: View {
    let stat: DynamicStatDTO

    var body: some View {
        HStack(spacing: 24) {
            statItem(symbol: "arrowshape.turn.up.right", value: stat.forward)
            statItem(symbol: "bubble.left", value: stat.comment)
            statItem(symbol: "hand.thumbsup", value: stat.like)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(IbiliTheme.textSecondary)
    }

    private func statItem(symbol: String, value: Int64) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(value > 0 ? BiliFormat.compactCount(value) : "—")
        }
    }
}

// MARK: - VM

@MainActor
final class DynamicFeedViewModel: ObservableObject {
    @Published var items: [DynamicItemDTO] = []
    @Published var isLoading = false
    @Published var isEnd = false
    private var offset: String = ""
    private var page: Int64 = 1

    func loadInitial(force: Bool = false) async {
        if !force && !items.isEmpty { return }
        items = []
        offset = ""
        page = 1
        isEnd = false
        await fetch()
    }

    func loadMore() async {
        guard !isLoading, !isEnd else { return }
        await fetch()
    }

    private func fetch() async {
        isLoading = true
        let p = page, off = offset
        let result: DynamicFeedPageDTO? = await Task.detached {
            try? CoreClient.shared.dynamicFeed(feedType: "all", page: p, offset: off)
        }.value
        isLoading = false
        guard let result else { isEnd = true; return }
        let existing = Set(items.map { $0.idStr })
        let fresh = result.items.filter { !existing.contains($0.idStr) }
        items.append(contentsOf: fresh)
        offset = result.offset
        page += 1
        if !result.hasMore || fresh.isEmpty { isEnd = true }
    }
}
