import SwiftUI

/// Search-result video card. Visually identical to `VideoCardView`
/// (same cover, same info section, same paddings) so the home and
/// search surfaces present a consistent card layout. The only
/// difference is the data source — search items carry an extra
/// `like` count.
struct SearchResultCardView: View {
    let item: SearchVideoItemDTO
    let cardWidth: CGFloat
    let imageQuality: Int?
    let meta: FeedCardMetaConfig

    private let cardCornerRadius: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VideoCoverView(
                cover: item.cover,
                width: cardWidth,
                imageQuality: imageQuality,
                playCount: item.play,
                durationSec: item.durationSec,
                durationPlacement: .bottomTrailing,
                showPlayCount: meta.showPlay,
                showDuration: meta.showDuration
            )
            CardInfoSection(
                title: item.title,
                author: item.author,
                pubdate: item.pubdate,
                stats: FeedCardStats(danmaku: item.danmaku, like: item.like),
                config: meta,
                titleFont: .system(size: 15, weight: .medium),
                showAuthorIcon: true
            )
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .frame(width: cardWidth, alignment: .topLeading)
        .background(IbiliTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .drawingGroup(opaque: false)
    }
}
