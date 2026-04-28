import Foundation

/// HTTP constants used both when reaching Bilibili CDNs directly and when
/// proxying their bytes through the in-process HLS server. Centralised so
/// that engine and proxy paths stay in lock-step.
enum BiliHTTP {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.1 Safari/605.1.15"
    static let referer = "https://www.bilibili.com/"

    static var headers: [String: String] {
        ["User-Agent": userAgent, "Referer": referer]
    }
}
