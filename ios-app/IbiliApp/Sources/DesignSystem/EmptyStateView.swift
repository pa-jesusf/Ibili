import SwiftUI

/// Lightweight replacement for `ContentUnavailableView` that works on
/// iOS 16. Falls back to a centred icon + title (+ optional message)
/// in the secondary text colour.
@ViewBuilder
func emptyState(title: String, symbol: String, message: String? = nil) -> some View {
    StateView(state: .empty(title: title, systemImage: symbol, message: message))
}
