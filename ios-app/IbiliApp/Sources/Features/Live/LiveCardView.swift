import SwiftUI

struct LiveCardView: View {
    let item: LiveFeedItemDTO
    let cardWidth: CGFloat
    let imageQuality: Int?

    private let cardCornerRadius: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LiveCover(
                cover: item.systemCover.isEmpty ? item.cover : item.systemCover,
                width: cardWidth,
                imageQuality: imageQuality,
                watchedLabel: item.watchedLabel,
                areaName: item.areaName
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)

                Label {
                    Text(item.uname).lineLimit(1)
                } icon: {
                    Image(systemName: "person.fill").imageScale(.small)
                }
                .font(.caption)
                .foregroundStyle(IbiliTheme.textSecondary)
            }
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

struct SearchLiveResultCardView: View {
    let item: SearchLiveItemDTO
    let cardWidth: CGFloat
    let imageQuality: Int?

    private let cardCornerRadius: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LiveCover(
                cover: item.cover,
                width: cardWidth,
                imageQuality: imageQuality,
                watchedLabel: item.online > 0 ? BiliFormat.compactCount(item.online) : "",
                areaName: item.areaName
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)

                Label {
                    Text(item.uname).lineLimit(1)
                } icon: {
                    Image(systemName: "person.fill").imageScale(.small)
                }
                .font(.caption)
                .foregroundStyle(IbiliTheme.textSecondary)
            }
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

private struct LiveCover: View {
    let cover: String
    let width: CGFloat
    let imageQuality: Int?
    let watchedLabel: String
    let areaName: String

    var body: some View {
        let height = (width / VideoCoverView.aspectRatio).rounded()
        ZStack(alignment: .bottomLeading) {
            RemoteImage(
                url: cover,
                contentMode: .fill,
                targetPointSize: CGSize(width: width, height: height),
                quality: imageQuality
            )
            .frame(width: width, height: height)
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.62)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(width: width, height: height)
            .allowsHitTesting(false)

            HStack(spacing: 6) {
                Text("LIVE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(IbiliTheme.accent))
                if !watchedLabel.isEmpty {
                    Text(watchedLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.45)))
                }
            }
            .padding(7)
            .frame(width: width, height: height, alignment: .topLeading)

            if !areaName.isEmpty {
                Text(areaName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 7)
                    .frame(width: width, alignment: .bottomLeading)
            }
        }
        .frame(width: width, height: height)
    }
}
