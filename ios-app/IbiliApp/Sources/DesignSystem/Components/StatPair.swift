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
    var isActive: Bool = false
    var tint: Color = IbiliTheme.accent
    var action: () -> Void
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: isActive ? activeSystemName : systemName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isActive ? tint : IbiliTheme.textPrimary)
                    .frame(height: 26)
                Text(BiliFormat.compactCount(count))
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
    }
}
