import SwiftUI

/// Vertical "icon over count" stat affordance — the primary building
/// block for the action row beneath a video (like / coin / fav /
/// share / triple). When `isActive` is true the icon switches to its
/// filled variant and tints accent so the user has a clear toggled
/// state (matches iOS Music/Photos action rows).
///
/// Designed to be tap-driven; long-press is exposed via `onLongPress`
/// so the like cell can wire up 三连 without bespoke gesture code.
struct StatPair: View {
    let systemName: String
    let activeSystemName: String
    let count: Int64
    /// When set, overrides the auto-formatted `count` and is rendered
    /// verbatim under the icon. Used by buttons like 稍后再看 where a
    /// numeric badge has no meaning.
    var labelOverride: String? = nil
    var isActive: Bool = false
    /// Renders an indeterminate progress ring around the icon while
    /// true. Used by the long-press 三连 / 收藏 affordances so the user
    /// has visual confirmation that the gesture was recognised, even
    /// before the network round-trip lands.
    var showProgressRing: Bool = false
    var tint: Color = IbiliTheme.accent
    var action: () -> Void
    var onLongPress: (() -> Void)? = nil

    @State private var ringAngle: Double = 0

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if showProgressRing {
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 32, height: 32)
                            .rotationEffect(.degrees(ringAngle))
                            .onAppear {
                                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                                    ringAngle = 360
                                }
                            }
                            .onDisappear { ringAngle = 0 }
                            .transition(.opacity)
                    }
                    Image(systemName: isActive ? activeSystemName : systemName)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isActive ? tint : IbiliTheme.textPrimary)
                }
                .frame(height: 32)
                Text(labelOverride ?? BiliFormat.compactCount(count))
                    .font(.caption)
                    .foregroundStyle(isActive ? tint : IbiliTheme.textSecondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in onLongPress?() }
        )
        .animation(.easeInOut(duration: 0.18), value: showProgressRing)
    }
}
