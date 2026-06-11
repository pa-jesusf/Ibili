import SwiftUI

/// Home feed video card. Shares its visual treatment 1:1 with
/// `SearchResultCardView` — same cover, same info section, same
/// paddings — so a user comparing the two surfaces sees a single,
/// consistent card layout. The home recommendation feed only
/// supplies a subset of the fields (no `like`, often no `pubdate`);
/// missing values just collapse their respective slots without
/// affecting the surrounding geometry.
struct VideoCardView: View {
    let item: FeedItemDTO
    let cardWidth: CGFloat
    let imageQuality: Int?
    let showsDurationAtTopTrailing: Bool
    let meta: FeedCardMetaConfig

    var body: some View {
        MediaCardView(
            model: MediaCardRenderModel(
                feed: item,
                imageQuality: imageQuality,
                meta: meta,
                durationPlacement: showsDurationAtTopTrailing ? .topTrailing : .bottomTrailing
            ),
            width: cardWidth
        )
    }
}
