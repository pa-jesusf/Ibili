import SwiftUI

/// 动态 (Dynamic) — Bilibili's user-feed of follow updates.
///
/// The wire feed is heterogeneous: video uploads, image posts, plain
/// text, articles, PGC/anime episode releases, live-room rcmd cards,
/// and "forwards" that wrap one of the above. We flatten this in Rust
/// (`dynamic.rs`) into a uniform `DynamicItemDTO { kind, … }` so the
/// Swift side can switch on `kind` and choose the right body view.
///
/// Layout choices, per the user's "Apple aesthetic" brief:
///   • Each item is a soft-corner card on a quiet background — like
///     iOS Today widgets — rather than a ledger of dense rows.
///   • Author header is uniform: avatar, name, pubLabel.
///   • Body switches:
///       - .video / .pgc / .live  → big cover with title + stats overlay
///       - .draw                  → 1/2/3-column image grid
///       - .word / .article       → text body
///       - .forward               → text + nested original card
///       - .unsupported           → small placeholder strip
///   • Footer stat row mirrors the layout used in the home feed.
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
                    .padding(.horizontal, 12)
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

private struct DynamicItemCard: View {
    let item: DynamicItemDTO
    @EnvironmentObject private var router: DeepLinkRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DynamicHeader(author: item.author)

            if !item.text.isEmpty {
                Text(item.text)
                    .font(.callout)
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(8)
                    .multilineTextAlignment(.leading)
            }

            DynamicBody(item: convertToRef(item), kind: item.kind, embedded: false)
                .onTapGesture { handleTap(kind: item.kind, video: item.video) }

            if let orig = item.orig {
                DynamicForwardPanel(orig: orig)
                    .onTapGesture { handleTap(kind: orig.kind, video: orig.video) }
            }

            DynamicStatBar(stat: item.stat)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(IbiliTheme.surface)
        )
    }

    private func convertToRef(_ item: DynamicItemDTO) -> DynamicItemRefDTO {
        DynamicItemRefDTO(
            idStr: item.idStr, kind: item.kind, author: item.author,
            stat: item.stat, text: item.text,
            video: item.video, images: item.images
        )
    }

    private func handleTap(kind: DynamicKindDTO, video: DynamicVideoDTO?) {
        guard kind == .video, let v = video, !v.bvid.isEmpty || v.aid > 0 else { return }
        router.pending = FeedItemDTO(
            aid: v.aid, bvid: v.bvid, cid: 0,
            title: v.title, cover: v.cover, author: "",
            durationSec: 0, play: 0, danmaku: 0
        )
    }
}

// MARK: - Header

private struct DynamicHeader: View {
    let author: DynamicAuthorDTO

    var body: some View {
        HStack(spacing: 10) {
            RemoteImage(url: author.face,
                        contentMode: .fill,
                        targetPointSize: CGSize(width: 80, height: 80),
                        quality: 75)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(author.name).font(.subheadline.weight(.medium))
                Text(author.pubLabel)
                    .font(.caption2)
                    .foregroundStyle(IbiliTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Body switch

private struct DynamicBody: View {
    let item: DynamicItemRefDTO
    let kind: DynamicKindDTO
    let embedded: Bool

    var body: some View {
        switch kind {
        case .video, .pgc, .live:
            if let v = item.video { DynamicVideoTile(video: v) }
        case .draw:
            DynamicImagesGrid(images: item.images)
        case .article:
            if let v = item.video {
                // For articles the API surfaces a banner image via the
                // `video` slot (cover only, no aid). Render the cover
                // without the play overlay.
                ArticleBanner(cover: v.cover, title: v.title)
            }
        case .word, .forward, .unsupported:
            EmptyView()
        }
    }
}

private struct DynamicVideoTile: View {
    let video: DynamicVideoDTO

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: video.cover,
                        contentMode: .fill,
                        targetPointSize: CGSize(width: 720, height: 405),
                        quality: 80)
                .aspectRatio(16/9, contentMode: .fill)
                .clipped()
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.55)],
                startPoint: .center, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if !video.statLabel.isEmpty {
                        Text(video.statLabel)
                    }
                    if !video.durationLabel.isEmpty {
                        Spacer(minLength: 0)
                        Text(video.durationLabel)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(.black.opacity(0.5)))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ArticleBanner: View {
    let cover: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !cover.isEmpty {
                RemoteImage(url: cover, contentMode: .fill,
                            targetPointSize: CGSize(width: 720, height: 320), quality: 80)
                    .aspectRatio(16/7, contentMode: .fill)
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
    }
}

private struct DynamicImagesGrid: View {
    let images: [DynamicImageDTO]

    var body: some View {
        let count = images.count
        if count == 0 { EmptyView() }
        else if count == 1 {
            singleImage(images[0])
        } else {
            let cols = count <= 4 ? 2 : 3
            let layout = Array(repeating: GridItem(.flexible(), spacing: 4), count: cols)
            LazyVGrid(columns: layout, spacing: 4) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                    RemoteImage(url: img.url, contentMode: .fill,
                                targetPointSize: CGSize(width: 320, height: 320), quality: 75)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private func singleImage(_ img: DynamicImageDTO) -> some View {
        let aspect: CGFloat = {
            guard img.width > 0, img.height > 0 else { return 1 }
            let ratio = CGFloat(img.width) / CGFloat(img.height)
            // Clamp tall-portrait posts so they don't dominate the
            // feed (Twitter-style behaviour).
            return min(max(ratio, 0.66), 1.6)
        }()
        RemoteImage(url: img.url, contentMode: .fill,
                    targetPointSize: CGSize(width: 720, height: 720), quality: 80)
            .aspectRatio(aspect, contentMode: .fill)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Forward panel

private struct DynamicForwardPanel: View {
    let orig: DynamicItemRefDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.up.right")
                Text(orig.author.name)
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(IbiliTheme.textSecondary)

            if !orig.text.isEmpty {
                Text(orig.text)
                    .font(.footnote)
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(4)
            }
            DynamicBody(item: orig, kind: orig.kind, embedded: true)

            if orig.kind == .unsupported {
                Text("暂不支持此类内容")
                    .font(.caption2)
                    .foregroundStyle(IbiliTheme.textSecondary)
            }
        }
        .padding(10)
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
        // Drop items we've already shown — needed because Bilibili
        // sometimes returns overlapping ranges across page calls.
        let existing = Set(items.map { $0.idStr })
        let fresh = result.items.filter { !existing.contains($0.idStr) }
        items.append(contentsOf: fresh)
        offset = result.offset
        page += 1
        if !result.hasMore || fresh.isEmpty { isEnd = true }
    }
}
