import AVFoundation
import Foundation

@MainActor
final class RemuxMP4Engine: PlaybackEngine {
    static let shared = RemuxMP4Engine()

    private var activeFiles: Set<URL> = []

    private init() {}

    func makeItem(for source: PlayUrlDTO) async throws -> EnginePreparation {
        let totalStart = CFAbsoluteTimeGetCurrent()
        let prepared = try await RemuxInputBuilder.prepareInputs(for: source)
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
        activeFiles.insert(mp4URL)

        let asset = AVURLAsset(url: mp4URL, options: nil)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - totalStart) * 1000)
        var summary = prepared.logSummary
        summary["engine"] = "ffmpeg_remux_mp4"
        summary["remuxPath"] = mp4URL.path
        summary["remuxInputMs"] = String(prepared.elapsedMs)
        summary["remuxTotalMs"] = String(totalMs)

        return EnginePreparation(
            item: item,
            logSummary: summary,
            totalElapsedMs: totalMs,
            release: { [weak self] in
                self?.activeFiles.remove(mp4URL)
            },
            exportDiagnostics: { reason in
                await Self.exportDiagnostics(directory: prepared.diagnosticsDirectory, mp4URL: mp4URL, reason: reason)
            }
        )
    }

    func tearDown() {
        activeFiles.removeAll()
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
