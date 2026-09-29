import Foundation

enum MediaTextSegment: Equatable {
    case text(String)
    case emote(String)
    case link(label: String, url: String)
    case time(label: String, seconds: Int64)
}

enum PlaybackTimecode {
    static let pattern = #"(?<![\d:：-])(?:\d+[:：])?\d+[:：][0-5]?\d(?![\d:：])"#
    private static let regex = try! NSRegularExpression(pattern: pattern)

    static func seconds(_ text: String) -> Int64? {
        let parts = text.replacingOccurrences(of: "：", with: ":").split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = parts.compactMap { Int64($0) }
        guard numbers.count == parts.count, numbers.last! < 60,
              numbers.count != 3 || numbers[1] < 60 else { return nil }
        var total: Int64 = 0
        for number in numbers {
            let (scaled, overflow) = total.multipliedReportingOverflow(by: 60)
            let (next, additionOverflow) = scaled.addingReportingOverflow(number)
            guard !overflow, !additionOverflow else { return nil }
            total = next
        }
        return total
    }

    static func isValid(_ seconds: Int64, duration: Double) -> Bool {
        duration.isFinite && duration > 0 && seconds >= 0 && Double(seconds) <= duration
    }

    static func firstValid(in text: String, duration: Double) -> Int64? {
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let value = seconds(String(text[range])),
                  isValid(value, duration: duration) else { continue }
            return value
        }
        return nil
    }
}

/// One tokenization pass shared by comments and descriptions. Server anchors
/// precede detection, so times embedded in URLs/emotes/usernames aren't split.
enum MediaTextParser {
    private final class Box: NSObject {
        let segments: [MediaTextSegment]
        init(_ segments: [MediaTextSegment]) { self.segments = segments }
    }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>(); cache.countLimit = 512; return cache
    }()
    private static let inlinePattern = #"(?:https?|bilibili|ibili)://[^\s<>\u3000，。！？；：“”‘’《》【】]+|www\.[^\s<>\u3000，。！？；：“”‘’《》【】]+|(?<![A-Za-z0-9])(?:BV[0-9A-Za-z]{10}|av\d+|cv\d+|opus\d+|ep\d+|ss\d+)(?![A-Za-z0-9])|#[^#\s][^#\n\r]*#|"# + PlaybackTimecode.pattern

    static func parse(message: String, emotes: [ReplyEmoteDTO] = [], jumps: [ReplyJumpUrlDTO] = []) -> [MediaTextSegment] {
        let emoteNames = Set(emotes.map(\.name).filter { !$0.isEmpty })
        let links = jumps.reduce(into: [String: ReplyJumpUrlDTO]()) { result, jump in
            if !jump.keyword.isEmpty, result[jump.keyword] == nil { result[jump.keyword] = jump }
        }
        let linkKeys = links.keys.sorted().flatMap {
            [$0, links[$0]!.title, links[$0]!.url]
        }
        let keyParts = [[message], emoteNames.sorted(), linkKeys]
        let key = (String(data: try! JSONEncoder().encode(keyParts), encoding: .utf8)!) as NSString
        if let box = cache.object(forKey: key) { return box.segments }
        let anchors = Set(links.keys).union(emoteNames).sorted {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }.map(NSRegularExpression.escapedPattern(for:))
        let pattern = (anchors + ["(?i:" + inlinePattern + ")"]).joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [.text(message)] }
        let ns = message as NSString
        var segments: [MediaTextSegment] = []
        var offset = 0
        for match in regex.matches(in: message, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > offset { segments.append(.text(ns.substring(with: NSRange(location: offset, length: match.range.location - offset)))) }
            let token = ns.substring(with: match.range)
            if emoteNames.contains(token) {
                segments.append(.emote(token))
            } else if let jump = links[token] {
                segments.append(.link(label: jump.title.isEmpty ? token : jump.title,
                                      url: LinkRouter.mapToInternalURL(jump.url, keyword: token)))
            } else if let seconds = PlaybackTimecode.seconds(token) {
                segments.append(.time(label: token, seconds: seconds))
            } else if token.first?.isNumber == true {
                // A time-shaped token can still have invalid minutes or overflow.
                segments.append(.text(token))
            } else if token.hasPrefix("#"), token.hasSuffix("#") {
                segments.append(.link(label: token, url: LinkRouter.searchURL(keyword: String(token.dropFirst().dropLast()))))
            } else {
                let label = trimmingURLPunctuation(token)
                segments.append(.link(label: label, url: LinkRouter.mapToInternalURL(label)))
                if label != token { segments.append(.text(String(token.dropFirst(label.count)))) }
            }
            offset = NSMaxRange(match.range)
        }
        if offset < ns.length { segments.append(.text(ns.substring(from: offset))) }
        cache.setObject(Box(segments), forKey: key)
        return segments
    }

    private static func trimmingURLPunctuation(_ value: String) -> String {
        var result = value
        while let last = result.last, "。，、！？；：,.!;\"'“”‘’》】".contains(last) { result.removeLast() }
        for (open, close) in [("(", ")"), ("（", "）"), ("[", "]")] {
            while result.hasSuffix(close), result.components(separatedBy: close).count > result.components(separatedBy: open).count { result.removeLast() }
        }
        return result
    }
}
