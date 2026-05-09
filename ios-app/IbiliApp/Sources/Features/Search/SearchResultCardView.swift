import SwiftUI

/// Search-result video card. Visually identical to `VideoCardView`
/// (same cover, same info section, same paddings) so the home and
/// search surfaces present a consistent card layout. The only
/// difference is the data source — search items carry an extra
/// `like` count.
struct SearchResultCardView: View {
    let item: SearchVideoItemDTO
    let cardWidth: CGFloat
    let imageQuality: Int?
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
                durationPlacement: .bottomTrailing,
                showPlayCount: meta.showPlay,
                showDuration: meta.showDuration
            )
            CardInfoSection(
                title: item.title,
                author: item.author,
                pubdate: item.pubdate,
                stats: FeedCardStats(danmaku: item.danmaku, like: item.like),
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

struct SearchUserResultCardView: View {
    let item: SearchUserItemDTO
    let cardWidth: CGFloat

    private let cardCornerRadius: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    RemoteImage(url: item.face,
                                contentMode: .fill,
                                targetPointSize: CGSize(width: 46, height: 46),
                                quality: 80)
                        .frame(width: 46, height: 46)
                        .clipShape(Circle())

                    if item.isLive {
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(IbiliTheme.accent))
                            .offset(x: 2, y: 2)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(item.uname)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(IbiliTheme.textPrimary)
                            .lineLimit(1)
                        if item.level > 0 {
                            Text("Lv\(item.level)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(IbiliTheme.accent)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(IbiliTheme.accent.opacity(0.12)))
                        }
                    }

                    Text("粉丝 \(BiliFormat.compactCount(item.fans)) · 视频 \(BiliFormat.compactCount(item.videos))")
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            let summary = item.officialDesc.isEmpty ? item.sign : item.officialDesc
            if !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            } else {
                Text("这个人还没有填写简介")
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary.opacity(0.7))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            }
        }
        .padding(10)
        .frame(width: cardWidth, alignment: .topLeading)
        .frame(minHeight: 112, alignment: .topLeading)
        .background(IbiliTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }
}

struct SearchArticleResultCardView: View {
    let item: SearchArticleItemDTO
    let cardWidth: CGFloat
    let imageQuality: Int?

    private let cardCornerRadius: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.cover.isEmpty {
                RemoteImage(url: item.cover,
                            contentMode: .fill,
                            targetPointSize: CGSize(width: cardWidth, height: cardWidth * 0.58),
                            quality: imageQuality ?? 78)
                    .frame(width: cardWidth, height: cardWidth * 0.58)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                if !item.desc.isEmpty {
                    Text(item.desc)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if !item.categoryName.isEmpty {
                        Text(item.categoryName)
                    }
                    Text(BiliFormat.relativeDate(item.pubTime))
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(IbiliTheme.textSecondary)
                HStack(spacing: 10) {
                    Label(BiliFormat.compactCount(item.view), systemImage: "eye")
                    Label(BiliFormat.compactCount(item.reply), systemImage: "bubble.left")
                    Label(BiliFormat.compactCount(item.like), systemImage: "hand.thumbsup")
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(IbiliTheme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .frame(width: cardWidth, alignment: .topLeading)
        .background(IbiliTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }
}
