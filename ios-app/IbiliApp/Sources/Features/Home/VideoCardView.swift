import SwiftUI

struct VideoCardView: View {
    let item: FeedItemDTO
    /// Width of the card in points. Used to size the cover image request so we
    /// only download as many pixels as the screen will display.
    let cardWidth: CGFloat
    let imageQuality: Int?

    private var coverHeight: CGFloat { (cardWidth * 10.0 / 16.0).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(
                    url: item.cover,
                    contentMode: .fill,
                    targetPointSize: CGSize(width: cardWidth, height: coverHeight),
                    quality: imageQuality
                )
                .frame(width: cardWidth, height: coverHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if item.durationSec > 0 {
                    Text(formatDuration(item.durationSec))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.author)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(IbiliTheme.textSecondary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
    }

    private func formatDuration(_ s: Int64) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }
}
