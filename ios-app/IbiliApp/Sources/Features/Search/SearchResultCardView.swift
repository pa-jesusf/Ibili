import SwiftUI

/// Search-result video card. Shares the cover treatment with the home
/// feed via `VideoCoverView` and the info layout via `CardInfoSection`.
struct SearchResultCardView: View {
    let item: SearchVideoItemDTO
    let cardWidth: CGFloat
    let imageQuality: Int?

    private let cardCornerRadius: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VideoCoverView(
                cover: item.cover,
                width: cardWidth,
                imageQuality: imageQuality,
                playCount: item.play,
                durationSec: item.durationSec,
                durationPlacement: .bottomTrailing
            )
            CardInfoSection(
                title: item.title,
                author: item.author,
                pubdate: item.pubdate,
                likeCount: item.like,
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
