import SwiftUI

struct LiveCardView: View {
    let item: LiveFeedItemDTO
    let cardWidth: CGFloat
    let imageQuality: Int?

    var body: some View {
        MediaCardView(model: MediaCardRenderModel(live: item, imageQuality: imageQuality), width: cardWidth)
    }

    static func preferredHeight(width: CGFloat) -> CGFloat {
        MediaCardLayout(width: width, showsAuthor: true, showsMetadata: true, showsOverflowMenu: false).height
    }
}

struct SearchLiveResultCardView: View {
    let item: SearchLiveItemDTO
    let cardWidth: CGFloat
    let imageQuality: Int?

    var body: some View {
        MediaCardView(model: MediaCardRenderModel(searchLive: item, imageQuality: imageQuality), width: cardWidth)
    }
}
