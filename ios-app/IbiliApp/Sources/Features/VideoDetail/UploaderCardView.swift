import SwiftUI

/// Uploader (UP 主) card: avatar + name + fans count + follow button.
///
/// We deliberately drop the previously-rendered "UP 主" subtitle —
/// the avatar pinned next to the name already communicates that, and
/// the fans count is *much* more useful at-a-glance for deciding
/// whether to follow. The fans count is fetched lazily from
/// `/x/web-interface/card` on appear so the card never blocks the
/// detail view's first paint.
struct UploaderCardView: View {
    let owner: VideoOwnerDTO
    @ObservedObject var interaction: VideoInteractionService
    @StateObject private var loader = UploaderCardLoader()

    var body: some View {
        HStack(spacing: 12) {
            BiliAvatar(url: owner.face, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(owner.name.isEmpty ? "—" : owner.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(1)
                // Fans subtitle replaces the old static "UP 主" line.
                // While we're loading we show an em-dash placeholder
                // so the row's vertical rhythm doesn't pop on hydrate.
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 0)

            Button {
                interaction.toggleFollow(fid: owner.mid)
            } label: {
                Text(interaction.state.followed ? "已关注" : "关注")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(interaction.state.followed ? IbiliTheme.textSecondary : .white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(interaction.state.followed ? IbiliTheme.surface : IbiliTheme.accent)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IbiliTheme.surface)
        )
        .task(id: owner.mid) {
            await loader.load(mid: owner.mid)
        }
    }

    private var subtitle: String {
        guard let card = loader.card else { return "—" }
        return "\(BiliFormat.compactCount(card.follower)) 粉丝"
    }
}

/// Tiny stand-alone view-model so the uploader card can self-fetch
/// `/x/web-interface/card` without complicating `VideoDetailViewModel`.
/// Re-fetches whenever the wrapped `mid` changes (related-video taps
/// re-key the host).
@MainActor
final class UploaderCardLoader: ObservableObject {
    @Published private(set) var card: UserCardDTO?

    func load(mid: Int64) async {
        guard mid > 0 else {
            card = nil
            return
        }
        if card?.mid == mid { return }
        let result: UserCardDTO? = await Task.detached {
            try? CoreClient.shared.userCard(mid: mid)
        }.value
        // Drop late responses if `mid` changed underneath us.
        if let result, result.mid == mid {
            self.card = result
        }
    }
}

private struct BiliAvatar: View {
    let url: String
    let size: CGFloat

    var body: some View {
        AsyncImage(url: URL(string: BiliImageURL.resized(url, pointSize: CGSize(width: size, height: size), quality: 75))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Circle().fill(IbiliTheme.surface)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
    }
}
