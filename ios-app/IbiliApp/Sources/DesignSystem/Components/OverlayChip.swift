import SwiftUI

/// Translucent dark capsule used as an overlay on top of a video cover
/// to display compact metadata (play count, danmaku count, duration).
///
/// Centralising this in one place keeps overlay style consistent across
/// the home feed and the search results grid; both call sites used to
/// inline the same `padding(.horizontal, 6).padding(.vertical, 3)
/// .background(.black.opacity(0.68), in: Capsule())` snippet.
struct OverlayChip: View {
    var systemImage: String? = nil
    let text: String
    var isMonospaced: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            label
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.68), in: Capsule())
        .lineLimit(1)
    }

    @ViewBuilder
    private var label: some View {
        if isMonospaced {
            Text(text).monospacedDigit().minimumScaleFactor(0.7)
        } else {
            Text(text).minimumScaleFactor(0.7)
        }
    }
}
