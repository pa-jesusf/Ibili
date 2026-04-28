import SwiftUI

struct VideoCardView: View {
    let item: FeedItemDTO
    /// Width of the card in points. Used to size the cover image request so we
    /// only download as many pixels as the screen will display.
    let cardWidth: CGFloat
    let imageQuality: Int?
    let showsDurationAtTopTrailing: Bool

    private let coverAspectRatio: CGFloat = 16.0 / 10.0
    private let cardCornerRadius: CGFloat = 10

    private var coverHeight: CGFloat { (cardWidth / coverAspectRatio).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                RemoteImage(
                    url: item.cover,
                    contentMode: .fill,
                    targetPointSize: CGSize(width: cardWidth, height: coverHeight),
                    quality: imageQuality
                )
                .frame(width: cardWidth, height: coverHeight)
                .clipped()

                VStack {
                    HStack {
                        Spacer()
                        if showsDurationAtTopTrailing, item.durationSec > 0 {
                            durationChip
                        }
                    }
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.horizontal, 8)

                HStack(alignment: .bottom, spacing: 8) {
                    statChip(icon: "play.fill", value: formatCount(item.play))
                    Spacer(minLength: 8)
                    if !showsDurationAtTopTrailing, item.durationSec > 0 {
                        durationChip
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
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

    private var durationChip: some View {
        Text(formatDuration(item.durationSec))
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.68), in: Capsule())
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private func statChip(icon: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.68), in: Capsule())
    }

    private func formatDuration(_ s: Int64) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private func formatCount(_ count: Int64) -> String {
        switch count {
        case 100_000_000...:
            let value = Double(count) / 100_000_000.0
            return compactCount(value, suffix: "亿")
        case 10_000...:
            let value = Double(count) / 10_000.0
            return compactCount(value, suffix: "万")
        default:
            return String(max(0, count))
        }
    }

    private func compactCount(_ value: Double, suffix: String) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == floor(rounded) {
            return "\(Int(rounded))\(suffix)"
        }
        return String(format: "%.1f%@", rounded, suffix)
    }
}
