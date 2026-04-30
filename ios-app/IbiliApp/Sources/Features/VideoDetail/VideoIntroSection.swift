import SwiftUI

/// Title + 标语 row (stat counts + publish date) shown immediately
/// below the player. Mirrors the upstream PiliPlus "intro" first row.
struct VideoIntroSection: View {
    let title: String
    let stat: VideoStatDTO?
    let pubdate: Int64
    let bvid: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(IbiliTheme.textPrimary)
                .lineSpacing(2)

            HStack(spacing: 12) {
                if let stat {
                    label(symbol: "play.fill", text: BiliFormat.compactCount(stat.view))
                    label(symbol: "text.bubble.fill", text: BiliFormat.compactCount(stat.danmaku))
                }
                if pubdate > 0 {
                    Text(BiliFormat.relativeDate(pubdate))
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                Spacer(minLength: 0)
                Text(bvid)
                    .font(.caption.monospaced())
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .textSelection(.enabled)
            }
            .font(.footnote)
            .foregroundStyle(IbiliTheme.textSecondary)
        }
    }

    private func label(symbol: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).imageScale(.small)
            Text(text).monospacedDigit()
        }
    }
}
