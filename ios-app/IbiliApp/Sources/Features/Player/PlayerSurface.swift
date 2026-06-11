import SwiftUI

struct PlayerSurface<Content: View>: View {
    var aspectRatio: CGFloat = 16.0 / 9.0
    let content: Content

    init(aspectRatio: CGFloat = 16.0 / 9.0, @ViewBuilder content: () -> Content) {
        self.aspectRatio = aspectRatio
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black
            content
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipped()
    }
}
