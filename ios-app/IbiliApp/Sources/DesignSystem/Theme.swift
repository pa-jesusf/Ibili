import SwiftUI

enum IbiliTheme {
    static let accent = Color(red: 0.98, green: 0.36, blue: 0.55)
    static let accentUIColor = UIColor(red: 0.98, green: 0.36, blue: 0.55, alpha: 1)
    static let background = Color(.systemBackground)
    static let surface = Color(.secondarySystemBackground)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
}

/// Centralized glass surface. iOS 26+ uses the new liquid-glass material; older
/// versions fall back to `.ultraThinMaterial` blur.
struct GlassSurface<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder var content: () -> Content

    init(cornerRadius: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            content()
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content()
                .background(GlassBackground(cornerRadius: cornerRadius))
        }
    }
}

private struct GlassBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.stroke(.white.opacity(0.06), lineWidth: 0.5))
    }
}
