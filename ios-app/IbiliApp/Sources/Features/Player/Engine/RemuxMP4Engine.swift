import AVFoundation
import CryptoKit
import Foundation

@MainActor
final class RemuxMP4Engine: PlaybackEngine {
    static let shared = RemuxMP4Engine()

    private var activeToken: String?
    private var activeSession: StreamingRemuxSession?
    private var currentGeneration: UInt64 = 0

    private init() {}

    func makeItem(for source: PlayUrlDTO) async throws -> EnginePreparation {
        let totalStart = CFAbsoluteTimeGetCurrent()
        let proxy = LocalHLSProxy.shared

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

        let videoOrdered = Self.reorder(urls: videoURLs, preferring: video.race.winnerURL)
        let audioOrdered = audio.map { Self.reorder(urls: audioURLs, preferring: $0.race.winnerURL) } ?? []

        let workspace = try Self.makeWorkspace(for: source)

        let session = StreamingRemuxSession(
            videoCandidates: videoOrdered,
            videoProbe: video.probe,
            outputDirectory: workspace,
            hlsTime: 6
        )
        try session.start()

        try await Self.waitForInitSegment(session: session)
        AppLog.info("player", "streaming remux 首段就绪", metadata: [
            "workspace": workspace.path,
            "playlist": workspace.appendingPathComponent("live.m3u8").path,
            "init": session.initSegmentPath.path,
            "seg0": session.segmentPath(0).path,
        ])

        let token = UUID().uuidString
        let masterURL = try proxy.registerRemuxSession(
            token: token,
            session: session,
            audioCandidates: audioOrdered,
            audioProbe: audio?.probe
        )
        currentGeneration += 1
        activeToken = token
        activeSession = session

        let asset = AVURLAsset(url: masterURL, options: nil)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - totalStart) * 1000)
        let summary: [String: String] = [
            "engine": "streaming_remux_hls",
            "videoCdn": video.race.winnerURL.host ?? "?",
            "videoOpenMs": String(video.race.winnerElapsedMs),
            "videoRaceMs": String(video.race.raceMs),
            "videoFragments": String(video.probe.index.entries.count),
            "audioFragments": String(audio?.probe.index.entries.count ?? 0),
            "proxyToken": token,
            "totalMs": String(totalMs),
        ]

        return EnginePreparation(
            item: item,
            logSummary: summary,
            totalElapsedMs: totalMs,
            release: { [weak self] in
                self?.releaseSession(token: token)
            },
            exportDiagnostics: { reason in
                await Self.exportDiagnostics(directory: workspace, source: source, reason: reason)
            }
        )
    }

    func tearDown() {
        if let token = activeToken {
            LocalHLSProxy.shared.unregisterRemuxSession(token: token)
        }
        activeSession?.cancel()
        activeToken = nil
        activeSession = nil
    }

    private func releaseSession(token: String) {
        if activeToken == token {
            LocalHLSProxy.shared.unregisterRemuxSession(token: token)
            activeSession?.cancel()
            activeToken = nil
            activeSession = nil
        }
    }

    /// Wait until `init.mp4` and the first segment exist on disk.
    private static func waitForInitSegment(session: StreamingRemuxSession) async throws {
        let fm = FileManager.default
        let playlistPath = session.outputDirectory.appendingPathComponent("live.m3u8").path
        let initPath = session.initSegmentPath.path
        let firstSeg = session.segmentPath(0).path
        let deadline = Date().addingTimeInterval(30)

        while Date() < deadline {
            try Task.checkCancellation()
            if fm.fileExists(atPath: playlistPath),
               fm.fileExists(atPath: initPath),
               fm.fileExists(atPath: firstSeg) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        throw StreamingRemuxError.ffmpegNotAvailable
    }

    // MARK: - Probe helpers (same as HLSProxyEngine)

    private static let fastProbeRange: ClosedRange<UInt64> = 0...(262_143)
    private static let slowProbeRange: ClosedRange<UInt64> = 0...(1_048_575)

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
                throw HLSProxyEngineError.probeFailed(label: label, underlying: error)
            }
        } catch {
            throw HLSProxyEngineError.probeFailed(label: label, underlying: error)
        }
    }

    // MARK: - Workspace

    private static func makeWorkspace(for source: PlayUrlDTO) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let key = cacheKey(for: source)
        let workspace = caches
            .appendingPathComponent("ibili-remux-stream", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        if FileManager.default.fileExists(atPath: workspace.path) {
            try? FileManager.default.removeItem(at: workspace)
        }
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

    // MARK: - Helpers

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

    private static func exportDiagnostics(directory: URL, source: PlayUrlDTO, reason: String) async -> URL? {
        do {
            let exportDir = try makeDiagnosticsDirectory(sourceDirectory: directory)
            let fm = FileManager.default
            let interestingNames = [
                "live.m3u8",
                "init.mp4",
                "seg-0.m4s",
                "seg-1.m4s",
                "seg-2.m4s",
            ]
            var exported: [String: String] = [:]
            for name in interestingNames {
                let source = directory.appendingPathComponent(name)
                guard fm.fileExists(atPath: source.path) else { continue }
                let destination = exportDir.appendingPathComponent(name)
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: source, to: destination)
                exported[name] = fileDescription(url: destination)
            }

            let rewrittenPlaylist = try rewritePlaylistForLocalDebug(
                sourceDirectory: directory,
                exportDirectory: exportDir
            )
            if rewrittenPlaylist != nil {
                exported["local.m3u8"] = "rewritten for local macOS debugging"
            }
            try writeMacDebugScript(to: exportDir)
            exported["debug-on-macos.sh"] = "generated"
            try writeAVFoundationProbeScript(to: exportDir)
            exported["AVFoundationProbe.swift"] = "generated"

            let metadata: [String: Any] = [
                "reason": reason,
                "engine": "streaming_remux_hls",
                "sourceDirectory": directory.path,
                "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "exported": exported,
                "note": "Copy this whole directory to macOS. Run ./debug-on-macos.sh, then open local.m3u8 with QuickTime/AVPlayer or run swift AVFoundationProbe.swift local.m3u8.",
            ]
            let metadataURL = exportDir.appendingPathComponent("metadata.json")
            var mutableMetadata = metadata
            if !source.videoCodec.isEmpty {
                mutableMetadata["videoCodec"] = source.videoCodec
            }
            if !source.audioCodec.isEmpty {
                mutableMetadata["audioCodec"] = source.audioCodec
            }
            if let width = source.videoWidth {
                mutableMetadata["videoWidth"] = width
            }
            if let height = source.videoHeight {
                mutableMetadata["videoHeight"] = height
            }
            if let frameRate = source.videoFrameRate {
                mutableMetadata["videoFrameRate"] = frameRate
            }
            if let videoRange = source.videoRange {
                mutableMetadata["videoRange"] = videoRange
            }
            if let initData = try? Data(contentsOf: exportDir.appendingPathComponent("init.mp4")),
               let videoMetadata = ISOBMFF.parseInitVideoMetadata(initData) {
                mutableMetadata["videoWidth"] = videoMetadata.width
                mutableMetadata["videoHeight"] = videoMetadata.height
                if let videoRange = videoMetadata.videoRange {
                    mutableMetadata["videoRange"] = videoRange.rawValue
                }
                if let videoCodec = videoMetadata.codecString {
                    mutableMetadata["videoCodec"] = videoCodec
                }
                if let supplementalVideoCodec = videoMetadata.supplementalCodecString {
                    mutableMetadata["videoSupplementalCodec"] = supplementalVideoCodec
                }
            }
            try writeJSONObject(mutableMetadata, to: metadataURL)

            let offlinePackagingBuild = await buildOfflinePackagingWorkspace(diagnosticsDirectory: exportDir)
            if let workspaceRootDirectory = offlinePackagingBuild["workspaceRootDirectory"] as? String {
                exported["packaging-workspace"] = workspaceRootDirectory
            }
            mutableMetadata["offlinePackagingBuild"] = offlinePackagingBuild
            mutableMetadata["exported"] = exported
            try writeJSONObject(mutableMetadata, to: metadataURL)
            AppLog.info("player", "remux 失败诊断导出完成", metadata: [
                "path": exportDir.path,
                "reason": reason,
            ])
            return exportDir
        } catch {
            AppLog.error("player", "remux 失败诊断导出失败", error: error, metadata: [
                "sourceDirectory": directory.path,
                "reason": reason,
            ])
            return nil
        }
    }

    private static func makeDiagnosticsDirectory(sourceDirectory: URL) throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let safeTimestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let shortWorkspace = String(sourceDirectory.lastPathComponent.prefix(8))
        let dir = documents
            .appendingPathComponent("ibili-diagnostics", isDirectory: true)
            .appendingPathComponent("remux-\(safeTimestamp)-\(shortWorkspace)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func buildOfflinePackagingWorkspace(diagnosticsDirectory: URL) async -> [String: Any] {
        AppLog.info("player", "开始生成 remux diagnostics offline packaging workspace", metadata: [
            "diagnostics": diagnosticsDirectory.path,
        ])

        do {
            let result = try await Task.detached(priority: .utility) {
                try CoreClient.shared.packagingOfflineBuild(
                    diagnosticsDirectory: diagnosticsDirectory.path
                )
            }.value

            AppLog.info("player", "remux diagnostics offline packaging workspace 已生成", metadata: [
                "diagnostics": result.diagnosticsDirectory,
                "workspace": result.workspaceRootDirectory,
                "sourceKind": result.sourceKind,
                "hasAudio": String(result.hasAudio),
                "startupReady": String(result.startupReady),
                "generatedFiles": String(result.generatedFiles.count),
                "warnings": String(result.warnings.count),
            ])

            var summary: [String: Any] = [
                "status": "built",
                "diagnosticsDirectory": result.diagnosticsDirectory,
                "workspaceRootDirectory": result.workspaceRootDirectory,
                "masterPlaylistPath": result.masterPlaylistPath,
                "videoPlaylistPath": result.videoPlaylistPath,
                "streamManifestPath": result.streamManifestPath,
                "authoringSummaryPath": result.authoringSummaryPath,
                "sourceKind": result.sourceKind,
                "hasAudio": result.hasAudio,
                "startupReady": result.startupReady,
                "stagedFiles": result.stagedFiles,
                "generatedFiles": result.generatedFiles,
                "warnings": result.warnings,
            ]
            if let audioPlaylistPath = result.audioPlaylistPath {
                summary["audioPlaylistPath"] = audioPlaylistPath
            }
            return summary
        } catch {
            let nsError = error as NSError
            AppLog.error("player", "remux diagnostics offline packaging workspace 生成失败", error: error, metadata: [
                "diagnostics": diagnosticsDirectory.path,
            ])
            return [
                "status": "failed",
                "diagnosticsDirectory": diagnosticsDirectory.path,
                "errorDomain": nsError.domain,
                "errorCode": nsError.code,
                "errorDescription": nsError.localizedDescription,
            ]
        }
    }

    private static func rewritePlaylistForLocalDebug(sourceDirectory: URL, exportDirectory: URL) throws -> URL? {
        let sourcePlaylist = sourceDirectory.appendingPathComponent("live.m3u8")
        guard var content = try? String(contentsOf: sourcePlaylist, encoding: .utf8) else { return nil }
        content = content.replacingOccurrences(of: sourceDirectory.path + "/", with: "")
        let localPlaylist = exportDirectory.appendingPathComponent("local.m3u8")
        try Data(content.utf8).write(to: localPlaylist, options: [.atomic])
        return localPlaylist
    }

    private static func writeMacDebugScript(to directory: URL) throws {
        let script = """
        #!/bin/sh
        set -eu
        cd "$(dirname "$0")"

        echo "== Files =="
        ls -lh

        if command -v ffprobe >/dev/null 2>&1; then
          echo "\n== ffprobe: init.mp4 =="
          ffprobe -hide_banner -v trace -i init.mp4 > ffprobe-init-trace.txt 2>&1 || true
          ffprobe -hide_banner -show_format -show_streams -show_entries stream=index,codec_name,codec_tag_string,profile,level,pix_fmt,color_range,color_space,color_transfer,color_primaries,side_data_list -of json init.mp4 > ffprobe-init.json 2>&1 || true

          if [ -f seg-0.m4s ]; then
            echo "\n== ffprobe: local.m3u8 =="
            ffprobe -hide_banner -allowed_extensions ALL -show_format -show_streams -of json local.m3u8 > ffprobe-local-playlist.json 2>&1 || true
          fi
        else
          echo "ffprobe not found. Install with: brew install ffmpeg"
        fi

        echo "\n== MP4 box strings likely relevant =="
        strings init.mp4 | grep -E 'ftyp|moov|trak|stsd|hvc1|hev1|dvh1|dvhe|hvcC|dvcC|dvvC|colr|pasp|clli|mdcv' || true

        if command -v swift >/dev/null 2>&1; then
          echo "\n== AVFoundation probe =="
          swift AVFoundationProbe.swift local.m3u8 > avfoundation-probe.txt 2>&1 || true
          cat avfoundation-probe.txt || true
        fi

        echo "\nGenerated diagnostics:"
        echo "  ffprobe-init-trace.txt"
        echo "  ffprobe-init.json"
        echo "  ffprobe-local-playlist.json"
        echo "  avfoundation-probe.txt"
        """
        let url = directory.appendingPathComponent("debug-on-macos.sh")
        try Data(script.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func writeAVFoundationProbeScript(to directory: URL) throws {
        let script = #"""
        import AVFoundation
        import Foundation

        let argument = CommandLine.arguments.dropFirst().first ?? "local.m3u8"
        let url = URL(fileURLWithPath: argument, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).absoluteURL
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        let semaphore = DispatchSemaphore(value: 0)
        var observation: NSKeyValueObservation?

        print("url=\(url.path)")
        observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            switch item.status {
            case .readyToPlay:
                print("status=readyToPlay")
                semaphore.signal()
            case .failed:
                print("status=failed")
                if let error = item.error as NSError? {
                    print("errorDomain=\(error.domain)")
                    print("errorCode=\(error.code)")
                    print("errorDescription=\(error.localizedDescription)")
                    print("userInfo=\(error.userInfo)")
                } else {
                    print("error=nil")
                }
                if let log = item.errorLog() {
                    for event in log.events {
                        print("errorLog domain=\(event.errorDomain) status=\(event.errorStatusCode) comment=\(event.errorComment ?? "-") uri=\(event.uri ?? "-")")
                    }
                }
                semaphore.signal()
            default:
                break
            }
        }

        player.play()
        _ = semaphore.wait(timeout: .now() + 15)
        observation?.invalidate()
        player.pause()
        """#
        let url = directory.appendingPathComponent("AVFoundationProbe.swift")
        try Data(script.utf8).write(to: url, options: [.atomic])
    }

    private static func fileDescription(url: URL) -> String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? -1
        return "\(size) bytes"
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
    }
}
