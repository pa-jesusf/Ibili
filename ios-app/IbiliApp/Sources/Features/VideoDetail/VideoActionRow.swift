import SwiftUI

/// Like / coin / favorite / share / triple action row beneath the
/// video intro. Backed by `VideoInteractionService` for optimistic UI.
/// Long-press on the like button triggers 三连.
struct VideoActionRow: View {
    let aid: Int64
    let bvid: String
    let stat: VideoStatDTO
    @ObservedObject var interaction: VideoInteractionService

    var body: some View {
        HStack(spacing: 0) {
            StatPair(
                systemName: "hand.thumbsup",
                activeSystemName: "hand.thumbsup.fill",
                count: max(stat.like, interaction.state.likeCount),
                isActive: interaction.state.liked,
                action: { interaction.toggleLike(aid: aid) },
                onLongPress: { interaction.triple(aid: aid) }
            )
            StatPair(
                systemName: "bitcoinsign.circle",
                activeSystemName: "bitcoinsign.circle.fill",
                count: max(stat.coin, interaction.state.coinCount),
                isActive: interaction.state.coined,
                action: { interaction.addCoin(aid: aid, multiply: 1, alsoLike: false) }
            )
            StatPair(
                systemName: "star",
                activeSystemName: "star.fill",
                count: max(stat.favorite, interaction.state.favoriteCount),
                isActive: interaction.state.favorited,
                action: { interaction.toggleFavorite(aid: aid, defaultFolderId: 0) }
            )
            StatPair(
                systemName: "square.and.arrow.up",
                activeSystemName: "square.and.arrow.up.fill",
                count: stat.share,
                action: { share() }
            )
            StatPair(
                systemName: "clock",
                activeSystemName: "clock.fill",
                count: 0,
                isActive: interaction.state.inWatchLater,
                action: { interaction.toggleWatchLater(aid: aid) }
            )
        }
    }

    private func share() {
        let url = "https://www.bilibili.com/video/\(bvid)"
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared
            .connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?
            .rootViewController?
            .present(av, animated: true)
    }
}
