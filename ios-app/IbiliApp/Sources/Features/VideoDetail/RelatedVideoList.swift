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
        if items.isEmpty {
            emptyState(title: "暂无相关视频", symbol: "rectangle.stack.badge.minus")
                .padding(.vertical, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        onTap(adapt(item))
                    } label: {
                        RelatedRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        // Trigger more when the third-from-last row appears
                        // so the list feels seamless on slower networks.
                        if !isEnd, index >= max(0, items.count - 3) {
                            onReachEnd()
                        }
                    }
                    if index < items.count - 1 {
                        Divider().padding(.leading, 132)
                    }
                }
                if isLoadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .padding(.vertical, 14)
                } else if isEnd {
                    HStack { Spacer(); Text("已经到底了").font(.caption).foregroundStyle(.secondary); Spacer() }
                        .padding(.vertical, 14)
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
            danmaku: r.danmaku
        )
    }
}

/// Single row: cover left (16:10) with duration overlay, title + UP +
/// stats stacked on the right. Wraps the shared `CompactVideoRow`
/// so the "我的" → 历史 / 收藏 / 稍后再看 二级 lists render with the
/// exact same rhythm — keeping the app's vertical-list surfaces
/// visually consistent.
private struct RelatedRow: View {
    let item: RelatedVideoItemDTO

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
