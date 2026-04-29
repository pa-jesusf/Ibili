import SwiftUI

/// Reusable capsule "pill" used for section chips: search type filters,
/// category cards, search-history entries, sort/duration filter buttons,
/// etc. Three visual styles cover everything we need without each call
/// site reinventing colours/padding:
///
/// - `.neutral` — default surface fill, primary text. Used for
///   inactive filter tabs and category grid cells.
/// - `.selected` — surface fill, accent text. Used for the active filter
///   tab in search results (`视频` highlighted in pink).
/// - `.accent` — accent fill, white text. Used for primary actions
///   (rare; reserved for CTA-style affordances).
struct IbiliPill: View {
    enum Style { case neutral, selected, accent }

    let title: String
    var systemImage: String? = nil
    var trailingSystemImage: String? = nil
    var style: Style = .neutral
    /// Horizontal padding override. Default is comfortable for short
    /// labels; category cards use the default, while compact filter
    /// chips can pass a smaller value.
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 8

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .imageScale(.small)
            }
        }
        .lineLimit(1)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(Capsule().fill(background))
        .contentShape(Capsule())
    }

    private var foreground: Color {
        switch style {
        case .neutral: return IbiliTheme.textPrimary
        case .selected: return IbiliTheme.accent
        case .accent: return .white
        }
    }

    private var background: Color {
        switch style {
        case .neutral, .selected: return IbiliTheme.surface
        case .accent: return IbiliTheme.accent
        }
    }
}
