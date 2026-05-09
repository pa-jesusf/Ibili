import Foundation

enum LinkRouter {
    static func mapToInternalURL(_ raw: String, keyword: String = "") -> String {
        let source = raw.isEmpty ? keyword : raw
        guard !source.isEmpty else { return "about:blank" }
        if let bv = extractBV(from: source) ?? extractBV(from: keyword) {
            return "ibili://bv/\(bv)"
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
        return raw.isEmpty ? source : raw
    }

    static func extractBV(from raw: String) -> String? {
        extract(pattern: #"BV[0-9A-Za-z]{10}"#, from: raw)
    }

    static func extractCV(from raw: String) -> String? {
        extract(pattern: #"(?i)(?:^cv|/read/cv|cvid=)(\d+)"#, from: raw)
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
