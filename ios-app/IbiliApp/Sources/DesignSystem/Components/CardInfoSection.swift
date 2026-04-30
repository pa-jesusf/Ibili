import SwiftUI

/// Stat counts a feed card may surface in its bottom info row. Cards
/// that don't carry a particular stat just leave it at 0; the section
/// hides the slot when the user-selected stat is unavailable.
struct FeedCardStats: Equatable {
    var danmaku: Int64 = 0
    var favorite: Int64 = 0
    var like: Int64 = 0
}

/// Shared bottom-info section for video cards. Used by both the home
/// feed card and the search result card to keep the visual treatment
/// consistent. Element visibility is controlled by `FeedCardMetaConfig`,
/// which is per-screen so users can tune Home and Search independently.
struct CardInfoSection: View {
    let title: String
    let author: String
    var pubdate: Int64 = 0
    var stats: FeedCardStats = .init()
    var config: FeedCardMetaConfig
    /// Overridable title font so screens can dial density independently
    /// — Search uses a slightly smaller treatment so the busier card
    /// doesn't visually overpower the surrounding chrome.
    var titleFont: Font = .subheadline.weight(.medium)
    var showAuthorIcon: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(titleFont)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(IbiliTheme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)

            if config.showAuthor {
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
            }

            metaLine
        }
    }

    /// Bottom meta line (date · stat). Only renders when at least one
    /// piece of metadata is available — keeps the card height tight on
    /// older items / lean configurations.
    @ViewBuilder
    private var metaLine: some View {
        let dateText = (config.showPubdate && pubdate > 0) ? BiliFormat.relativeDate(pubdate) : ""
        let statValue = resolvedStatValue()
        let showDate = !dateText.isEmpty
        let showStat = config.stat != .none && statValue > 0
        if showDate || showStat {
            HStack(spacing: 8) {
                if showDate {
                    Text(dateText)
                }
                if showDate, showStat {
                    Text("·")
                }
                if showStat {
                    Label(BiliFormat.compactCount(statValue), systemImage: config.stat.systemImage)
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption2)
            .foregroundStyle(IbiliTheme.textSecondary)
            .lineLimit(1)
        }
    }

    private func resolvedStatValue() -> Int64 {
        switch config.stat {
        case .none: return 0
        case .danmaku: return stats.danmaku
        case .favorite: return stats.favorite
        case .like: return stats.like
        }
    }
}
