import SwiftUI

/// Glass-capsule icon button used as the primary affordance in player
/// overlays and detail-page action rows. SF Symbol-only by design — the
/// caller pairs it with a separate label when one is needed (see
/// `StatPair` for stat-style "icon + count" displays).
///
/// The default ornamental size matches Apple HIG's 44 pt minimum tappable
/// area while the symbol itself stays legible at 17 pt.
struct IconButton: View {
    enum Surface { case glass, plain, accent }

    let systemName: String
    var size: CGFloat = 44
    var symbolSize: CGFloat = 17
    var weight: Font.Weight = .medium
    var surface: Surface = .glass
    var tint: Color? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: weight))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(background)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(systemName))
    }

    private var foreground: Color {
        if let tint { return tint }
        switch surface {
        case .glass: return .white
        case .plain: return IbiliTheme.textPrimary
        case .accent: return .white
        }
    }

    @ViewBuilder
    private var background: some View {
        switch surface {
        case .glass:
            Circle().fill(.regularMaterial).overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 0.5))
        case .plain:
            Circle().fill(IbiliTheme.surface)
        case .accent:
            Circle().fill(IbiliTheme.accent)
        }
    }
}
