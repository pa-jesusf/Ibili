import SwiftUI
import UIKit

/// Secondary page reached by tapping a non-video dynamic card. Shows
/// the full post body with tappable media, plus an embedded comment
/// thread reusing the video comment component (`CommentListView`).
struct DynamicDetailView: View {
    let item: DynamicItemDTO

    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var session: AppSession
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation
    @State private var preview: DynamicDetailPreviewState?
    @State private var isLiked = false
    @State private var likeCount: Int64 = 0
    @State private var likeBusy = false
    @State private var shareSheetURL: ShareSheetItem?
    @State private var commentSendSheet = false
    @State private var toast: String?

    var body: some View {
        let contentWidth = UIScreen.main.bounds.width - 32
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
                    onTapImage: { idx in preview = .init(urls: item.images.map(\.url), index: idx) }
                )

                if let orig = item.orig {
                    DetailForwardPanel(
                        orig: orig,
                        contentWidth: contentWidth - 20,
                        onPlayVideo: openOrigVideo,
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
        Group {
            if isInPlayerHostNavigation {
                Button {
                    router.openUserSpace(mid: item.author.mid)
                } label: {
                    headerLabel
                }
            } else {
                NavigationLink {
                    UserSpaceView(mid: item.author.mid)
                } label: {
                    headerLabel
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(item.author.mid <= 0)
    }

    private var headerLabel: some View {
        HStack(spacing: 10) {
            RemoteImage(url: item.author.face,
                        contentMode: .fill,
                        targetPointSize: CGSize(width: 44, height: 44),
                        quality: 80)
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(item.author.name).font(.subheadline.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                if !item.author.pubLabel.isEmpty {
                    Text(item.author.pubLabel)
                        .font(.caption2)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var statBar: some View {
        HStack(spacing: 0) {
            statButton(symbol: "arrowshape.turn.up.right", value: item.stat.forward, label: "转发") {
                shareSheetURL = ShareSheetItem(url: "https://t.bilibili.com/\(item.idStr)")
            }
            statButton(symbol: "bubble.left", value: item.stat.comment, label: "评论") {
                commentSendSheet = true
            }
            statButton(symbol: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
                       value: likeCount, label: "点赞",
                       tint: isLiked ? IbiliTheme.accent : IbiliTheme.textSecondary) {
                Task { await toggleLike() }
            }
            .disabled(likeBusy)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func statButton(symbol: String, value: Int64, label: String,
                            tint: Color = IbiliTheme.textSecondary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(value > 0 ? BiliFormat.compactCount(value) : label)
            }
            .font(.footnote)
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                          video: x.video, images: x.images)
    }

    private func openVideo() {
        guard let v = item.video else { return }
        router.open(FeedItemDTO(
            aid: v.aid, bvid: v.bvid, cid: 0,
            title: v.title, cover: v.cover, author: item.author.name,
            durationSec: 0, play: 0, danmaku: 0
        ))
    }

    private func openOrigVideo() {
        guard let v = item.orig?.video else { return }
        router.open(FeedItemDTO(
            aid: v.aid, bvid: v.bvid, cid: 0,
            title: v.title, cover: v.cover, author: item.orig?.author.name ?? "",
            durationSec: 0, play: 0, danmaku: 0
        ))
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
    let onTapImage: (Int) -> Void

    var body: some View {
        switch kind {
        case .video, .pgc, .live:
            if let v = item.video {
                detailVideoTile(v)
            }
        case .draw:
            detailGrid(item.images)
        case .article:
            if let v = item.video {
                detailArticle(v)
            }
        case .word, .forward, .unsupported:
            EmptyView()
        }
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

    private func detailArticle(_ v: DynamicVideoDTO) -> some View {
        let h = max(1, contentWidth * 9 / 16)
        return VStack(alignment: .leading, spacing: 6) {
            if !v.cover.isEmpty {
                RemoteImage(url: v.cover, contentMode: .fill,
                            targetPointSize: CGSize(width: contentWidth, height: h), quality: 85)
                    .frame(width: contentWidth, height: h)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if !v.title.isEmpty {
                Text(v.title).font(.headline).foregroundStyle(IbiliTheme.textPrimary)
            }
        }
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
                       onPlayVideo: onPlayVideo, onTapImage: onTapImage)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.15))
        )
    }
}
