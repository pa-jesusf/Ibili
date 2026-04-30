import SwiftUI

/// Home feed video card. Cover treatment + bottom info area composed
/// from reusable design-system pieces (`VideoCoverView`, `CardInfoSection`).
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
                config: meta
            )
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .frame(width: cardWidth, alignment: .topLeading)
        .background(IbiliTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .drawingGroup(opaque: false)
    }
}
