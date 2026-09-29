import SwiftUI

struct PlaybackTextContext {
    let identity: String
    let duration: Double
    let seek: (Int64) -> Void
    var contentVersion: String { "\(identity):\(duration)" }

    func url(seconds: Int64) -> URL? {
        guard PlaybackTimecode.isValid(seconds, duration: duration) else { return nil }
        var components = URLComponents()
        components.scheme = "ibili"
        components.host = "playback-time"
        components.path = "/\(identity)"
        components.queryItems = [URLQueryItem(name: "seconds", value: String(seconds))]
        return components.url
    }

    func handle(_ url: URL) -> Bool {
        guard url.scheme == "ibili", url.host == "playback-time" else { return false }
        guard url.lastPathComponent == identity,
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "seconds" })?.value,
              let seconds = Int64(raw), PlaybackTimecode.isValid(seconds, duration: duration) else { return true }
        seek(seconds)
        return true
    }
}

private struct PlaybackTextContextKey: EnvironmentKey {
    static let defaultValue: PlaybackTextContext? = nil
}

extension EnvironmentValues {
    var playbackTextContext: PlaybackTextContext? {
        get { self[PlaybackTextContextKey.self] }
        set { self[PlaybackTextContextKey.self] = newValue }
    }
}
