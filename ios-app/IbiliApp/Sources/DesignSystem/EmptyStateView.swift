import SwiftUI

/// Lightweight replacement for `ContentUnavailableView` that works on
/// iOS 16. Falls back to a centred icon + title (+ optional message)
/// in the secondary text colour.
@ViewBuilder
func emptyState(title: String, symbol: String, message: String? = nil) -> some View {
    VStack(spacing: 8) {
        Image(systemName: symbol)
            .font(.system(size: 32, weight: .regular))
            .foregroundStyle(.secondary)
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
        if let m = message, !m.isEmpty {
            Text(m)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
    .frame(maxWidth: .infinity)
}
