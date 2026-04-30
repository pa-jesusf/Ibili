import SwiftUI

/// Compact horizontal video row used by:
///   • 相关视频 列表 (`VideoDetail/RelatedVideoList`)
///   • 我的 → 历史 / 收藏 / 稍后再看 二级页
///   • Anywhere else a video needs a vertical-list presentation
///     rather than the home/search 2-up grid.
///
/// Visual: 16:10 cover on the left with optional duration pill,
/// title + author + stats stacked on the right. Apple-feeling rhythm:
/// 8pt vertical padding, 12pt cover-to-text gap.
///
/// Tap handling lives at the call-site so callers can choose between
/// `Button { … } label: { CompactVideoRow(...) }` or wrapping in
/// `NavigationLink`. We expose a `progress` knob (0…1) so the
/// "history" surface can render the upstream resume bar without
/// needing a second component.
struct CompactVideoRow: View {
    let cover: String
    let title: String
    let author: String
    let durationSec: Int64
    let play: Int64
    let danmaku: Int64
    /// Optional resume-progress (0…1). Zero hides the bar entirely.
    var progress: Double = 0
    /// Optional override for the duration pill (e.g. "已看完", "看到 3 分钟").
    /// Falls back to formatted duration when nil.
    var durationOverride: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: cover,
                            contentMode: .fill,
                            targetPointSize: CGSize(width: 240, height: 150),
                            quality: 75)
                    .frame(width: 120, height: 75)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        if progress > 0.001 {
                            // Slim resume bar across the bottom of the
                            // cover, matching iOS's "Continue Watching"
                            // affordance in the TV app.
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.white.opacity(0.25))
                                    Rectangle().fill(IbiliTheme.accent)
                                        .frame(width: geo.size.width * min(max(progress, 0), 1))
                                }
                            }
                            .frame(height: 2)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if let label = durationOverride ?? formattedDuration {
                    Text(label)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(6)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !author.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle")
                            .imageScale(.small)
                        Text(author)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(IbiliTheme.textSecondary)
                }
                HStack(spacing: 12) {
                    if play > 0 {
                        Label(BiliFormat.compactCount(play), systemImage: "play.fill")
                    }
                    if danmaku > 0 {
                        Label(BiliFormat.compactCount(danmaku), systemImage: "text.bubble")
                    }
                }
                .font(.caption2)
                .foregroundStyle(IbiliTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private var formattedDuration: String? {
        durationSec > 0 ? BiliFormat.duration(durationSec) : nil
    }
}
