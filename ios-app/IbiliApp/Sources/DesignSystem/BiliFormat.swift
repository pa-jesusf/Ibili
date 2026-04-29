import Foundation

/// Reusable formatters for Bilibili-style numeric and date display.
///
/// Centralised so feed cards, search cards, player chrome, etc. all
/// agree on the same wording — avoids "12.3万 / 12W / 123000" drift
/// across screens.
enum BiliFormat {
    /// Compact play / danmaku / like count.
    /// `123` → "123", `15234` → "1.5万", `123_456_789` → "1.2亿".
    static func compactCount(_ count: Int64) -> String {
        switch count {
        case 100_000_000...:
            return compact(Double(count) / 100_000_000.0, suffix: "亿")
        case 10_000...:
            return compact(Double(count) / 10_000.0, suffix: "万")
        default:
            return String(max(0, count))
        }
    }

    /// `H:MM:SS` if longer than an hour, otherwise `M:SS`.
    static func duration(_ seconds: Int64) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Human-friendly relative date for a unix timestamp (seconds).
    /// Returns `""` for zero/invalid timestamps so callers can hide the
    /// trailing line entirely. Mirrors what bilibili search results
    /// display in their app: "刚刚 / X分钟前 / X小时前 / X天前 /
    /// MM-dd / yyyy-MM-dd".
    static func relativeDate(_ unix: Int64, now: Date = Date()) -> String {
        guard unix > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let diff = now.timeIntervalSince(date)
        if diff < 0 { return staticDate(date, relativeTo: now) }
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60))分钟前" }
        if diff < 86_400 { return "\(Int(diff / 3600))小时前" }
        if diff < 86_400 * 7 { return "\(Int(diff / 86_400))天前" }
        return staticDate(date, relativeTo: now)
    }

    private static func compact(_ value: Double, suffix: String) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == floor(rounded) {
            return "\(Int(rounded))\(suffix)"
        }
        return String(format: "%.1f%@", rounded, suffix)
    }

    private static let sameYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd"
        return f
    }()

    private static let crossYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func staticDate(_ date: Date, relativeTo now: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return sameYearFormatter.string(from: date)
        }
        return crossYearFormatter.string(from: date)
    }
}
