import SwiftUI
import UIKit

/// Renders a Bilibili reply message with inline emotes and tappable
/// links and playback times. The view is `Text`-based (no `UITextView`)
/// and respects the surrounding font / foreground style.
///
/// Tapping a jump link forwards a custom `ibili://bv/<id>` URL through
/// the `OpenURLAction` environment — the comment list installs a
/// handler that pushes the corresponding video onto the nav stack.
struct RichReplyText: View {
    let message: String
    let emotes: [ReplyEmoteDTO]
    let jumpUrls: [ReplyJumpUrlDTO]
    var lineLimit: Int? = nil
    var font: Font = .body
    var textColor: Color = .primary
    var onTruncationChange: ((Bool) -> Void)? = nil

    @State private var emoteImages: [String: UIImage] = [:]
    @State private var lastReportedTruncates: Bool?

    @Environment(\.playbackTextContext) private var playbackContext
    @Environment(\.openURL) private var openURL

    var body: some View {
        let estimatedTruncates = estimatedTruncation
        measuredText
            .environment(\.openURL, OpenURLAction { url in
                if playbackContext?.handle(url) == true { return .handled }
                guard url.host != "playback-time" else { return .handled }
                if LinkRouter.isShortLink(url) {
                    Task { @MainActor in openURL(await LinkRouter.resolveShortLink(url)) }
                    return .handled
                }
                openURL(url)
                return .handled
            })
            .lineLimit(lineLimit)
            .lineSpacing(2)
            .task(id: emoteLoadKey) {
                await loadEmotes()
            }
            .onAppear {
                reportTruncationIfNeeded(estimatedTruncates)
            }
            .onChange(of: estimatedTruncates) { newValue in
                reportTruncationIfNeeded(newValue)
            }
    }

    private var measuredText: Text {
        rendered
            .font(font)
    }

    private var emoteLoadKey: String {
        emotes.map { "\($0.name)=\($0.url)#\($0.size)" }.joined(separator: "|")
    }

    private var estimatedTruncation: Bool {
        guard let lineLimit, lineLimit > 0 else { return false }
        let hardLineBreaks = message.filter { $0 == "\n" }.count
        if hardLineBreaks >= lineLimit { return true }
        let visibleBudget = max(48, lineLimit * 24)
        return message.count > visibleBudget
    }

    private func reportTruncationIfNeeded(_ value: Bool) {
        guard lastReportedTruncates != value else { return }
        lastReportedTruncates = value
        onTruncationChange?(value)
    }

    private func emotePointSize(for emote: ReplyEmoteDTO) -> CGFloat {
        emote.size >= 2 ? 32 : 18
    }

    private func emotePointSize(for token: String) -> CGFloat {
        if let e = emotes.first(where: { $0.name == token }) {
            return emotePointSize(for: e)
        }
        return 18
    }

    // MARK: - Rendering

    private var rendered: Text {
        let segs = MediaTextParser.parse(message: message, emotes: emotes, jumps: jumpUrls)
        var out = Text("")
        var first = true
        for seg in segs {
            let part = render(segment: seg)
            out = first ? part : out + part
            first = false
        }
        return out
    }

    private func render(segment: MediaTextSegment) -> Text {
        switch segment {
        case .text(let s):
            return Text(s).foregroundColor(textColor)
        case .emote(let token):
            if let img = emoteImages[token] {
                return Text(Image(uiImage: img))
            }
            return Text(Image(uiImage: ReplyEmoteImageCache.placeholder(pointSize: emotePointSize(for: token))))
        case .link(let label, let url):
            return linkText(label: label, url: URL(string: url))
        case .time(let label, let seconds):
            guard let url = playbackContext?.url(seconds: seconds) else {
                return Text(label).foregroundColor(textColor)
            }
            return linkText(label: label, url: url)
        }
    }

    private func linkText(label: String, url: URL?) -> Text {
        var attr = AttributedString(label)
        attr.link = url
        attr.foregroundColor = IbiliTheme.accent
        return Text(attr).fontWeight(.medium)
    }

    // MARK: - Async emote fetch

    @MainActor
    private func loadEmotes() async {
        for e in emotes where !e.url.isEmpty && emoteImages[e.name] == nil {
            if let image = await ReplyEmoteImageCache.shared.image(for: e, pointSize: emotePointSize(for: e)) {
                emoteImages[e.name] = image
            }
        }
    }
}

@MainActor
private final class ReplyEmoteImageCache {
    static let shared = ReplyEmoteImageCache()

    private let renderedCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private static var placeholders: [Int: UIImage] = [:]

    func image(for emote: ReplyEmoteDTO, pointSize: CGFloat) async -> UIImage? {
        let cacheKey = "\(emote.url)#\(Int(pointSize.rounded()))" as NSString
        if let cached = renderedCache.object(forKey: cacheKey) {
            return cached
        }
        let taskKey = cacheKey as String
        if let task = inFlight[taskKey] {
            return await task.value
        }
        let task = Task<UIImage?, Never> {
            guard let url = URL(string: emote.url) else { return nil }
            let scale = UIScreen.main.scale
            guard let rawImage = await ImagePipeline.shared.image(for: url, maxPixelDimension: pointSize * scale) else { return nil }
            return try? await BlockingWorkQueue.images.run(priority: .utility) {
                Self.renderedSquare(rawImage, pointSize: pointSize, scale: scale)
            }
        }
        inFlight[taskKey] = task
        let image = await task.value
        inFlight[taskKey] = nil
        if let image {
            renderedCache.setObject(image, forKey: cacheKey, cost: ImageCache.decodedCost(of: image))
        }
        return image
    }

    static func placeholder(pointSize: CGFloat) -> UIImage {
        let key = Int(pointSize.rounded())
        if let cached = placeholders[key] { return cached }
        let size = CGSize(width: pointSize, height: pointSize)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            UIColor.clear.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        }
        placeholders[key] = image
        return image
    }

    private nonisolated static func renderedSquare(_ image: UIImage, pointSize: CGFloat, scale displayScale: CGFloat) -> UIImage {
        let canvas = CGSize(width: pointSize, height: pointSize)
        let imageSize = image.size
        let scale = min(canvas.width / max(imageSize.width, 1), canvas.height / max(imageSize.height, 1))
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawOrigin = CGPoint(
            x: (canvas.width - drawSize.width) / 2,
            y: (canvas.height - drawSize.height) / 2
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
    }
}
