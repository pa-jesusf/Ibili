import SwiftUI

/// Like / coin / favorite / share / triple action row beneath the
/// video intro. Backed by `VideoInteractionService` for optimistic UI.
/// Long-press on the like button triggers 三连; long-press on the
/// favorite button opens the folder picker; coin tap shows a 1/2 币
/// chooser.
struct VideoActionRow: View {
    let aid: Int64
    let bvid: String
    let title: String
    let stat: VideoStatDTO
    @ObservedObject var interaction: VideoInteractionService

    @State private var coinDialog = false
    @State private var folderSheet = false

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
                action: {
                    if !interaction.state.coined { coinDialog = true }
                }
            )
            StatPair(
                systemName: "star",
                activeSystemName: "star.fill",
                count: max(stat.favorite, interaction.state.favoriteCount),
                isActive: interaction.state.favorited,
                action: {
                    // Tap → toggle in/out of the default folder. If the
                    // user has no folders yet, fall back to opening the
                    // picker so they can create/select one.
                    if interaction.defaultFolderId > 0 {
                        interaction.toggleFavorite(aid: aid, defaultFolderId: interaction.defaultFolderId)
                    } else {
                        folderSheet = true
                    }
                },
                onLongPress: { folderSheet = true }
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
                labelOverride: "稍后",
                isActive: interaction.state.inWatchLater,
                action: { interaction.toggleWatchLater(aid: aid) }
            )
        }
        .confirmationDialog("投币", isPresented: $coinDialog, titleVisibility: .visible) {
            Button("投 1 币") {
                interaction.addCoin(aid: aid, multiply: 1, alsoLike: false)
            }
            Button("投 2 币") {
                interaction.addCoin(aid: aid, multiply: 2, alsoLike: false)
            }
            Button("投 1 币 + 点赞") {
                interaction.addCoin(aid: aid, multiply: 1, alsoLike: true)
            }
            Button("投 2 币 + 点赞") {
                interaction.addCoin(aid: aid, multiply: 2, alsoLike: true)
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $folderSheet) {
            FavoriteFolderPickerSheet(aid: aid, interaction: interaction)
        }
    }

    private func share() {
        guard let url = URL(string: "https://www.bilibili.com/video/\(bvid)") else { return }
        let items: [Any] = [title, url]
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        UIApplication.shared
            .connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?
            .rootViewController?
            .present(av, animated: true)
    }
}
