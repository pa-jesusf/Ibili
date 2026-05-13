import SwiftUI
import UIKit

/// Renders a Bilibili reply message with inline emotes and tappable
/// jump-link chips. The view is `Text`-based (no `UITextView`) so it
/// composes with `LazyVStack` perf and respects the surrounding font /
/// foreground style.
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

    var body: some View {
        let estimatedTruncates = estimatedTruncation
        measuredText
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
        let segs = tokenize(message: message,
                             emotes: emotes,
                             jumps: jumpUrls)
        var out = Text("")
        var first = true
        for seg in segs {
            let part = render(segment: seg)
            out = first ? part : out + part
            first = false
        }
        return out
    }

    private func render(segment: Segment) -> Text {
        switch segment {
        case .text(let s):
            return Text(s).foregroundColor(textColor)
        case .emote(let token):
            if let img = emoteImages[token] {
                return Text(Image(uiImage: img))
            }
            return Text(Image(uiImage: ReplyEmoteImageCache.placeholder(pointSize: emotePointSize(for: token))))
        case .link(let label, let url):
            var attr = AttributedString(label)
            if let parsed = URL(string: url) ?? encodedURL(from: url) {
                attr.link = parsed
            }
            attr.foregroundColor = IbiliTheme.accent
            return Text(attr).fontWeight(.medium)
        }
    }

    private func encodedURL(from raw: String) -> URL? {
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: encoded)
    }

    // MARK: - Tokeniser

    private enum Segment {
        case text(String)
        case emote(String)            // includes brackets
        case link(String, String)     // (display, url)
    }

    private func tokenize(message: String,
                          emotes: [ReplyEmoteDTO],
                          jumps: [ReplyJumpUrlDTO]) -> [Segment] {
        // Build a quick lookup of all anchors we might splice in.
        let emoteSet = Set(emotes.map { $0.name })
        let jumpDict = Dictionary(uniqueKeysWithValues: jumps.compactMap { j -> (String, ReplyJumpUrlDTO)? in
            j.keyword.isEmpty ? nil : (j.keyword, j)
        })

        var out: [Segment] = []
        var buf = ""

        // Walk char-by-char so multi-byte CJK + ASCII mix correctly.
        let chars = Array(message)
        var i = 0
        while i < chars.count {
            // Try emote `[xxx]` at this position.
            if chars[i] == "[" {
                if let close = chars[i...].firstIndex(of: "]") {
                    let token = String(chars[i...close])
                    if emoteSet.contains(token) {
                        if !buf.isEmpty { out.append(.text(buf)); buf.removeAll() }
                        out.append(.emote(token))
                        i = close + 1
                        continue
                    }
                }
            }
            // Try jump-keyword starting here. Match longest keyword first.
            var matched = false
            for keyword in jumpDict.keys.sorted(by: { $0.count > $1.count }) {
                let kchars = Array(keyword)
                if i + kchars.count <= chars.count, Array(chars[i..<i+kchars.count]) == kchars {
                    if !buf.isEmpty { out.append(.text(buf)); buf.removeAll() }
                    let j = jumpDict[keyword]!
                    let url = mapJumpURL(keyword: keyword, raw: j.url)
                    let label = j.title.isEmpty ? keyword : j.title
                    out.append(.link(label, url))
                    i += kchars.count
                    matched = true
                    break
                }
            }
            if matched { continue }

            if let detected = detectInlineLink(chars: chars, start: i) {
                if !buf.isEmpty { out.append(.text(buf)); buf.removeAll() }
                out.append(.link(detected.label, detected.url))
                i = detected.end
                continue
            }

            buf.append(chars[i])
            i += 1
        }
        if !buf.isEmpty { out.append(.text(buf)) }
        return out
    }

    /// Translate the upstream `pc_url` into our internal `ibili://` scheme
    /// when possible, so the OpenURLAction handler can route in-app.
    private func mapJumpURL(keyword: String, raw: String) -> String {
        let mapped = LinkRouter.mapToInternalURL(raw, keyword: keyword)
        if mapped == raw, looksLikeSearchTag(keyword: keyword, raw: raw) {
            return LinkRouter.searchURL(keyword: cleanedSearchKeyword(keyword))
        }
        return mapped
    }

    private func detectInlineLink(chars: [Character], start: Int) -> (label: String, url: String, end: Int)? {
        let remaining = String(chars[start...])
        let patterns = [
            #"^BV[0-9A-Za-z]{10}"#,
            #"(?i)^av\d+"#,
            #"(?i)^cv\d+"#,
            #"(?i)^opus\d+"#,
            #"^#[^#\s\u{3000}][^#\n\r]*#"#,
            #"^https?://[^\s\u{3000}]+"#,
            #"^www\.[^\s\u{3000}]+"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(remaining.startIndex..<remaining.endIndex, in: remaining)
            guard let match = regex.firstMatch(in: remaining, range: range),
                  match.range.location == 0,
                  let swiftRange = Range(match.range, in: remaining) else { continue }
            let label = String(remaining[swiftRange])
            if label.hasPrefix("#"), label.hasSuffix("#"), label.count > 2 {
                let keyword = String(label.dropFirst().dropLast())
                return (label, LinkRouter.searchURL(keyword: keyword), start + label.count)
            }
            let rawURL = label.hasPrefix("www.") ? "https://\(label)" : label
            return (label, LinkRouter.mapToInternalURL(rawURL, keyword: label), start + label.count)
        }
        return nil
    }

    private func looksLikeSearchTag(keyword: String, raw: String) -> Bool {
        let source = raw.isEmpty ? keyword : raw
        let lower = source.lowercased()
        return lower.contains("search.bilibili.com")
            || lower.contains("word_search")
            || lower.contains("wordsearch")
            || lower.contains("search_type")
            || (!keyword.isEmpty && raw.isEmpty)
    }

    private func cleanedSearchKeyword(_ keyword: String) -> String {
        var text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#"), text.hasSuffix("#"), text.count > 2 {
            text.removeFirst()
            text.removeLast()
        }
        return text
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

    private let renderedCache = NSCache<NSString, UIImage>()
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
            let rawKey = url as NSURL
            let rawImage: UIImage
            if let cached = ImageCache.shared.cache.object(forKey: rawKey) {
                rawImage = cached
            } else {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        return nil
                    }
                    guard let decoded = UIImage(data: data) else { return nil }
                    ImageCache.shared.cache.setObject(decoded, forKey: rawKey, cost: data.count)
                    rawImage = decoded
                } catch {
                    return nil
                }
            }
            return Self.renderedSquare(rawImage, pointSize: pointSize)
        }
        inFlight[taskKey] = task
        let image = await task.value
        inFlight[taskKey] = nil
        if let image {
            renderedCache.setObject(image, forKey: cacheKey, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
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

    private static func renderedSquare(_ image: UIImage, pointSize: CGFloat) -> UIImage {
        let canvas = CGSize(width: pointSize, height: pointSize)
        let imageSize = image.size
        let scale = min(canvas.width / max(imageSize.width, 1), canvas.height / max(imageSize.height, 1))
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawOrigin = CGPoint(
            x: (canvas.width - drawSize.width) / 2,
            y: (canvas.height - drawSize.height) / 2
        )
        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
    }
}
