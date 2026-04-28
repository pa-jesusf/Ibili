import AVFoundation
import Foundation

/// Outcome of preparing a stream: the AVPlayerItem ready to be handed to
/// AVPlayer plus per-engine telemetry that the view-model writes to AppLog.
struct EnginePreparation {
    let item: AVPlayerItem
    let logSummary: [String: String]
    let totalElapsedMs: Int
}

/// Abstraction over how a `PlayUrlDTO` becomes an `AVPlayerItem`.
///
/// Two implementations live alongside each other:
/// * ``DirectAVPlayerEngine`` — legacy path, `AVMutableComposition` for
///   separate DASH video + audio. Reliable but suffers from the two-asset
///   rendezvous (each `AVURLAsset` must finish `loadTracks` + duration
///   before composition can begin), causing 6–32 s startup on iOS.
/// * ``HLSProxyEngine`` — default, runs an in-process HLS proxy that
///   re-packages DASH fMP4 fragments as HLS-with-EXT-X-MEDIA so AVPlayer
///   treats it as a native HLS stream. Native UI / system PiP / AirPlay are
///   preserved.
@MainActor
protocol PlaybackEngine: AnyObject {
    func makeItem(for source: PlayUrlDTO) async throws -> EnginePreparation
    /// Released when the player view disappears (or quality is being switched
    /// to a fresh source). Implementations must idempotently release any
    /// proxy tokens, sockets, or disk cache they hold.
    func tearDown()
}

enum PlayerEngineKind: String {
    case hlsProxy = "hls_proxy"
    case direct = "direct"

    var displayName: String {
        switch self {
        case .hlsProxy: return "HLS 代理（推荐）"
        case .direct:   return "AVPlayer 直拼（旧）"
        }
    }
}

@MainActor
enum PlaybackEngineFactory {
    static func make(kind: PlayerEngineKind) -> PlaybackEngine {
        switch kind {
        case .hlsProxy: return HLSProxyEngine.shared
        case .direct:   return DirectAVPlayerEngine.shared
        }
    }
}
