import AVFoundation
import CryptoKit
import Foundation

struct RemuxPreparedInput {
    let videoSample: URL
    let audioSample: URL?
    let outputMP4: URL
    let diagnosticsDirectory: URL
    let logSummary: [String: String]
    let elapsedMs: Int
}

enum RemuxInputBuilderError: Error, LocalizedError {
    case invalidVideoURL(String)
    case probeFailed(label: String, underlying: Error)
    case missingVideoCandidate
    case emptyFragmentIndex(label: String)

    var errorDescription: String? {
        switch self {
        case .invalidVideoURL(let url):
            return "无效的视频地址: \(url)"
        case .probeFailed(let label, let underlying):
            return "\(label) 流 remux 探针失败: \(underlying.localizedDescription)"
        case .missingVideoCandidate:
            return "remux 缺少视频候选地址"
        case .emptyFragmentIndex(let label):
            return "\(label) 流没有可 remux 的 fragment"
        }
    }
}

enum RemuxInputBuilder {
    private static let fastProbeRange: ClosedRange<UInt64> = 0...(262_143)
    private static let slowProbeRange: ClosedRange<UInt64> = 0...(1_048_575)

    static let initialFragmentCount = 15

    static func prepareInputs(for source: PlayUrlDTO) async throws -> RemuxPreparedInput {
        try await prepareInputs(for: source, fragmentLimit: nil)
    }

    static func prepareInitialInputs(for source: PlayUrlDTO) async throws -> RemuxPreparedInput {
        try await prepareInputs(for: source, fragmentLimit: initialFragmentCount)
    }

    private static func prepareInputs(for source: PlayUrlDTO, fragmentLimit: Int?) async throws -> RemuxPreparedInput {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let workspace = try makeWorkspace(for: source, partial: fragmentLimit != nil)
        let suffix = fragmentLimit.map { "-partial-\($0)" } ?? ""
        let outputMP4 = workspace.appendingPathComponent("remux\(suffix).mp4")
        let videoSample = workspace.appendingPathComponent("video-source\(suffix).m4s")
        let audioSample = source.audioUrl == nil ? nil : workspace.appendingPathComponent("audio-source\(suffix).m4s")
        let metadataURL = workspace.appendingPathComponent("remux-metadata\(suffix).json")

        if FileManager.default.fileExists(atPath: outputMP4.path) {
            let cachedAudioSample: URL?
            if let audioSample, FileManager.default.fileExists(atPath: audioSample.path) {
                cachedAudioSample = audioSample
            } else {
                cachedAudioSample = nil
            }
            return RemuxPreparedInput(
                videoSample: videoSample,
                audioSample: cachedAudioSample,
                outputMP4: outputMP4,
                diagnosticsDirectory: workspace,
                logSummary: [
                    "remuxCache": "hit",
                    "remuxPath": outputMP4.path,
                ],
                elapsedMs: Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            )
        }

        let videoURLs = validURLs(primary: source.url, backups: source.backupUrls)
        guard !videoURLs.isEmpty else { throw RemuxInputBuilderError.invalidVideoURL(source.url) }
        let audioURLs: [URL]
        if let primary = source.audioUrl {
            audioURLs = validURLs(primary: primary, backups: source.audioBackupUrls)
        } else {
            audioURLs = []
        }

        async let videoOutcome = probeAndParse(label: "video", urls: videoURLs)
        async let audioOutcome: ProbeOutcome? = audioURLs.isEmpty ? nil : probeAndParse(label: "audio", urls: audioURLs)
        let video = try await videoOutcome
        let audio = try await audioOutcome

        let videoOrdered = reorder(urls: videoURLs, preferring: video.race.winnerURL)
        let audioOrdered = audio.map { reorder(urls: audioURLs, preferring: $0.race.winnerURL) } ?? []
        guard let videoURL = videoOrdered.first else { throw RemuxInputBuilderError.missingVideoCandidate }

        let videoBytes = try await writeConcatenatedFMP4(
            label: "video",
            url: videoURL,
            probe: video.probe,
            output: videoSample,
            fragmentLimit: fragmentLimit
        )
        var audioBytes = 0
        if let audio, let audioURL = audioOrdered.first, let audioSample {
            audioBytes = try await writeConcatenatedFMP4(
                label: "audio",
                url: audioURL,
                probe: audio.probe,
                output: audioSample,
                fragmentLimit: fragmentLimit
            )
        }

        let metadata: [String: Any] = [
            "videoURL": videoURL.absoluteString,
            "audioURL": audioOrdered.first?.absoluteString ?? "",
            "quality": source.quality,
            "durationMs": source.durationMs,
            "videoCodec": source.videoCodec,
            "audioCodec": source.audioCodec,
            "videoFragments": video.probe.index.entries.count,
            "audioFragments": audio?.probe.index.entries.count ?? 0,
            "videoBytes": videoBytes,
            "audioBytes": audioBytes,
            "videoAttempts": video.race.attempts,
            "audioAttempts": audio?.race.attempts ?? [],
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try metadataData.write(to: metadataURL, options: [.atomic])

        var summary: [String: String] = [
            "engine": "ffmpeg_remux_mp4",
            "remuxCache": "miss",
            "remuxWorkspace": workspace.path,
            "videoCdn": video.race.winnerURL.host ?? "?",
            "videoOpenMs": String(video.race.winnerElapsedMs),
            "videoRaceMs": String(video.race.raceMs),
            "videoFragments": String(video.probe.index.entries.count),
            "videoBytes": String(videoBytes),
            "videoAttempts": video.race.attempts.joined(separator: " | "),
        ]
        if let audio {
            summary["audioCdn"] = audio.race.winnerURL.host ?? "?"
            summary["audioOpenMs"] = String(audio.race.winnerElapsedMs)
            summary["audioRaceMs"] = String(audio.race.raceMs)
            summary["audioFragments"] = String(audio.probe.index.entries.count)
            summary["audioBytes"] = String(audioBytes)
            summary["audioAttempts"] = audio.race.attempts.joined(separator: " | ")
        } else {
            summary["audioCdn"] = "-"
            summary["audioOpenMs"] = "-"
            summary["audioAttempts"] = "-"
        }

        return RemuxPreparedInput(
            videoSample: videoSample,
            audioSample: audioSample,
            outputMP4: outputMP4,
            diagnosticsDirectory: workspace,
            logSummary: summary,
            elapsedMs: Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        )
    }

    private struct ProbeOutcome {
        let race: ProbeRaceOutcome
        let probe: ISOBMFF.Probe
    }

    private static func probeAndParse(label: String, urls: [URL]) async throws -> ProbeOutcome {
        let race = try await ProxyURLLoader.shared.raceProbe(urls: urls, range: fastProbeRange)
        do {
            return ProbeOutcome(race: race, probe: try ISOBMFF.probe(race.data))
        } catch ISOBMFF.ProbeError.missingSidx, ISOBMFF.ProbeError.missingMoov {
            let extended = try await ProxyURLLoader.shared.fetch(url: race.winnerURL, range: slowProbeRange)
            do {
                let widerRace = ProbeRaceOutcome(
                    winnerURL: race.winnerURL,
                    winnerElapsedMs: race.winnerElapsedMs,
                    raceMs: race.raceMs,
                    data: extended.data,
                    attempts: race.attempts
                )
                return ProbeOutcome(race: widerRace, probe: try ISOBMFF.probe(extended.data))
            } catch {
                throw RemuxInputBuilderError.probeFailed(label: label, underlying: error)
            }
        } catch {
            throw RemuxInputBuilderError.probeFailed(label: label, underlying: error)
        }
    }

    private static func writeConcatenatedFMP4(label: String,
                                             url: URL,
                                             probe: ISOBMFF.Probe,
                                             output: URL,
                                             fragmentLimit: Int? = nil) async throws -> Int {
        guard !probe.index.entries.isEmpty else { throw RemuxInputBuilderError.emptyFragmentIndex(label: label) }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        var totalBytes = 0
        let initData = try await ProxyURLLoader.shared.fetch(url: url, range: probe.initSegment.range).data
        try handle.write(contentsOf: initData)
        totalBytes += initData.count

        let count = fragmentLimit.map { min($0, probe.index.entries.count) } ?? probe.index.entries.count
        for index in 0..<count {
            try Task.checkCancellation()
            let entry = probe.index.entries[index]
            let data = try await ProxyURLLoader.shared.fetch(url: url, range: entry.range).data
            try handle.write(contentsOf: data)
            totalBytes += data.count
            if index == 0 || (index + 1) % 20 == 0 || index == count - 1 {
                AppLog.info("player", "remux 输入下载进度", metadata: [
                    "label": label,
                    "fragment": "\(index + 1)/\(count)",
                    "bytes": String(totalBytes),
                ])
            }
        }
        return totalBytes
    }

    static func workspaceURL(for source: PlayUrlDTO) throws -> URL {
        try makeWorkspace(for: source)
    }

    private static func makeWorkspace(for source: PlayUrlDTO, partial: Bool = false) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let key = cacheKey(for: source)
        let workspace = caches
            .appendingPathComponent("ibili-remux", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    private static func cacheKey(for source: PlayUrlDTO) -> String {
        let raw = [
            source.url,
            source.audioUrl ?? "",
            String(source.quality),
            String(source.durationMs),
            source.videoCodec,
            source.audioCodec,
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
