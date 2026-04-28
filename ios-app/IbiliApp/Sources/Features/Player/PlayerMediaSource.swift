@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

@MainActor
enum PlayerItemFactory {
    private struct LoadedAsset {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let duration: CMTime
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.1 Safari/605.1.15"
    private static let headerFields: [String: String] = [
        "User-Agent": userAgent,
        "Referer": "https://www.bilibili.com/",
    ]

    static func makeItem(from playInfo: PlayUrlDTO) async throws -> AVPlayerItem {
        let videoURLs = validURLs(primary: playInfo.url, backups: playInfo.backupUrls)
        guard let videoURL = videoURLs.first else {
            throw PlayerMediaSourceError.invalidURL(playInfo.url)
        }
        if let audioURLString = playInfo.audioUrl,
           let audioURL = URL(string: audioURLString),
           audioURL != videoURL {
            let audioURLs = validURLs(primary: audioURLString, backups: playInfo.audioBackupUrls)
            return try await makeComposedItem(videoURLs: videoURLs, audioURLs: audioURLs)
        }
        return try await makeSingleItem(urls: videoURLs)
    }

    static func makeSingleItem(urls: [URL]) async throws -> AVPlayerItem {
        let loaded = try await firstPlayableAsset(from: urls, mediaType: .video)
        let item = AVPlayerItem(asset: loaded.asset)
        item.audioTimePitchAlgorithm = .spectral
        return item
    }

    private static func makeComposedItem(videoURLs: [URL], audioURLs: [URL]) async throws -> AVPlayerItem {
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
        return item
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
            "AVURLAssetHTTPHeaderFieldsKey": headerFields,
        ])
    }

    private static func firstPlayableAsset(from urls: [URL], mediaType: AVMediaType) async throws -> LoadedAsset {
        var lastError: Error?
        for url in urls {
            let asset = makeAsset(url: url)
            do {
                async let tracks = asset.loadTracks(withMediaType: mediaType)
                async let duration = asset.load(.duration)
                let (loadedTracks, loadedDuration) = try await (tracks, duration)
                guard let track = loadedTracks.first else {
                    throw PlayerMediaSourceError.missingTrack("\(mediaType.rawValue) @ \(url.host ?? url.absoluteString)")
                }
                return LoadedAsset(asset: asset, track: track, duration: loadedDuration)
            } catch {
                lastError = PlayerMediaSourceError.assetLoadFailed(mediaType.rawValue, url: url, underlying: error)
            }
        }
        throw lastError ?? PlayerMediaSourceError.assetLoadFailed(mediaType.rawValue, url: urls.first, underlying: nil)
    }

    private static func minimumDuration(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        if !lhs.isNumeric { return rhs }
        if !rhs.isNumeric { return lhs }
        return CMTimeCompare(lhs, rhs) <= 0 ? lhs : rhs
    }
}

enum PlayerMediaSourceError: LocalizedError {
    case invalidURL(String)
    case missingTrack(String)
    case compositionFailed(String)
    case assetLoadFailed(String, url: URL?, underlying: Error?)

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