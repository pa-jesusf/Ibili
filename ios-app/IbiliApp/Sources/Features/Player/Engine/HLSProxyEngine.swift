import AVFoundation
import Foundation

/// Default playback engine.
///
/// 1. Take the picked video (and optional audio) URL out of `PlayUrlDTO`.
/// 2. Race a small Range probe (1 MiB) across the candidate CDNs to (a)
///    pick the fastest host and (b) collect ftyp + moov + sidx, which we
///    parse via ``ISOBMFF/probe(_:)``.
/// 3. Register the parsed `Source` with ``LocalHLSProxy`` and hand a
///    `http://127.0.0.1:<port>/play/<token>/master.m3u8` URL to AVPlayer.
/// 4. AVPlayer treats this as a vanilla HLS stream — fast startup, full
///    native UI, system PiP, AirPlay all preserved.
@MainActor
final class HLSProxyEngine: PlaybackEngine {
    static let shared = HLSProxyEngine()

    /// Fast-path probe: covers ~99 % of B 站 streams. The `ftyp + moov +
    /// sidx` prefix is typically well under 200 KiB even at 4K, so a 256
    /// KiB head fetch is enough to build the HLS playlist while keeping
    /// startup snappy.
    private static let fastProbeRange: ClosedRange<UInt64> = 0...(262_143)
    /// Fallback probe used only when the fast path can't see the full
    /// `moov + sidx`. 1 MiB matches what we shipped originally and is
    /// comfortably enough for any real-world B 站 dash file.
    private static let slowProbeRange: ClosedRange<UInt64> = 0...(1_048_575)
    private var liveTokens: Set<String> = []

    private init() {}

    func makeItem(for source: PlayUrlDTO) async throws -> EnginePreparation {
        let totalStart = CFAbsoluteTimeGetCurrent()
        let videoURLs = Self.validURLs(primary: source.url, backups: source.backupUrls)
        guard !videoURLs.isEmpty else {
            throw HLSProxyEngineError.invalidVideoURL(source.url)
        }
        let audioURLs: [URL]
        if let primary = source.audioUrl {
            audioURLs = Self.validURLs(primary: primary, backups: source.audioBackupUrls)
        } else {
            audioURLs = []
        }

        async let videoOutcome = Self.probeAndParse(label: "video", urls: videoURLs)
        async let audioOutcome: ProbeOutcome? = audioURLs.isEmpty
            ? nil
            : Self.probeAndParse(label: "audio", urls: audioURLs)
        let video = try await videoOutcome
        let audio = try await audioOutcome

        // Re-order candidates so the proven-good host is always tried first.
        let videoOrdered = Self.reorder(urls: videoURLs, preferring: video.race.winnerURL)
        let audioOrdered = audio.map { Self.reorder(urls: audioURLs, preferring: $0.race.winnerURL) } ?? []

        let token = UUID().uuidString
        let registered = LocalHLSProxy.Source(
            videoCandidates: videoOrdered,
            audioCandidates: audioOrdered,
            videoProbe: video.probe,
            audioProbe: audio?.probe,
            videoBandwidthHint: nil,
            videoCodec: source.videoCodec,
            audioCodec: audio == nil ? "" : source.audioCodec
        )
        let masterURL = try LocalHLSProxy.shared.register(token: token, source: registered)
        liveTokens.insert(token)

        let asset = AVURLAsset(url: masterURL, options: nil)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - totalStart) * 1000)
        var summary: [String: String] = [
            "engine": "hls_proxy",
            "videoCdn": video.race.winnerURL.host ?? "?",
            "videoOpenMs": String(video.race.winnerElapsedMs),
            "videoRaceMs": String(video.race.raceMs),
            "videoFragments": String(video.probe.index.entries.count),
            "videoAttempts": video.race.attempts.joined(separator: " | "),
            "proxyToken": token,
        ]
        if let audio {
            summary["audioCdn"] = audio.race.winnerURL.host ?? "?"
            summary["audioOpenMs"] = String(audio.race.winnerElapsedMs)
            summary["audioRaceMs"] = String(audio.race.raceMs)
            summary["audioFragments"] = String(audio.probe.index.entries.count)
            summary["audioAttempts"] = audio.race.attempts.joined(separator: " | ")
        } else {
            summary["audioCdn"] = "-"
            summary["audioOpenMs"] = "-"
            summary["audioAttempts"] = "-"
        }
        return EnginePreparation(
            item: item,
            logSummary: summary,
            totalElapsedMs: totalMs,
            release: { [weak self] in
                self?.liveTokens.remove(token)
                LocalHLSProxy.shared.unregister(token: token)
            },
            exportDiagnostics: { reason in
                await LocalHLSProxy.shared.exportDiagnostics(token: token, reason: reason)
            }
        )
    }

    func tearDown() {
        for token in liveTokens { LocalHLSProxy.shared.unregister(token: token) }
        liveTokens.removeAll()
    }

    /// `true` only while the local proxy listener is still running and
    /// at least one playback token remains registered. Returning `false`
    /// after the app comes back from a long background spell is the
    /// signal `PlayerView` uses to rebuild the AVPlayerItem against a
    /// freshly-bound port.
    var isAlive: Bool {
        guard !liveTokens.isEmpty else { return false }
        return LocalHLSProxy.shared.isHealthy
    }

    // MARK: - Helpers

    private struct ProbeOutcome {
        let race: ProbeRaceOutcome
        let probe: ISOBMFF.Probe
    }

    private static func probeAndParse(label: String, urls: [URL]) async throws -> ProbeOutcome {
        // Tier 1: race the fast probe across all candidate CDNs.
        let race = try await ProxyURLLoader.shared.raceProbe(urls: urls, range: fastProbeRange)
        AppLog.info("player", "HLS 代理探针完成", metadata: [
            "label": label,
            "host": race.winnerURL.host ?? "?",
            "elapsedMs": String(race.winnerElapsedMs),
            "raceMs": String(race.raceMs),
            "candidates": String(urls.count),
            "bytes": String(race.data.count),
            "tier": "fast",
        ])
        do {
            let probe = try ISOBMFF.probe(race.data)
            return ProbeOutcome(race: race, probe: probe)
        } catch ISOBMFF.ProbeError.missingSidx, ISOBMFF.ProbeError.missingMoov {
            // Tier 2: rare large-moov stream. Refetch a wider window from
            // the proven-good winner — no need to race again.
            AppLog.info("player", "HLS 代理探针扩展", metadata: [
                "label": label,
                "host": race.winnerURL.host ?? "?",
                "fastBytes": String(race.data.count),
            ])
            let extended = try await ProxyURLLoader.shared.fetch(url: race.winnerURL, range: slowProbeRange)
            do {
                let probe = try ISOBMFF.probe(extended.data)
                let widerRace = ProbeRaceOutcome(
                    winnerURL: race.winnerURL,
                    winnerElapsedMs: race.winnerElapsedMs,
                    raceMs: race.raceMs,
                    data: extended.data,
                    attempts: race.attempts
                )
                return ProbeOutcome(race: widerRace, probe: probe)
            } catch {
                AppLog.error("player", "HLS 代理 fMP4 解析失败", error: error, metadata: [
                    "label": label,
                    "host": race.winnerURL.host ?? "?",
                    "bytes": String(extended.data.count),
                    "tier": "slow",
                ])
                throw HLSProxyEngineError.probeFailed(label: label, underlying: error)
            }
        } catch {
            AppLog.error("player", "HLS 代理 fMP4 解析失败", error: error, metadata: [
                "label": label,
                "host": race.winnerURL.host ?? "?",
                "bytes": String(race.data.count),
                "tier": "fast",
            ])
            throw HLSProxyEngineError.probeFailed(label: label, underlying: error)
        }
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

    private static func reorder(urls: [URL], preferring winner: URL) -> [URL] {
        var rest = urls.filter { $0 != winner }
        rest.insert(winner, at: 0)
        return rest
    }
}

enum HLSProxyEngineError: Error, LocalizedError {
    case invalidVideoURL(String)
    case probeFailed(label: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidVideoURL(let url):
            return "无效的视频地址: \(url)"
        case .probeFailed(let label, let underlying):
            return "\(label) 流探针失败: \(underlying.localizedDescription)"
        }
    }
}
