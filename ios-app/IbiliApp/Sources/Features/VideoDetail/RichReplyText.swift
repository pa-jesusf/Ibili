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
    @State private var truncates: Bool = false

    var body: some View {
        measuredText
            .lineLimit(lineLimit)
            .lineSpacing(2)
            .foregroundStyle(textColor)
            .background(measureGeometry)
            .task(id: emotes.map { $0.url }.joined(separator: "|")) {
                await loadEmotes()
            }
            .onAppear {
                onTruncationChange?(truncates)
            }
            .onChange(of: truncates) { newValue in
                onTruncationChange?(newValue)
            }
    }

    private var measuredText: Text {
        rendered
            .font(font)
    }

    private var measureGeometry: some View {
        Group {
            if let lineLimit {
                measuredText
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .background(GeometryReader { full in
                        measuredText
                            .lineSpacing(2)
                            .lineLimit(lineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { clipped in
                                Color.clear
                                    .onAppear {
                                        updateTruncation(clippedHeight: clipped.size.height,
                                                         fullHeight: full.size.height)
                                    }
                                    .onChange(of: emoteImages.count) { _ in
                                        updateTruncation(clippedHeight: clipped.size.height,
                                                         fullHeight: full.size.height)
                                    }
                            })
                            .hidden()
                    })
            }
        }
    }

    private func updateTruncation(clippedHeight: CGFloat, fullHeight: CGFloat) {
        truncates = clippedHeight < fullHeight - 1
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
            return Text(s)
        case .emote(let token):
            if let img = emoteImages[token] {
                let size = emoteSize(for: token)
                let scaled = img.resized(toHeight: size)
                return Text(Image(uiImage: scaled))
            }
            // While loading: keep the bracketed token as plain text so
            // the layout doesn't reflow when the image arrives.
            return Text(token).foregroundColor(.secondary)
        case .link(let label, let url):
            // Markdown link → SwiftUI Text picks it up as a tappable
            // run that emits the URL into the OpenURLAction env.
            let escaped = label.replacingOccurrences(of: "]", with: "\\]")
            let md = "[\(escaped)](\(url))"
            if let attr = try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                return Text(attr)
            }
            return Text(label).foregroundColor(IbiliTheme.accent)
        }
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
        LinkRouter.mapToInternalURL(raw, keyword: keyword)
    }

    private func detectInlineLink(chars: [Character], start: Int) -> (label: String, url: String, end: Int)? {
        let remaining = String(chars[start...])
        let patterns = [
            #"^BV[0-9A-Za-z]{10}"#,
            #"(?i)^av\d+"#,
            #"(?i)^cv\d+"#,
            #"(?i)^opus\d+"#,
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
            let rawURL = label.hasPrefix("www.") ? "https://\(label)" : label
            return (label, LinkRouter.mapToInternalURL(rawURL, keyword: label), start + label.count)
        }
        return nil
    }

    private func emoteSize(for token: String) -> CGFloat {
        // Honour upstream `meta.size` (1=small/inline, 2=large) — the
        // large emotes are roughly 32pt vs 18pt for small.
        if let e = emotes.first(where: { $0.name == token }), e.size >= 2 { return 32 }
        return 18
    }

    // MARK: - Async emote fetch

    @MainActor
    private func loadEmotes() async {
        for e in emotes where !e.url.isEmpty && emoteImages[e.name] == nil {
            guard let url = URL(string: e.url) else { continue }
            let key = url as NSURL
            if let cached = ImageCache.shared.cache.object(forKey: key) {
                emoteImages[e.name] = cached
                continue
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let img = UIImage(data: data) else { continue }
                ImageCache.shared.cache.setObject(img, forKey: key, cost: data.count)
                emoteImages[e.name] = img
            } catch {
                // Silent — token will keep showing as bracketed text.
            }
        }
    }
}

private extension UIImage {
    func resized(toHeight h: CGFloat) -> UIImage {
        let scale = h / max(size.height, 1)
        let target = CGSize(width: size.width * scale, height: h)
        let r = UIGraphicsImageRenderer(size: target)
        return r.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
