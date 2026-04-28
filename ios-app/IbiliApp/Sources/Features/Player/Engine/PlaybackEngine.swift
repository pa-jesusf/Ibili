import AVFoundation
import Foundation

/// Outcome of preparing a stream: the AVPlayerItem ready to be handed to
/// AVPlayer plus engine telemetry that the view-model writes to AppLog.
struct EnginePreparation {
    let item: AVPlayerItem
    let logSummary: [String: String]
    let totalElapsedMs: Int
    let release: @MainActor () -> Void
}

/// Abstraction over how a `PlayUrlDTO` becomes an `AVPlayerItem`.
///
/// Only one production engine ships today (``HLSProxyEngine``): it runs an
/// in-process HLS proxy that re-packages DASH fMP4 fragments as HLS so
/// AVPlayer treats it as a native HLS stream — preserving native UI,
/// system Picture-in-Picture, and AirPlay. The protocol is preserved so
/// a future re-introduction of an alternate engine doesn't require a
/// player-view rewrite.
@MainActor
protocol PlaybackEngine: AnyObject {
    func makeItem(for source: PlayUrlDTO) async throws -> EnginePreparation
    /// Released when the player view disappears (or quality is being
    /// switched to a fresh source). Implementations must idempotently
    /// release any proxy tokens, sockets, or disk cache they hold.
    func tearDown()
}
