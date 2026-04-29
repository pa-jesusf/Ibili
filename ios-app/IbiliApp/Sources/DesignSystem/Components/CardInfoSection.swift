import SwiftUI

/// Shared bottom-info section for video cards. Used by both the home
/// feed card and the search result card to keep the visual treatment
/// consistent. Additional metadata (author label, like count, pubdate)
/// can be passed via the optional slots.
struct CardInfoSection: View {
    let title: String
    let author: String
    var pubdate: Int64 = 0
    var likeCount: Int64 = 0
    var showAuthorIcon: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(IbiliTheme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)

            if showAuthorIcon {
                Label {
                    Text(author).lineLimit(1)
                } icon: {
                    Image(systemName: "person.fill").imageScale(.small)
                }
                .font(.caption)
                .foregroundStyle(IbiliTheme.textSecondary)
            } else {
                Text(author)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if pubdate > 0 || likeCount > 0 {
                HStack(spacing: 8) {
                    let dateText = BiliFormat.relativeDate(pubdate)
                    if !dateText.isEmpty {
                        Text(dateText)
                    }
                    if !dateText.isEmpty, likeCount > 0 {
                        Text("·")
                    }
                    if likeCount > 0 {
                        Label(BiliFormat.compactCount(likeCount), systemImage: "heart.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption2)
                .foregroundStyle(IbiliTheme.textSecondary)
                .lineLimit(1)
            }
        }
    }
}
