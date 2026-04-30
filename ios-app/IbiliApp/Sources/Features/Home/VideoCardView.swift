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

    private let cardCornerRadius: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VideoCoverView(
                cover: item.cover,
                width: cardWidth,
                imageQuality: imageQuality,
                playCount: item.play,
                durationSec: item.durationSec,
                durationPlacement: showsDurationAtTopTrailing ? .topTrailing : .bottomTrailing,
                showPlayCount: meta.showPlay,
                showDuration: meta.showDuration
            )
            CardInfoSection(
                title: item.title,
                author: item.author,
                pubdate: item.pubdate,
                stats: FeedCardStats(danmaku: item.danmaku),
                config: meta,
                titleFont: .system(size: 15, weight: .medium),
                showAuthorIcon: true
            )
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .frame(width: cardWidth, alignment: .topLeading)
        .background(IbiliTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .drawingGroup(opaque: false)
    }
}
