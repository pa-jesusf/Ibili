import SwiftUI

struct ArticleView: View {
    let articleID: String
    let kind: String

    @StateObject private var vm = ArticleViewModel()
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation
    @Environment(\.inlinePlayerNavigation) private var inlinePlayerNavigation
    @State private var preview: ArticleImagePreview?
    @State private var shareSheet: ShareSheetItem?
    @State private var userSpaceMID: Int64?

    var body: some View {
        Group {
            if vm.isLoading && vm.detail == nil {
                ProgressView()
                    .tint(IbiliTheme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.errorText, vm.detail == nil {
                emptyState(systemImage: "doc.text.magnifyingglass", text: error, retry: true)
            } else if let detail = vm.detail {
                detailContent(detail)
            } else {
                emptyState(systemImage: "doc.text", text: "专栏暂时不可用")
            }
        }
        .background(IbiliTheme.background.ignoresSafeArea())
        .navigationTitle("专栏")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(kind)-\(articleID)") {
            await vm.load(id: articleID, kind: kind)
        }
        .fullScreenCover(item: $preview) { selection in
            ImagePreviewSheet(urls: selection.urls, initialIndex: selection.index)
        }
        .sheet(item: $shareSheet) { item in
            ActivityViewController(activityItems: [item.url])
        }
        .background {
            if !isInPlayerHostNavigation {
                NavigationLink(
                    isActive: Binding(
                        get: { userSpaceMID != nil },
                        set: { if !$0 { userSpaceMID = nil } }
                    ),
                    destination: {
                        if let mid = userSpaceMID {
                            UserSpaceView(mid: mid)
                        }
                    },
                    label: { EmptyView() }
                )
                .opacity(0)
                .allowsHitTesting(false)
            }
        }
    }

    private func detailContent(_ detail: ArticleDetailDTO) -> some View {
        GeometryReader { proxy in
            let pageWidth = max(1, proxy.size.width)
            let contentWidth = max(1, pageWidth - 32)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(detail.title.isEmpty ? "无标题专栏" : detail.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(IbiliTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: contentWidth, alignment: .leading)

                        Button {
                            openUser(mid: detail.author.mid)
                        } label: {
                            HStack(spacing: 10) {
                                RemoteImage(url: detail.author.face,
                                            contentMode: .fill,
                                            targetPointSize: CGSize(width: 40, height: 40),
                                            quality: 80)
                                    .frame(width: 40, height: 40)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(detail.author.name.isEmpty ? "未知作者" : detail.author.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(IbiliTheme.textPrimary)
                                        .lineLimit(1)
                                    if detail.pubTs > 0 {
                                        Text(BiliFormat.relativeDate(detail.pubTs))
                                            .font(.caption)
                                            .foregroundStyle(IbiliTheme.textSecondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(detail.author.mid <= 0)
                        .frame(width: contentWidth, alignment: .leading)

                        ArticleStatRow(detail: detail, onShare: {
                            shareSheet = ShareSheetItem(url: detail.url)
                        })
                        .frame(width: contentWidth, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(detail.blocks.enumerated()), id: \.offset) { _, block in
                            ArticleBlockView(block: block, contentWidth: contentWidth, onOpenImage: openImage)
                                .frame(width: contentWidth, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)

                    Divider()
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                    if detail.commentId > 0 && detail.commentType > 0 {
                        CommentListView(oid: detail.commentId, kind: detail.commentType)
                            .padding(.horizontal, 16)
                    } else {
                        Text("此专栏不支持评论")
                            .font(.footnote)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .frame(width: contentWidth, alignment: .center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 20)
                    }
                }
                .frame(width: pageWidth, alignment: .leading)
                .padding(.bottom, 32)
            }
            .environment(\.commentViewportHeight, max(1, proxy.size.height))
            .environment(\.commentContentWidth, contentWidth)
            .refreshable {
                await vm.load(id: articleID, kind: kind, force: true)
            }
        }
    }

    private func openImage(_ url: String) {
        guard let detail = vm.detail else { return }
        let urls = detail.blocks.flatMap { $0.images.map(\.url) }.filter { !$0.isEmpty }
        guard let index = urls.firstIndex(of: url) else { return }
        preview = ArticleImagePreview(urls: urls, index: index)
    }

    private func openUser(mid: Int64) {
        guard mid > 0 else { return }
        if isInPlayerHostNavigation {
            if let inlinePlayerNavigation {
                inlinePlayerNavigation.openUser(mid: mid)
            } else {
                router.openUserSpace(mid: mid)
            }
        } else {
            userSpaceMID = mid
        }
    }

    private func emptyState(systemImage: String, text: String, retry: Bool = false) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(IbiliTheme.textSecondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(IbiliTheme.textSecondary)
                .multilineTextAlignment(.center)
            if retry {
                Button("重试") {
                    Task { await vm.load(id: articleID, kind: kind, force: true) }
                }
                .buttonStyle(.borderedProminent)
                .tint(IbiliTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}

@MainActor
final class ArticleViewModel: ObservableObject {
    @Published private(set) var detail: ArticleDetailDTO?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?

    private var loadedKey = ""

    func load(id: String, kind: String, force: Bool = false) async {
        let key = "\(kind)-\(id)"
        guard force || key != loadedKey else { return }
        loadedKey = key
        isLoading = true
        errorText = nil
        do {
            let normalizedKind = kind == "opus" ? "opus" : "read"
            let result = try await Task.detached(priority: .userInitiated) {
                if normalizedKind == "opus" {
                    return try CoreClient.shared.articleOpus(id: id)
                }
                return try CoreClient.shared.articleRead(cvid: Int64(id) ?? 0)
            }.value
            detail = result
        } catch {
            errorText = (error as NSError).localizedDescription
        }
        isLoading = false
    }
}

private struct ArticleImagePreview: Identifiable {
    let id = UUID()
    let urls: [String]
    let index: Int
}

private struct ArticleStatRow: View {
    let detail: ArticleDetailDTO
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            stat(symbol: "eye", value: detail.stat.view, fallback: "阅读")
            stat(symbol: "hand.thumbsup", value: detail.stat.like, fallback: "点赞")
            stat(symbol: "bubble.left", value: detail.stat.reply, fallback: "评论")
            stat(symbol: "star", value: detail.stat.favorite, fallback: "收藏")
            Spacer(minLength: 0)
            Button(action: onShare) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .foregroundStyle(IbiliTheme.textSecondary)
        }
        .font(.caption)
        .foregroundStyle(IbiliTheme.textSecondary)
    }

    private func stat(symbol: String, value: Int64, fallback: String) -> some View {
        Label(value > 0 ? BiliFormat.compactCount(value) : fallback, systemImage: symbol)
            .labelStyle(.titleAndIcon)
    }
}

private struct ArticleBlockView: View {
    let block: ArticleBlockDTO
    let contentWidth: CGFloat
    let onOpenImage: (String) -> Void

    var body: some View {
        switch block.kind {
        case "heading":
            ArticleRichText(nodes: block.richText, fallback: block.text)
                .font(.title3.weight(.semibold))
                .foregroundStyle(IbiliTheme.textPrimary)
                .frame(width: contentWidth, alignment: .leading)
        case "quote":
            ArticleRichText(nodes: block.richText, fallback: block.text)
                .font(.body)
                .foregroundStyle(IbiliTheme.textSecondary)
                .padding(.leading, 10)
                .padding(.vertical, 6)
                .frame(width: contentWidth, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(IbiliTheme.textSecondary.opacity(0.35))
                        .frame(width: 3)
                }
        case "image":
            ArticleImagesView(images: block.images, contentWidth: contentWidth, onOpenImage: onOpenImage)
        case "line":
            Divider()
                .padding(.vertical, 4)
                .frame(width: contentWidth)
        case "code":
            Text(block.text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(IbiliTheme.textPrimary)
                .padding(10)
                .frame(width: contentWidth, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(IbiliTheme.surface))
        case "link_card":
            if let card = block.linkCard {
                ArticleLinkCardView(card: card, contentWidth: contentWidth)
            }
        default:
            ArticleRichText(nodes: block.richText, fallback: block.text)
                .font(.body)
                .foregroundStyle(IbiliTheme.textPrimary)
                .frame(width: contentWidth, alignment: .leading)
        }
    }
}

private struct ArticleRichText: View {
    let nodes: [ArticleRichNodeDTO]
    let fallback: String

    var body: some View {
        rendered
            .lineSpacing(5)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var rendered: Text {
        let effective = nodes.isEmpty ? [ArticleRichNodeDTO(text: fallback, url: "", kind: "text", rid: "", emojiURL: "", bold: false, italic: false, strikethrough: false)] : nodes
        var out = Text("")
        var first = true
        for node in effective {
            let part = render(node)
            out = first ? part : out + part
            first = false
        }
        return out
    }

    private func render(_ node: ArticleRichNodeDTO) -> Text {
        let text = Text(node.text)
        var styled = text
        if node.bold {
            styled = styled.bold()
        }
        if node.italic {
            styled = styled.italic()
        }
        if node.strikethrough {
            styled = styled.strikethrough()
        }
        if !node.url.isEmpty || node.kind != "text" {
            styled = styled.foregroundColor(IbiliTheme.accent)
        }
        return styled
    }
}

private struct ArticleImagesView: View {
    let images: [ArticleImageDTO]
    let contentWidth: CGFloat
    let onOpenImage: (String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(images, id: \.url) { image in
                let ratio = image.width > 0 && image.height > 0
                    ? min(max(CGFloat(image.height) / CGFloat(image.width), 0.25), 2.8)
                    : 9 / 16
                Button {
                    onOpenImage(image.url)
                } label: {
                    RemoteImage(url: image.url,
                                contentMode: .fill,
                                targetPointSize: CGSize(width: contentWidth, height: contentWidth * ratio),
                                quality: 82)
                        .frame(width: contentWidth, height: contentWidth * ratio)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ArticleLinkCardView: View {
    let card: ArticleLinkCardDTO
    let contentWidth: CGFloat
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: LinkRouter.mapToInternalURL(card.url)) {
                openURL(url)
            }
        } label: {
            HStack(spacing: 10) {
                if !card.cover.isEmpty {
                    RemoteImage(url: card.cover,
                                contentMode: .fill,
                                targetPointSize: CGSize(width: 76, height: 56),
                                quality: 76)
                        .frame(width: 76, height: 56)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(IbiliTheme.textPrimary)
                        .lineLimit(2)
                    if !card.subtitle.isEmpty {
                        Text(card.subtitle)
                            .font(.caption)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: contentWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(IbiliTheme.surface))
        }
        .buttonStyle(.plain)
    }
}
