import SwiftUI
import UIKit

/// Secondary page reached by tapping a non-video dynamic card. Shows
/// the full post body with tappable media, plus an embedded comment
/// thread reusing the video comment component (`CommentListView`).
struct DynamicDetailView: View {
    let item: DynamicItemDTO

    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var session: AppSession
    @State private var preview: DynamicDetailPreviewState?
    @State private var isLiked = false
    @State private var likeCount: Int64 = 0
    @State private var likeBusy = false
    @State private var shareSheetURL: ShareSheetItem?
    @State private var commentSendSheet = false
    @State private var toast: String?

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(1, proxy.size.width - 32)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if !item.text.isEmpty {
                        Text(item.text)
                            .font(.body)
                            .foregroundStyle(IbiliTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    DetailBody(
                        item: refOf(item),
                        kind: item.kind,
                        contentWidth: contentWidth,
                        onPlayVideo: openVideo,
                        onOpenLive: openLive,
                        onOpenArticle: openArticle,
                        onTapImage: { idx in preview = .init(urls: item.images.map(\.url), index: idx) }
                    )

                    if let orig = item.orig {
                        DetailForwardPanel(
                            orig: orig,
                            contentWidth: max(1, contentWidth - 20),
                            onPlayVideo: openOrigVideo,
                            onOpenLive: openOrigLive,
                            onOpenArticle: openOrigArticle,
                            onTapImage: { idx in preview = .init(urls: orig.images.map(\.url), index: idx) }
                        )
                    }

                    statBar

                    Divider().padding(.vertical, 4)

                    // Re-use the existing comment thread component. The
                    // dynamic feed surfaces its own (oid, kind) tuple in
                    // `basic.comment_id_str` / `basic.comment_type` —
                    // values vary per dynamic kind (1=video archive,
                    // 11=image post, 17=word/forward).
                    if item.commentId > 0 && item.commentType > 0 {
                        CommentListView(oid: item.commentId, kind: item.commentType)
                    } else {
                        Text("此动态不支持评论")
                            .font(.footnote)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .environment(\.commentViewportHeight, max(1, proxy.size.height))
            .environment(\.commentContentWidth, max(1, proxy.size.width - 32))
        }
        .background(IbiliTheme.background.ignoresSafeArea())
        .navigationTitle("动态")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $preview) { state in
            ImagePreviewSheet(urls: state.urls, initialIndex: state.index)
        }
        .sheet(item: $shareSheetURL) { item in
            ActivityViewController(activityItems: [item.url])
        }
        .sheet(isPresented: $commentSendSheet) {
            if item.commentId > 0 && item.commentType > 0 {
                CommentSendSheet(
                    oid: item.commentId,
                    kind: item.commentType,
                    selfMid: session.mid,
                    selfName: ""
                ) { _ in
                    // The embedded `CommentListView` reloads itself
                    // on the next bind cycle; nothing to do here.
                }
            }
        }
        .overlay(alignment: .top) {
            if let t = toast {
                Text(t)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .onAppear {
            // Initialise local like state from the item's stats. Real
            // "is_liked" needs an extra account-scoped query that the
            // current dynamic feed doesn't carry; for now we expose
            // the count and let the user toggle.
            likeCount = item.stat.like
        }
    }

    private var header: some View {
        DynamicAuthorHeader(author: item.author, avatarSize: 44)
    }

    private var statBar: some View {
        DynamicStatActionBar(
            stat: item.stat,
            isLiked: isLiked,
            likeCountOverride: likeCount,
            likeBusy: likeBusy,
            onForward: {
                shareSheetURL = ShareSheetItem(url: "https://t.bilibili.com/\(item.idStr)")
            },
            onComment: {
                commentSendSheet = true
            },
            onLike: {
                Task { await toggleLike() }
            }
        )
        .padding(.top, 4)
    }

    private func toggleLike() async {
        guard !likeBusy else { return }
        likeBusy = true
        defer { likeBusy = false }
        let next: Int32 = isLiked ? 2 : 1 // 1=like, 2=unlike (matches upstream)
        let dynId = item.idStr
        let ok: Bool = await Task.detached {
            (try? CoreClient.shared.dynamicLike(dynamicId: dynId, action: next)) != nil
        }.value
        if ok {
            isLiked.toggle()
            likeCount += isLiked ? 1 : -1
        } else {
            await flash("操作失败，请稍后重试")
        }
    }

    @MainActor
    private func flash(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { toast = nil }
    }

    private func refOf(_ x: DynamicItemDTO) -> DynamicItemRefDTO {
        DynamicItemRefDTO(idStr: x.idStr, kind: x.kind, author: x.author,
                          stat: x.stat, text: x.text,
                          video: x.video, live: x.live, article: x.article, images: x.images)
    }

    private func openVideo() {
        guard let v = item.video else { return }
        if v.isPGC {
            if v.epID > 0 {
                router.openPgc(epID: v.epID)
            } else if v.seasonID > 0 {
                router.openPgc(seasonID: v.seasonID)
            }
            return
        }
        openFeedItem(FeedItemDTO(
            aid: v.aid, bvid: v.bvid, cid: v.cid,
            title: v.title, cover: v.cover, author: item.author.name,
            durationSec: 0, play: 0, danmaku: 0
        ))
    }

    private func openOrigVideo() {
        guard let v = item.orig?.video else { return }
        if v.isPGC {
            if v.epID > 0 {
                router.openPgc(epID: v.epID)
            } else if v.seasonID > 0 {
                router.openPgc(seasonID: v.seasonID)
            }
            return
        }
        openFeedItem(FeedItemDTO(
            aid: v.aid, bvid: v.bvid, cid: v.cid,
            title: v.title, cover: v.cover, author: item.orig?.author.name ?? "",
            durationSec: 0, play: 0, danmaku: 0
        ))
    }

    private func openFeedItem(_ feedItem: FeedItemDTO) {
        router.open(feedItem)
    }

    private func openLive() {
        guard let live = item.live, live.isOpenable else { return }
        openLiveRoute(
            roomID: live.roomID,
            title: live.title,
            cover: live.cover,
            anchorName: item.author.name
        )
    }

    private func openOrigLive() {
        guard let orig = item.orig, let live = orig.live, live.isOpenable else { return }
        openLiveRoute(
            roomID: live.roomID,
            title: live.title,
            cover: live.cover,
            anchorName: orig.author.name
        )
    }

    private func openArticle() {
        guard let article = item.article, !article.id.isEmpty else { return }
        openArticleRoute(id: article.id, kind: article.kind)
    }

    private func openOrigArticle() {
        guard let article = item.orig?.article, !article.id.isEmpty else { return }
        openArticleRoute(id: article.id, kind: article.kind)
    }

    private func openLiveRoute(roomID: Int64, title: String, cover: String, anchorName: String) {
        router.openLive(
            roomID: roomID,
            title: title,
            cover: cover,
            anchorName: anchorName
        )
    }

    private func openArticleRoute(id: String, kind: String) {
        router.openArticle(id: id, kind: kind)
    }
}

private struct DynamicDetailPreviewState: Identifiable {
    let id = UUID()
    let urls: [String]
    let index: Int
}

/// Sheet payload for system share. `Identifiable` so we can drive a
/// `.sheet(item:)` directly off it.
struct ShareSheetItem: Identifiable {
    let id = UUID()
    let url: String
}

/// Thin `UIActivityViewController` wrapper for system share. We
/// pass the canonical `t.bilibili.com/<id_str>` URL so external apps
/// (Messages, WeChat etc.) get a clean deep link.
struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Body / forward panel (mostly mirror feed counterparts but
// take the larger detail-page content width).

private struct DetailBody: View {
    let item: DynamicItemRefDTO
    let kind: DynamicKindDTO
    let contentWidth: CGFloat
    let onPlayVideo: () -> Void
    let onOpenLive: () -> Void
    let onOpenArticle: () -> Void
    let onTapImage: (Int) -> Void

    var body: some View {
        switch kind {
        case .video, .pgc:
            if let v = item.video {
                detailVideoTile(v)
            }
        case .live:
            if let live = item.live {
                detailLiveTile(live)
            }
        case .draw:
            detailGrid(item.images)
        case .article:
            if let article = item.article {
                detailArticle(article)
            }
        case .word, .forward, .unsupported:
            EmptyView()
        }
    }

    private func detailLiveTile(_ live: DynamicLiveDTO) -> some View {
        let h = max(1, contentWidth * 9 / 16)
        return Button(action: onOpenLive) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: live.cover, contentMode: .fill,
                            targetPointSize: CGSize(width: contentWidth, height: h), quality: 85)
                    .frame(width: contentWidth, height: h)
                    .clipped()
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.62)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 5) {
                    Text(live.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        if !live.areaName.isEmpty { Text(live.areaName) }
                        if !live.watchedLabel.isEmpty { Text(live.watchedLabel) }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.86))
                }
                .padding(12)
                Text(live.liveStatus == 1 ? "LIVE" : "直播")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(live.liveStatus == 1 ? IbiliTheme.accent : .gray))
                    .padding(10)
                    .frame(width: contentWidth, height: h, alignment: .topLeading)
            }
            .frame(width: contentWidth, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func detailVideoTile(_ v: DynamicVideoDTO) -> some View {
        let h = max(1, contentWidth * 9 / 16)
        return Button(action: onPlayVideo) {
            ZStack {
                RemoteImage(url: v.cover, contentMode: .fill,
                            targetPointSize: CGSize(width: contentWidth, height: h), quality: 85)
                    .frame(width: contentWidth, height: h)
                    .clipped()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: contentWidth, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func detailArticle(_ article: DynamicArticleDTO) -> some View {
        return Button(action: onOpenArticle) {
            HStack(spacing: 10) {
                if !article.cover.isEmpty {
                    RemoteImage(url: article.cover, contentMode: .fill,
                                targetPointSize: CGSize(width: 110, height: 78), quality: 82)
                    .frame(width: 110, height: 78)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Label("专栏", systemImage: "doc.text")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(IbiliTheme.accent)
                    Text(article.title.isEmpty ? article.summary : article.title)
                        .font(.headline)
                        .foregroundStyle(IbiliTheme.textPrimary)
                        .lineLimit(2)
                    if !article.summary.isEmpty && article.summary != article.title {
                        Text(article.summary)
                            .font(.caption)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(IbiliTheme.surface))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detailGrid(_ images: [DynamicImageDTO]) -> some View {
        if images.isEmpty {
            EmptyView()
        } else if images.count == 1, let img = images.first {
            // 1-img post: respect natural ratio but clamp.
            let aspect: CGFloat = {
                guard img.width > 0, img.height > 0 else { return 1 }
                let r = CGFloat(img.height) / CGFloat(img.width)
                return min(max(r, 0.5), 1.6)
            }()
            let h = contentWidth * aspect
            RemoteImage(url: img.url, contentMode: .fill,
                        targetPointSize: CGSize(width: contentWidth, height: h), quality: 85)
                .frame(width: contentWidth, height: h)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { onTapImage(0) }
        } else {
            let cols = (images.count == 2 || images.count == 4) ? 2 : 3
            let spacing: CGFloat = 4
            let cell = (contentWidth - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let layout = Array(repeating: GridItem(.fixed(cell), spacing: spacing), count: cols)
            LazyVGrid(columns: layout, alignment: .leading, spacing: spacing) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                    RemoteImage(url: img.url, contentMode: .fill,
                                targetPointSize: CGSize(width: cell, height: cell), quality: 80)
                        .frame(width: cell, height: cell)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { onTapImage(idx) }
                }
            }
            .frame(width: contentWidth, alignment: .leading)
        }
    }
}

private struct DetailForwardPanel: View {
    let orig: DynamicItemRefDTO
    let contentWidth: CGFloat
    let onPlayVideo: () -> Void
    let onOpenLive: () -> Void
    let onOpenArticle: () -> Void
    let onTapImage: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.up.right")
                Text("@\(orig.author.name)")
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(IbiliTheme.textSecondary)

            if !orig.text.isEmpty {
                Text(orig.text)
                    .font(.callout)
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DetailBody(item: orig, kind: orig.kind, contentWidth: contentWidth,
                       onPlayVideo: onPlayVideo,
                       onOpenLive: onOpenLive,
                       onOpenArticle: onOpenArticle,
                       onTapImage: onTapImage)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.15))
        )
    }
}
