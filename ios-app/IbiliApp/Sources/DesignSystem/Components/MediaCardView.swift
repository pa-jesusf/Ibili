import SwiftUI

struct MediaCardView: View {
    let model: MediaCardRenderModel
    let width: CGFloat

    private let cornerRadius: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VideoCoverView(
                cover: model.cover,
                width: width,
                imageQuality: model.imageQuality,
                playCount: model.play,
                durationSec: model.durationSec,
                durationPlacement: model.durationPlacement,
                showPlayCount: model.meta.showPlay,
                showDuration: model.meta.showDuration
            )

            CardInfoSection(
                title: model.title,
                author: model.author,
                pubdate: model.pubdate,
                stats: FeedCardStats(danmaku: model.danmaku, like: model.like),
                config: model.meta,
                titleFont: .system(size: 15, weight: .medium),
                showAuthorIcon: true,
                isAuthorFollowed: model.isAuthorFollowed,
                bottomTrailingInset: 26
            )
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .frame(width: width, alignment: .topLeading)
        .background(IbiliTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .drawingGroup(opaque: false)
    }
}

struct MediaRowView: View {
    let model: MediaCardRenderModel
    var progress: Double = 0
    var durationOverride: String? = nil
    var coverSize = CGSize(width: 120, height: 75)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 6) {
                Text(model.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !model.author.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle")
                            .imageScale(.small)
                        Text(model.author)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(IbiliTheme.textSecondary)
                }

                HStack(spacing: 12) {
                    if model.play > 0 {
                        Label(BiliFormat.compactCount(model.play), systemImage: "play.fill")
                    }
                    if model.danmaku > 0 {
                        Label(BiliFormat.compactCount(model.danmaku), systemImage: "text.bubble")
                    }
                    if model.like > 0 {
                        Label(BiliFormat.compactCount(model.like), systemImage: "hand.thumbsup")
                    }
                }
                .font(.caption2)
                .foregroundStyle(IbiliTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(
                url: model.cover,
                contentMode: .fill,
                targetPointSize: CGSize(width: coverSize.width * 2, height: coverSize.height * 2),
                quality: model.imageQuality ?? 75
            )
            .frame(width: coverSize.width, height: coverSize.height)
            .clipped()
            .overlay(alignment: .bottom) {
                if progress > 0.001 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.25))
                            Rectangle().fill(IbiliTheme.accent)
                                .frame(width: geo.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let label = durationOverride ?? formattedDuration {
                Text(label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(6)
            }
        }
    }

    private var formattedDuration: String? {
        model.durationSec > 0 ? BiliFormat.duration(model.durationSec) : nil
    }
}

