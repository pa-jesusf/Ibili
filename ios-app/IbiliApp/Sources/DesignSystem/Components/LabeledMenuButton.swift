import SwiftUI

/// "icon + small label" pill used in the player top-right cluster
/// when an icon alone would be ambiguous (e.g. a quality picker showing
/// the current label). For pure-icon affordances see `IconButton`.
struct LabeledMenuButton<MenuContent: View>: View {
    let systemName: String
    let label: String
    @ViewBuilder var content: () -> MenuContent

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .medium))
                Text(label)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 0.5))
        }
    }
}
