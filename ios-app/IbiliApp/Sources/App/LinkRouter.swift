import Foundation

enum LinkRouter {
    static func mapToInternalURL(_ raw: String, keyword: String = "") -> String {
        let source = raw.isEmpty ? keyword : raw
        guard !source.isEmpty else { return "about:blank" }
        if let searchKeyword = extractSearchKeyword(from: source) {
            return searchURL(keyword: searchKeyword)
        }
        if let bv = extractBV(from: source) ?? extractBV(from: keyword) {
            return "ibili://bv/\(bv)"
        }
        if let epID = extract(pattern: #"(?i)(?:/bangumi/play/|^)(?:ep)(\d+)"#, from: source)
            ?? extract(pattern: #"(?i)^ep(\d+)$"#, from: keyword) {
            return "ibili://pgc/ep/\(epID)"
        }
        if let seasonID = extract(pattern: #"(?i)(?:/bangumi/play/|^)(?:ss)(\d+)"#, from: source)
            ?? extract(pattern: #"(?i)^ss(\d+)$"#, from: keyword) {
            return "ibili://pgc/ss/\(seasonID)"
        }
        if let aid = extract(pattern: #"(?i)(?:^|/|[?&])av(\d+)"#, from: source) ?? extract(pattern: #"(?i)^av(\d+)"#, from: keyword) {
            return "ibili://av/\(aid)"
        }
        if let cvid = extractCV(from: source) ?? extractCV(from: keyword) {
            return "ibili://article/read/\(cvid)"
        }
        if let opusID = extract(pattern: #"(?i)/(?:opus|dynamic)/(\d+)"#, from: source)
            ?? extract(pattern: #"(?i)^opus(\d+)$"#, from: keyword) {
            return "ibili://article/opus/\(opusID)"
        }
        if let roomID = extract(pattern: #"(?i)live\.bilibili\.com/(?:h5/)?(\d+)"#, from: source) {
            return "ibili://live/\(roomID)"
        }
        if let mid = extract(pattern: #"(?i)space\.bilibili\.com/(\d+)"#, from: source) {
            return "ibili://space/\(mid)"
        }
        if raw.isEmpty {
            return searchURL(keyword: source)
        }
        return raw.isEmpty ? source : raw
    }

    static func searchURL(keyword: String) -> String {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "about:blank" }
        var components = URLComponents()
        components.scheme = "ibili"
        components.host = "search"
        components.queryItems = [URLQueryItem(name: "keyword", value: trimmed)]
        return components.string ?? "ibili://search?keyword=\(trimmed)"
    }

    static func extractBV(from raw: String) -> String? {
        extract(pattern: #"BV[0-9A-Za-z]{10}"#, from: raw)
    }

    static func extractCV(from raw: String) -> String? {
        extract(pattern: #"(?i)(?:^cv|/read/cv|cvid=)(\d+)"#, from: raw)
    }

    private static func extractSearchKeyword(from raw: String) -> String? {
        let candidates = raw.contains("://") ? [raw] : ["https://\(raw)", raw]
        for candidate in candidates {
            guard let components = URLComponents(string: candidate),
                  let host = components.host?.lowercased(),
                  host.contains("search.bilibili.com") else { continue }
            let keyword = components.queryItems?.first { $0.name == "keyword" }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let keyword, !keyword.isEmpty {
                return keyword
            }
        }
        return nil
    }

    private static func extract(pattern: String, from raw: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range) else { return nil }
        let group = match.numberOfRanges > 1 ? 1 : 0
        guard let resultRange = Range(match.range(at: group), in: raw) else { return nil }
        return String(raw[resultRange])
    }
}
