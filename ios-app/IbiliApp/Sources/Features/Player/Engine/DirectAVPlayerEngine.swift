@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Legacy engine: builds an AVPlayerItem with an `AVMutableComposition`
/// stitching separate video + audio DASH tracks. Kept behind a setting as
/// a fallback while the HLS proxy engine is being battle-tested.
///
/// This is a thin re-packaging of the previous `PlayerItemFactory` —
/// behaviour-preserving, so any A/B regression points cleanly back at the
/// new HLS path.
@MainActor
final class DirectAVPlayerEngine: PlaybackEngine {
    static let shared = DirectAVPlayerEngine()
    private init() {}

    func makeItem(for source: PlayUrlDTO) async throws -> EnginePreparation {
        let prep = try await DirectPlayerItemBuilder.makeItem(from: source)
        var summary: [String: String] = [
            "engine": "direct",
            "videoCdn": prep.video.winnerHost,
            "videoOpenMs": String(prep.video.winnerElapsedMs),
            "videoAttempts": prep.video.attempts.joined(separator: " | "),
        ]
        if let audio = prep.audio {
            summary["audioCdn"] = audio.winnerHost
            summary["audioOpenMs"] = String(audio.winnerElapsedMs)
            summary["audioAttempts"] = audio.attempts.joined(separator: " | ")
        } else {
            summary["audioCdn"] = "-"
            summary["audioOpenMs"] = "-"
            summary["audioAttempts"] = "-"
        }
        return EnginePreparation(
            item: prep.item,
            logSummary: summary,
            totalElapsedMs: prep.totalElapsedMs
        )
    }

    func tearDown() { /* nothing to release */ }
}

// MARK: - Internal builder (former PlayerItemFactory)

/// Lightweight summary of how a single AVURLAsset open performed. Surfaced
/// so the player layer can log "which CDN won and how long it took",
/// mirroring upstream PiliPlus's media_kit timing diagnostics.
struct AssetOpenTelemetry: Sendable {
    let mediaType: String
    let winnerHost: String
    let winnerURL: URL
    let winnerElapsedMs: Int
    /// Per-candidate trace lines. Each entry is `host elapsedMs outcome`.
    let attempts: [String]
}

/// Collected telemetry for a fully prepared player item.
struct DirectPlayerItemPreparation: Sendable {
    let item: AVPlayerItem
    let video: AssetOpenTelemetry
    let audio: AssetOpenTelemetry?
    let totalElapsedMs: Int
}

@MainActor
enum DirectPlayerItemBuilder {
    private struct LoadedAsset {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let duration: CMTime
        let url: URL
        let elapsedMs: Int
        let attempts: [String]
    }

    static let userAgent = BiliHTTP.userAgent
    static let referer = BiliHTTP.referer

    private static let headerFields: [String: String] = [
        "User-Agent": userAgent,
        "Referer": referer,
    ]

    static func makeItem(from playInfo: PlayUrlDTO) async throws -> DirectPlayerItemPreparation {
        let videoURLs = validURLs(primary: playInfo.url, backups: playInfo.backupUrls)
        guard !videoURLs.isEmpty else {
            throw PlayerMediaSourceError.invalidURL(playInfo.url)
        }
        let totalStart = CFAbsoluteTimeGetCurrent()
        if let audioURLString = playInfo.audioUrl,
           let audioURL = URL(string: audioURLString),
           audioURL != videoURLs.first {
            let audioURLs = validURLs(primary: audioURLString, backups: playInfo.audioBackupUrls)
            return try await makeComposedItem(videoURLs: videoURLs, audioURLs: audioURLs, totalStart: totalStart)
        }
        return try await makeSingleItem(urls: videoURLs, totalStart: totalStart)
    }

    private static func makeSingleItem(urls: [URL], totalStart: CFAbsoluteTime) async throws -> DirectPlayerItemPreparation {
        let loaded = try await firstPlayableAsset(from: urls, mediaType: .video)
        let item = AVPlayerItem(asset: loaded.asset)
        item.audioTimePitchAlgorithm = .spectral
        item.preferredForwardBufferDuration = 1
        let totalMs = Int((CFAbsoluteTimeGetCurrent() - totalStart) * 1000)
        return DirectPlayerItemPreparation(
            item: item,
            video: telemetry(from: loaded, mediaType: "video"),
            audio: nil,
            totalElapsedMs: totalMs
        )
    }

    private static func makeComposedItem(videoURLs: [URL],
                                         audioURLs: [URL],
                                         totalStart: CFAbsoluteTime) async throws -> DirectPlayerItemPreparation {
        async let videoLoaded = firstPlayableAsset(from: videoURLs, mediaType: .video)
        async let audioLoaded = firstPlayableAsset(from: audioURLs, mediaType: .audio)
        let (videoAsset, audioAsset) = try await (videoLoaded, audioLoaded)

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video,
                                                                     preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PlayerMediaSourceError.compositionFailed("video")
        }
        guard let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                     preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PlayerMediaSourceError.compositionFailed("audio")
        }

        let mediaDuration = minimumDuration(videoAsset.duration, audioAsset.duration)
        let timeRange = CMTimeRange(start: .zero, duration: mediaDuration)

        try compositionVideoTrack.insertTimeRange(timeRange, of: videoAsset.track, at: .zero)
        try compositionAudioTrack.insertTimeRange(timeRange, of: audioAsset.track, at: .zero)
        compositionVideoTrack.preferredTransform = try await videoAsset.track.load(.preferredTransform)

        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = .spectral
        item.preferredForwardBufferDuration = 1
        let totalMs = Int((CFAbsoluteTimeGetCurrent() - totalStart) * 1000)
        return DirectPlayerItemPreparation(
            item: item,
            video: telemetry(from: videoAsset, mediaType: "video"),
            audio: telemetry(from: audioAsset, mediaType: "audio"),
            totalElapsedMs: totalMs
        )
    }

    private static func telemetry(from asset: LoadedAsset, mediaType: String) -> AssetOpenTelemetry {
        AssetOpenTelemetry(
            mediaType: mediaType,
            winnerHost: asset.url.host ?? asset.url.absoluteString,
            winnerURL: asset.url,
            winnerElapsedMs: asset.elapsedMs,
            attempts: asset.attempts
        )
    }

    private static func validURLs(primary: String, backups: [String]) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for value in [primary] + backups {
            guard let url = URL(string: value), seen.insert(url).inserted else { continue }
            result.append(url)
        }
        return result
    }

    private static func makeAsset(url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            AVURLAssetHTTPUserAgentKey as String: userAgent,
            AVURLAssetPreferPreciseDurationAndTimingKey as String: false,
            "AVURLAssetHTTPHeaderFieldsKey": headerFields,
        ])
    }

    /// Concurrently race all candidate URLs and return the first asset to
    /// load both its track list and duration. Mirrors upstream's behavior
    /// of trying multiple CDN URLs in parallel rather than serially.
    private static func firstPlayableAsset(from urls: [URL], mediaType: AVMediaType) async throws -> LoadedAsset {
        struct Outcome: Sendable { let url: URL; let elapsedMs: Int; let result: Result<RaceSuccess, Error> }
        struct RaceSuccess: Sendable { let asset: AVURLAsset; let track: AVAssetTrack; let duration: CMTime }

        let raceStart = CFAbsoluteTimeGetCurrent()
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            for url in urls {
                group.addTask { @Sendable in
                    let start = CFAbsoluteTimeGetCurrent()
                    let asset = await DirectPlayerItemBuilder.makeAsset(url: url)
                    do {
                        async let tracks = asset.loadTracks(withMediaType: mediaType)
                        async let duration = asset.load(.duration)
                        let (loadedTracks, loadedDuration) = try await (tracks, duration)
                        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                        guard let track = loadedTracks.first else {
                            return Outcome(url: url, elapsedMs: elapsed, result: .failure(
                                PlayerMediaSourceError.missingTrack("\(mediaType.rawValue) @ \(url.host ?? url.absoluteString)")))
                        }
                        return Outcome(url: url, elapsedMs: elapsed, result: .success(
                            RaceSuccess(asset: asset, track: track, duration: loadedDuration)))
                    } catch {
                        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                        return Outcome(url: url, elapsedMs: elapsed, result: .failure(
                            PlayerMediaSourceError.assetLoadFailed(mediaType.rawValue, url: url, underlying: error)))
                    }
                }
            }

            var attempts: [String] = []
            var errors: [Error] = []
            while let outcome = try await group.next() {
                switch outcome.result {
                case .success(let success):
                    attempts.append("\(outcome.url.host ?? "?") \(outcome.elapsedMs)ms ok")
                    AppLog.debug("player", "CDN 候选完成", metadata: [
                        "media": mediaType.rawValue,
                        "host": outcome.url.host ?? outcome.url.absoluteString,
                        "elapsedMs": String(outcome.elapsedMs),
                        "outcome": "ok",
                    ])
                    group.cancelAll()
                    let raceMs = Int((CFAbsoluteTimeGetCurrent() - raceStart) * 1000)
                    AppLog.info("player", "CDN 选中", metadata: [
                        "media": mediaType.rawValue,
                        "host": outcome.url.host ?? outcome.url.absoluteString,
                        "elapsedMs": String(outcome.elapsedMs),
                        "raceMs": String(raceMs),
                        "candidates": String(urls.count),
                    ])
                    return LoadedAsset(asset: success.asset,
                                       track: success.track,
                                       duration: success.duration,
                                       url: outcome.url,
                                       elapsedMs: outcome.elapsedMs,
                                       attempts: attempts)
                case .failure(let err):
                    let detail = failureDetail(err)
                    attempts.append("\(outcome.url.host ?? "?") \(outcome.elapsedMs)ms \(detail)")
                    errors.append(err)
                    AppLog.warning("player", "CDN 候选失败", metadata: [
                        "media": mediaType.rawValue,
                        "host": outcome.url.host ?? outcome.url.absoluteString,
                        "elapsedMs": String(outcome.elapsedMs),
                        "error": detail,
                    ])
                }
            }
            throw errors.last ?? PlayerMediaSourceError.assetLoadFailed(mediaType.rawValue, url: urls.first, underlying: nil)
        }
    }

    private static func minimumDuration(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        if !lhs.isNumeric { return rhs }
        if !rhs.isNumeric { return lhs }
        return CMTimeCompare(lhs, rhs) <= 0 ? lhs : rhs
    }

    private static func failureDetail(_ error: Error) -> String {
        if let mediaError = error as? PlayerMediaSourceError {
            return mediaError.debugSummary
        }
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code) \(nsError.localizedDescription)"
    }
}

enum PlayerMediaSourceError: LocalizedError {
    case invalidURL(String)
    case missingTrack(String)
    case compositionFailed(String)
    case assetLoadFailed(String, url: URL?, underlying: Error?)

    var debugSummary: String {
        switch self {
        case .invalidURL(let value):
            return "invalid-url \(value)"
        case .missingTrack(let mediaType):
            return "missing-track \(mediaType)"
        case .compositionFailed(let mediaType):
            return "composition-failed \(mediaType)"
        case .assetLoadFailed(_, _, let underlying):
            if let nsError = underlying as NSError? {
                return "\(nsError.domain)#\(nsError.code) \(nsError.localizedDescription)"
            }
            return "asset-load-failed"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "无效的播放地址: \(value)"
        case .missingTrack(let mediaType):
            return "播放源缺少 \(mediaType) 轨道"
        case .compositionFailed(let mediaType):
            return "无法构建 \(mediaType) 组合轨道"
        case .assetLoadFailed(let key, let url, let underlying):
            let host = url?.host ?? url?.absoluteString ?? "unknown"
            if let nsError = underlying as NSError? {
                return "资源加载失败: \(key) @ \(host) [\(nsError.domain)#\(nsError.code)] \(nsError.localizedDescription)"
            }
            return "资源加载失败: \(key) @ \(host)"
        }
    }
}
