import SwiftUI

/// Search-result video card. Shares the cover treatment with the home
/// feed via `VideoCoverView` and the info layout via `CardInfoSection`.
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
                // Slightly smaller title than the home card so the
                // denser search row reads as more "result-y" than
                // "showcase-y" — matches Apple's HIG density cues.
                titleFont: .system(size: 13, weight: .medium),
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
