import SwiftUI

/// Search uses the same native card presentation and bitmap backdrop as home.
struct SearchResultCardView: View {
    let item: SearchVideoItemDTO
    let cardWidth: CGFloat
    let imageQuality: Int?
    let meta: FeedCardMetaConfig

    var body: some View {
        MediaCardView(
            model: MediaCardRenderModel(search: item, imageQuality: imageQuality, meta: meta),
            width: cardWidth
        )
    }
}

struct SearchUserResultCardView: View {
    let item: SearchUserItemDTO
    let cardWidth: CGFloat

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
        .mediaCardChrome(width: cardWidth)
    }
}

struct SearchArticleResultCardView: View {
    let item: SearchArticleItemDTO
    let cardWidth: CGFloat
    let imageQuality: Int?

    var body: some View {
        MediaCardView(model: MediaCardRenderModel(searchArticle: item, imageQuality: imageQuality), width: cardWidth)
    }
}

struct SearchPgcResultCardView: View {
    let item: SearchPgcItemDTO
    let cardWidth: CGFloat
    let imageQuality: Int?

    var body: some View {
        PgcPosterCardView(
            data: PgcPosterCardData(
                id: item.seasonID,
                title: item.title,
                cover: item.cover,
                score: item.score,
                primaryLine: [item.areas, item.styles].filter { !$0.isEmpty }.joined(separator: " · "),
                secondaryLine: [item.indexShow, item.pubtime > 0 ? BiliFormat.relativeDate(item.pubtime) : ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                description: item.desc
            ),
            cardWidth: cardWidth,
            imageQuality: imageQuality,
            style: .detailed,
            cornerRadius: MediaCardLayout(width: cardWidth, showsAuthor: false, showsMetadata: false).cornerRadius
        )
        .mediaCardChrome(width: cardWidth)
    }
}
