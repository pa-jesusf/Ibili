import SwiftUI

struct PgcPosterCardData: Hashable, Identifiable {
    let id: Int64
    let title: String
    let cover: String
    let badge: String
    let score: String
    let primaryLine: String
    let secondaryLine: String
    let description: String

    init(
        id: Int64,
        title: String,
        cover: String,
        badge: String = "",
        score: String = "",
        primaryLine: String = "",
        secondaryLine: String = "",
        description: String = ""
    ) {
        self.id = id
        self.title = title
        self.cover = cover
        self.badge = badge
        self.score = score
        self.primaryLine = primaryLine
        self.secondaryLine = secondaryLine
        self.description = description
    }
}

struct PgcPosterCardView: View {
    enum Style {
        case compact
        case detailed
    }

    let data: PgcPosterCardData
    let cardWidth: CGFloat
    let imageQuality: Int?
    var style: Style = .detailed

    private let cardCornerRadius: CGFloat = 10

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            poster
            VStack(alignment: .leading, spacing: 7) {
                Text(data.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)

                if style == .detailed {
                    HStack(spacing: 8) {
                        Text("评分 \(displayScore)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(IbiliTheme.accent)
                        if !data.primaryLine.isEmpty {
                            Text(data.primaryLine)
                                .font(.caption)
                                .foregroundStyle(IbiliTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                } else if !data.primaryLine.isEmpty {
                    Text(data.primaryLine)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(1)
                }

                if !data.secondaryLine.isEmpty {
                    Text(data.secondaryLine)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(2)
                }

                if style == .detailed, !data.description.isEmpty {
                    Text(data.description)
                        .font(.caption2)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: posterHeight, alignment: .topLeading)
        }
        .padding(8)
        .frame(width: cardWidth, alignment: .topLeading)
        .background(IbiliTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }

    private var poster: some View {
        RemoteImage(url: data.cover,
                    contentMode: .fill,
                    targetPointSize: CGSize(width: posterWidth, height: posterHeight),
                    quality: imageQuality ?? 82)
            .frame(width: posterWidth, height: posterHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if !data.badge.isEmpty {
                    Text(data.badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.56)))
                        .padding(6)
                }
            }
    }

    private var displayScore: String {
        let score = data.score.trimmingCharacters(in: .whitespacesAndNewlines)
        return score.isEmpty || score == "0" || score == "0.0" ? "-" : score
    }

    private var posterWidth: CGFloat {
        max(74, min(104, cardWidth * 0.32))
    }

    private var posterHeight: CGFloat {
        posterWidth * 4 / 3
    }
}
