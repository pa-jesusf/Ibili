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
    let isLoadingMore: Bool
    let isEnd: Bool
    let onTap: (FeedItemDTO) -> Void
    let onReachEnd: () -> Void

    var body: some View {
        PagedCollectionSurface(
            items: items,
            layout: .list(spacing: 0),
            isLoading: isLoadingMore,
            isEnd: isEnd,
            prefetchThreshold: 4,
            onReachEnd: onReachEnd,
            onItemAppear: { index, _ in
                prefetchCovers(around: index)
            }
        ) {
            emptyState(title: "暂无相关视频", symbol: "rectangle.stack.badge.minus")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } itemContent: { index, item in
            Button {
                onTap(adapt(item))
            } label: {
                RelatedRow(item: item)
                    .equatable()
            }
            .buttonStyle(.plain)

            if index < items.count - 1 {
                Divider()
            }
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

    private func prefetchCovers(around index: Int) {
        guard items.indices.contains(index) else { return }
        let lower = max(0, index - 2)
        let upper = min(items.count, index + 8)
        let urls = items[lower..<upper].map(\.cover).filter { !$0.isEmpty }
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
