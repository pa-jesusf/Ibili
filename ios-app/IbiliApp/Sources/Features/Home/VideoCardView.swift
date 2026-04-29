import SwiftUI

/// Home feed video card. Cover treatment + bottom info area composed
/// from reusable design-system pieces (`VideoCoverView`, `OverlayChip`,
/// `BiliFormat`). Intentionally accepts the upstream `FeedItemDTO`
/// directly so the home grid call site stays one-liner.
struct VideoCardView: View {
    let item: FeedItemDTO
    /// Width of the card in points. Used to size the cover image request so we
    /// only download as many pixels as the screen will display.
    let cardWidth: CGFloat
    let imageQuality: Int?
    let showsDurationAtTopTrailing: Bool

    private let cardCornerRadius: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VideoCoverView(
                cover: item.cover,
                width: cardWidth,
                imageQuality: imageQuality,
                playCount: item.play,
                durationSec: item.durationSec,
                durationPlacement: showsDurationAtTopTrailing ? .topTrailing : .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                Text(item.author)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .frame(width: cardWidth, alignment: .topLeading)
        .background(IbiliTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }
}
