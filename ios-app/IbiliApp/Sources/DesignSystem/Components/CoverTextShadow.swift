import SwiftUI

extension View {
    /// Apply to a full-width padded text block, leaving the rest of the cover clear.
    func coverTextShadow() -> some View {
        shadow(color: .black.opacity(0.4), radius: 1.5, x: 0, y: 1)
            .background {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black.opacity(0.1), location: 0.4),
                                       .init(color: .black.opacity(0.32), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.top, -18)
                    .allowsHitTesting(false)
            }
    }
}
