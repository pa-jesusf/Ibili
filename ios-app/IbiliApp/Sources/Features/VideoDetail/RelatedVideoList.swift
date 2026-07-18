import SwiftUI

/// "相关视频" tab content.
///
/// Visual: vertical list of compact rows (cover left, title + meta right)
/// rather than the home/search 2-up grid. Pagination: the upstream
/// `archive/related` endpoint is one-shot, so once those exhaust the VM
/// falls back to the home feed for additional rows. Tap → `onTap`
/// (the parent forwards into the deep-link router so the new video
/// opens on top of the current player, mirroring an in-app jump).
struct RelatedVideoList: View {
    let items: [RelatedVideoItemDTO]
    let isLoading: Bool
    let isEnd: Bool
    let scrollToTopSignal: Int
    let bottomContentInset: CGFloat
    let onScrollOffsetChange: ((CGFloat) -> Void)?
    let onTap: (FeedItemDTO) -> Void
    let onReachEnd: () -> Void

    var body: some View {
        VirtualizedCollectionSurface(
            items: items,
            layout: .list(
                horizontalInset: 12,
                topInset: 12,
                bottomInset: bottomContentInset,
                spacing: 0,
                estimatedHeight: 112
            ),
            footer: footer,
            scrollToTopSignal: scrollToTopSignal,
            prefetchThreshold: 4,
            onLoadMore: onReachEnd,
            onOpen: { onTap(adapt($0)) },
            onPrefetch: { items, _ in prefetchCovers(items) },
            onScrollOffsetChanged: { onScrollOffsetChange?($0) },
            splitTransitionIdentity: { item in
                let identity = FeedStableIdentity(
                    aid: item.aid,
                    bvid: item.bvid,
                    cid: item.cid
                )
                return identity.isValid ? identity : nil
            }
        ) { item, _ in
            AnyView(
                VStack(spacing: 0) {
                    RelatedRow(item: item)
                        .equatable()
                    if item.id != items.last?.id {
                        Divider()
                    }
                }
            )
        }
        .modifier(ProMotionScrollHint())
        .overlay {
            if items.isEmpty, isLoading {
                InitialLoadingView()
            } else if items.isEmpty {
                emptyState(title: "暂无相关视频", symbol: "rectangle.stack.badge.minus")
                    .padding(.horizontal, 24)
            }
        }
    }

    private var footer: (() -> AnyView)? {
        guard isEnd, !items.isEmpty else { return nil }
        return {
            AnyView(
                Text("已经到底了")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            )
        }
    }

    private func adapt(_ r: RelatedVideoItemDTO) -> FeedItemDTO {
        FeedItemDTO(
            aid: r.aid,
            bvid: r.bvid,
            cid: r.cid,
            title: r.title,
            cover: r.cover,
            author: r.author,
            durationSec: r.durationSec,
            play: r.play,
            danmaku: r.danmaku,
            ownerMID: r.mid
        )
    }

    private func prefetchCovers(_ items: [RelatedVideoItemDTO]) {
        let urls = items.map(\.cover).filter { !$0.isEmpty }
        guard !urls.isEmpty else { return }
        CoverImagePrefetcher.shared.prefetch(
            urls,
            targetPointSize: CGSize(width: 240, height: 150),
            quality: 75
        )
    }
}

/// Single row: cover left (16:10) with duration overlay, title + UP +
/// stats stacked on the right. Wraps the shared `CompactVideoRow`
/// so the "我的" → 历史 / 收藏 / 稍后再看 二级 lists render with the
/// exact same rhythm — keeping the app's vertical-list surfaces
/// visually consistent.
private struct RelatedRow: View, Equatable {
    let item: RelatedVideoItemDTO

    static func == (lhs: RelatedRow, rhs: RelatedRow) -> Bool {
        lhs.item == rhs.item
    }

    var body: some View {
        CompactVideoRow(
            model: MediaCardRenderModel(related: item)
        )
    }
}
