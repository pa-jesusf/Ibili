import AVFoundation
import Foundation

@MainActor
final class RemuxMP4Engine: PlaybackEngine {
    static let shared = RemuxMP4Engine()

    private var activeToken: String?
    private var backgroundTask: Task<Void, Never>?
    private var extensionObserver: Any?
    private var currentSource: PlayUrlDTO?
    private weak var currentPlayer: AVPlayer?
    private var currentGeneration: UInt64 = 0
    private var partialDuration: Double = 0

    private init() {}

    func makeItem(for source: PlayUrlDTO) async throws -> EnginePreparation {
        let totalStart = CFAbsoluteTimeGetCurrent()
        let proxy = LocalHLSProxy.shared

        let prepared: RemuxPreparedInput
        let isPartial: Bool

        if let cachedMP4 = checkFullCache(for: source) {
            let asset = AVURLAsset(url: cachedMP4, options: nil)
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .spectral
            let totalMs = Int((CFAbsoluteTimeGetCurrent() - totalStart) * 1000)
            return EnginePreparation(
                item: item,
                logSummary: [
                    "engine": "ffmpeg_remux_mp4",
                    "remuxCache": "hit",
                    "remuxPath": cachedMP4.path,
                    "remuxTotalMs": String(totalMs),
                    "partial": "false",
                ],
                totalElapsedMs: totalMs,
                release: {},
                exportDiagnostics: { _ in nil }
            )
        }

        prepared = try await RemuxInputBuilder.prepareInitialInputs(for: source)
        isPartial = true

        let mp4URL: URL
        if FileManager.default.fileExists(atPath: prepared.outputMP4.path) {
            mp4URL = prepared.outputMP4
        } else {
            mp4URL = try await FFmpegRemuxer.shared.remuxToMP4(
                video: prepared.videoSample,
                audio: prepared.audioSample,
                output: prepared.outputMP4
            )
        }

        let token = UUID().uuidString
        try proxy.registerLocalFile(token: token, fileURL: mp4URL)
        activeToken = token

        let port = proxy.currentPort
        guard let streamURL = URL(string: "http://127.0.0.1:\(port)/file/\(token)/stream.mp4") else {
            throw ProxyServerError.invalidServerURL
        }

        let asset = AVURLAsset(url: streamURL, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Connection": "keep-alive"],
        ])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - totalStart) * 1000)
        var summary = prepared.logSummary
        summary["engine"] = isPartial ? "ffmpeg_remux_mp4_partial" : "ffmpeg_remux_mp4"
        summary["remuxPath"] = mp4URL.path
        summary["remuxInputMs"] = String(prepared.elapsedMs)
        summary["remuxTotalMs"] = String(totalMs)
        summary["partial"] = String(isPartial)
        summary["proxyToken"] = token

        if isPartial {
            currentSource = source
            currentGeneration += 1
            let gen = currentGeneration
            backgroundTask?.cancel()
            backgroundTask = Task { [weak self] in
                await self?.backgroundFullDownload(source: source, token: token, generation: gen)
            }
        }

        return EnginePreparation(
            item: item,
            logSummary: summary,
            totalElapsedMs: totalMs,
            release: { [weak self] in
                if self?.activeToken == token {
                    proxy.unregisterLocalFile(token: token)
                    self?.activeToken = nil
                }
            },
            exportDiagnostics: { reason in
                await Self.exportDiagnostics(directory: prepared.diagnosticsDirectory, mp4URL: mp4URL, reason: reason)
            }
        )
    }

    func setPlayer(_ player: AVPlayer) {
        currentPlayer = player
    }

    func tearDown() {
        if let token = activeToken {
            LocalHLSProxy.shared.unregisterLocalFile(token: token)
        }
        activeToken = nil
        backgroundTask?.cancel()
        backgroundTask = nil
        currentSource = nil
        currentPlayer = nil
        if let obs = extensionObserver {
            NotificationCenter.default.removeObserver(obs)
            extensionObserver = nil
        }
    }

    private func checkFullCache(for source: PlayUrlDTO) -> URL? {
        guard let workspace = try? RemuxInputBuilder.workspaceURL(for: source) else { return nil }
        let fullMP4 = workspace.appendingPathComponent("remux.mp4")
        if FileManager.default.fileExists(atPath: fullMP4.path) { return fullMP4 }
        return nil
    }

    private func backgroundFullDownload(source: PlayUrlDTO, token: String, generation: UInt64) async {
        do {
            let prepared = try await RemuxInputBuilder.prepareInputs(for: source)
            if !FileManager.default.fileExists(atPath: prepared.outputMP4.path) {
                _ = try await FFmpegRemuxer.shared.remuxToMP4(
                    video: prepared.videoSample,
                    audio: prepared.audioSample,
                    output: prepared.outputMP4
                )
            }
            guard !Task.isCancelled, await self.currentGeneration == generation else { return }
            await MainActor.run {
                guard self.currentGeneration == generation else { return }
                LocalHLSProxy.shared.updateLocalFile(token: token, fileURL: prepared.outputMP4)
                AppLog.info("player", "后台全量 remux 完成，已更新代理文件", metadata: [
                    "path": prepared.outputMP4.path,
                    "token": token,
                ])
            }
        } catch is CancellationError {
            return
        } catch {
            AppLog.error("player", "后台全量 remux 失败", error: error)
        }
    }

    private static func exportDiagnostics(directory: URL, mp4URL: URL, reason: String) async -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let metadata: [String: Any] = [
                "reason": reason,
                "remuxMP4": mp4URL.path,
                "exists": FileManager.default.fileExists(atPath: mp4URL.path),
            ]
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("playback-failure.json"), options: [.atomic])
            return directory
        } catch {
            AppLog.error("player", "remux 诊断导出失败", error: error, metadata: [
                "path": directory.path,
            ])
            return nil
        }
    }
}
