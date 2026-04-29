import SwiftUI

/// Search-result video card. Shares the cover treatment with the home
/// feed via `VideoCoverView`, but the bottom info area is tailored to
/// the search context: title (2 lines), `UP` author row, and a
/// secondary metadata line `MM-dd · ❤ X.X万`.
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

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)

                Label {
                    Text(item.author)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "person.fill")
                        .imageScale(.small)
                }
                .font(.caption)
                .foregroundStyle(IbiliTheme.textSecondary)

                HStack(spacing: 8) {
                    let dateText = BiliFormat.relativeDate(item.pubdate)
                    if !dateText.isEmpty {
                        Text(dateText)
                    }
                    if !dateText.isEmpty, item.like > 0 {
                        Text("·")
                    }
                    if item.like > 0 {
                        Label(BiliFormat.compactCount(item.like), systemImage: "heart.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption2)
                .foregroundStyle(IbiliTheme.textSecondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .frame(width: cardWidth, alignment: .topLeading)
        .background(IbiliTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }
}
