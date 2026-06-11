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
    var onScrollOffsetChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        if items.isEmpty {
            emptyState(title: "暂无相关视频", symbol: "rectangle.stack.badge.minus")
                .padding(.vertical, 40)
        } else {
            VirtualizedCollectionView(
                items: items,
                layout: .list(
                    rowHeight: 92,
                    contentInsets: NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 92, trailing: 12)
                ),
                onTap: { item in
                    onTap(adapt(item))
                },
                onReachEnd: {
                    if !isEnd {
                        onReachEnd()
                    }
                },
                onPrefetch: prefetchCovers,
                onScrollOffsetChange: onScrollOffsetChange
            ) { item in
                RelatedRow(item: item)
                    .equatable()
            }
            .overlay(alignment: .bottom) {
                if isLoadingMore {
                    ProgressView()
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 14)
                } else if isEnd {
                    Text("已经到底了")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 14)
                }
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
            cover: item.cover,
            title: item.title,
            author: item.author,
            durationSec: item.durationSec,
            play: item.play,
            danmaku: item.danmaku
        )
    }
}
