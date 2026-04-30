import SwiftUI

/// Uploader (UP 主) card: avatar, name, follow button. Tapping the
/// card area is reserved for navigating to the uploader's space; we
/// stub that out for now and only wire the follow toggle.
struct UploaderCardView: View {
    let owner: VideoOwnerDTO
    @ObservedObject var interaction: VideoInteractionService

    var body: some View {
        HStack(spacing: 12) {
            BiliAvatar(url: owner.face, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(owner.name.isEmpty ? "—" : owner.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(1)
                Text("UP 主")
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
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
