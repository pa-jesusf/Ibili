import SwiftUI

/// "相关视频" tab content. Reuses VideoCardView via a thin adapter so
/// the home/search card visual stays consistent.
struct RelatedVideoList: View {
    let items: [RelatedVideoItemDTO]
    let onTap: (FeedItemDTO) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 12, alignment: .top)
    ]

    var body: some View {
        if items.isEmpty {
            emptyState(title: "暂无相关视频", symbol: "rectangle.stack.badge.minus")
                .padding(.vertical, 40)
        } else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items) { item in
                    Button {
                        onTap(adapt(item))
                    } label: {
                        VideoCardView(
                            item: adapt(item),
                            cardWidth: 170,
                            imageQuality: 75,
                            showsDurationAtTopTrailing: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
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
