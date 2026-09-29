import Foundation

enum LinkRouter {
    static func mapToInternalURL(_ raw: String, keyword: String = "") -> String {
        let source = raw.isEmpty ? keyword : raw
        guard !source.isEmpty else { return "about:blank" }
        if let direct = identifierURL(source) { return direct }
        let normalized = source.hasPrefix("//") ? "https:" + source
            : source.lowercased().hasPrefix("www.") ? "https://" + source : source
        guard let components = URLComponents(string: normalized), let scheme = components.scheme?.lowercased() else {
            return raw.isEmpty ? searchURL(keyword: keyword) : normalized
        }
        if scheme == "ibili" { return normalized }
        let host = components.host?.lowercased() ?? ""
        let native = scheme == "bilibili"
        guard native || (["http", "https"].contains(scheme) && (host == "bilibili.com" || host.hasSuffix(".bilibili.com"))) else {
            // Never turn another site's path or query containing a BV number into a video.
            return normalized
        }
        let parts = components.path.split(separator: "/").map(String.init)
        let query = components.queryItems ?? []
        func videoURL(_ path: String) -> String {
            guard var target = URLComponents(string: path) else { return path }
            let playbackQuery = VideoLinkRequest.playbackQuery(in: components)
            target.queryItems = playbackQuery.isEmpty ? nil : playbackQuery
            return target.string ?? path
        }
        func value(_ key: String) -> String? { query.first { $0.name == key }?.value }
        func number(_ value: String?) -> String? {
            guard let value, let n = Int64(value), n > 0 else { return nil }
            return String(n)
        }
        if host == "search.bilibili.com" || (native && host == "search") {
            return value("keyword").map(searchURL(keyword:)) ?? normalized
        }
        if host == "space.bilibili.com" || (native && ["space", "author"].contains(host)) {
            return number(parts.first).map { "ibili://space/\($0)" } ?? normalized
        }
        if host == "live.bilibili.com" || (native && host == "live") {
            return number(parts.last).map { "ibili://live/\($0)" } ?? normalized
        }
        if host == "t.bilibili.com" {
            return number(parts.first).map { "ibili://article/opus/\($0)" } ?? normalized
        }
        if native && host == "video" {
            if let first = parts.first, let mapped = identifierURL(first),
               mapped.hasPrefix("ibili://bv/") || mapped.hasPrefix("ibili://av/") { return videoURL(mapped) }
            if let aid = number(parts.first) { return videoURL("ibili://av/\(aid)") }
            if parts.isEmpty, let bv = value("bvid").flatMap(identifierURL), bv.hasPrefix("ibili://bv/") { return videoURL(bv) }
            return normalized
        }
        if let first = parts.first {
            if ["video", "bangumi", "read"].contains(first), let last = parts.last, let mapped = identifierURL(last) {
                if first == "video", mapped.hasPrefix("ibili://bv/") || mapped.hasPrefix("ibili://av/") { return videoURL(mapped) }
                if first == "bangumi", mapped.hasPrefix("ibili://pgc/") { return videoURL(mapped) }
                if first == "read", mapped.hasPrefix("ibili://article/read/") { return mapped }
            }
            if ["opus", "dynamic"].contains(first), let id = number(parts.last) { return "ibili://article/opus/\(id)" }
        }
        if native && ["article", "read"].contains(host), let id = number(parts.last) { return "ibili://article/read/\(id)" }
        if native && ["pgc", "bangumi"].contains(host), let last = parts.last {
            if let mapped = identifierURL(last), mapped.hasPrefix("ibili://pgc/") { return videoURL(mapped) }
            if parts.first == "season", let id = number(last) {
                return videoURL("ibili://pgc/\(parts.contains("ep") ? "ep" : "ss")/\(id)")
            }
        }
        if let cvid = number(value("cvid")), components.path.contains("note") { return "ibili://article/read/\(cvid)" }
        return normalized
    }

    static func searchURL(keyword: String) -> String {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "about:blank" }
        var components = URLComponents()
        components.scheme = "ibili"
        components.host = "search"
        components.queryItems = [URLQueryItem(name: "keyword", value: trimmed)]
        return components.string ?? "about:blank"
    }

    static func isShortLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
            ["b23.tv", "bili2233.cn"].contains(url.host?.lowercased() ?? "")
    }

    /// Resolve only user-tapped Bilibili short links, without account cookies.
    static func resolveShortLink(_ url: URL) async -> URL {
        guard isShortLink(url) else { return url }
        var secure = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        secure.scheme = "https"
        var request = URLRequest(url: secure.url ?? url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request), let destination = response.url,
              ["https", "http"].contains(destination.scheme?.lowercased() ?? "") else { return url }
        return URL(string: mapToInternalURL(destination.absoluteString)) ?? destination
    }

    static func extractBV(from raw: String) -> String? {
        extract(pattern: #"(?i)BV[0-9A-Za-z]{10}"#, from: raw).map { "BV" + $0.dropFirst(2) }
    }

    static func extractCV(from raw: String) -> String? {
        extract(pattern: #"(?i)(?:^cv|/read/cv|cvid=)(\d+)"#, from: raw)
    }

    private static func identifierURL(_ text: String) -> String? {
        if text.range(of: #"(?i)^BV[0-9A-Za-z]{10}$"#, options: .regularExpression) != nil {
            return "ibili://bv/BV" + text.dropFirst(2)
        }
        for (prefix, target) in [("av", "av"), ("cv", "article/read"), ("opus", "article/opus"), ("ep", "pgc/ep"), ("ss", "pgc/ss")] {
            if let id = extract(pattern: "(?i)^" + prefix + #"(\d+)$"#, from: text), let number = Int64(id), number > 0 {
                return "ibili://\(target)/\(number)"
            }
        }
        return nil
    }

    private static func extract(pattern: String, from raw: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return nil }
        let group = match.numberOfRanges > 1 ? 1 : 0
        guard let range = Range(match.range(at: group), in: raw) else { return nil }
        return String(raw[range])
    }
}
