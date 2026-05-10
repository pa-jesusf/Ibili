import SwiftUI
import AVFoundation
import Photos
import QuickLook
import UIKit

enum OfflineDownloadStatus: String, Codable {
    case queued
    case resolving
    case downloading
    case remuxing
    case completed
    case paused
    case failed

    var label: String {
        switch self {
        case .queued: return "等待中"
        case .resolving: return "获取地址"
        case .downloading: return "下载中"
        case .remuxing: return "无损封装"
        case .completed: return "已完成"
        case .paused: return "已暂停"
        case .failed: return "失败"
        }
    }
}

struct OfflineDownloadMetadata: Codable, Identifiable, Hashable {
    let id: String
    var sourceType: String
    var aid: Int64
    var bvid: String
    var cid: Int64
    var epID: Int64
    var seasonID: Int64
    var title: String
    var author: String
    var cover: String
    var durationSec: Int64
    var qn: Int64
    var qnLabel: String
    var audioQn: Int64
    var audioQnLabel: String
    var videoFileName: String
    var danmakuFileName: String
    var createdAt: Date
    var updatedAt: Date
    var status: OfflineDownloadStatus
    var progress: Double
    var errorMessage: String?
    var danmakuStatus: OfflineDownloadStatus
}

struct OfflineDanmakuArchive: Codable {
    let schemaVersion: Int
    let cid: Int64
    let durationSec: Int64
    let generatedAt: Date
    let items: [DanmakuItemDTO]
}

struct OfflineDownloadRequest: Hashable {
    let item: FeedItemDTO
    let qn: Int64
    let qnLabel: String
    let audioQn: Int64
    let audioQnLabel: String
    let cdn: String
}

@MainActor
final class OfflineDownloadService: ObservableObject {
    static let shared = OfflineDownloadService()

    @Published private(set) var entries: [OfflineDownloadMetadata] = []

    private var activeTasks: [String: Task<Void, Never>] = [:]
    private let fileManager = FileManager.default
    private let metadataFileName = "metadata.json"
    private let danmakuFileName = "danmaku.json"

    private init() {
        reloadFromDisk()
    }

    var rootDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Ibili", isDirectory: true)
            .appendingPathComponent("OfflineCache", isDirectory: true)
    }

    private var workRootDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("IbiliOfflineWork", isDirectory: true)
    }

    func reloadFromDisk() {
        ensureDirectory(rootDirectory)
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            entries = []
            return
        }
        let decoded: [OfflineDownloadMetadata] = dirs.compactMap { dir in
            let metadataURL = dir.appendingPathComponent(metadataFileName)
            guard let data = try? Data(contentsOf: metadataURL),
                  var metadata = try? JSONDecoder.offline.decode(OfflineDownloadMetadata.self, from: data) else {
                return nil
            }
            if metadata.status != .completed && activeTasks[metadata.id] == nil {
                metadata.status = .failed
                metadata.errorMessage = metadata.errorMessage ?? "下载未完成"
            }
            return metadata
        }
        entries = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    func start(_ request: OfflineDownloadRequest) {
        ensureDirectory(rootDirectory)
        ensureDirectory(workRootDirectory)
        let id = stableID(for: request.item, qn: request.qn, audioQn: request.audioQn)
        activeTasks[id]?.cancel()
        let dir = entryDirectory(id: id, title: request.item.title)
        ensureDirectory(dir)
        var metadata = OfflineDownloadMetadata(
            id: id,
            sourceType: request.item.isPGC ? "pgc" : "ugc",
            aid: request.item.aid,
            bvid: request.item.bvid,
            cid: request.item.cid,
            epID: request.item.epID,
            seasonID: request.item.seasonID,
            title: request.item.title,
            author: request.item.author,
            cover: request.item.cover,
            durationSec: request.item.durationSec,
            qn: request.qn,
            qnLabel: request.qnLabel,
            audioQn: request.audioQn,
            audioQnLabel: request.audioQnLabel,
            videoFileName: "video.mp4",
            danmakuFileName: danmakuFileName,
            createdAt: Date(),
            updatedAt: Date(),
            status: .queued,
            progress: 0,
            errorMessage: nil,
            danmakuStatus: .queued
        )
        upsert(metadata)
        writeMetadata(metadata, to: dir)

        activeTasks[id] = Task { [weak self] in
            await self?.performDownload(request: request, metadata: metadata, directory: dir)
        }
    }

    func pause(_ id: String) {
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
        update(id: id) {
            $0.status = .paused
            $0.updatedAt = Date()
        }
    }

    func retry(_ metadata: OfflineDownloadMetadata) {
        let item = FeedItemDTO(
            aid: metadata.aid,
            bvid: metadata.bvid,
            cid: metadata.cid,
            title: metadata.title,
            cover: metadata.cover,
            author: metadata.author,
            durationSec: metadata.durationSec,
            play: 0,
            danmaku: 0,
            epID: metadata.epID,
            seasonID: metadata.seasonID,
            isPGC: metadata.sourceType == "pgc"
        )
        start(OfflineDownloadRequest(
            item: item,
            qn: metadata.qn,
            qnLabel: metadata.qnLabel,
            audioQn: metadata.audioQn,
            audioQnLabel: metadata.audioQnLabel,
            cdn: AppSettings.shared.cdnService.rawValue
        ))
    }

    func delete(_ metadata: OfflineDownloadMetadata) {
        activeTasks[metadata.id]?.cancel()
        activeTasks[metadata.id] = nil
        let dirs = matchingEntryDirectories(for: metadata.id)
        dirs.forEach { try? fileManager.removeItem(at: $0) }
        try? fileManager.removeItem(at: workDirectory(for: metadata.id))
        entries.removeAll { $0.id == metadata.id }
    }

    func videoURL(for metadata: OfflineDownloadMetadata) -> URL? {
        guard let dir = matchingEntryDirectories(for: metadata.id).first else { return nil }
        let url = dir.appendingPathComponent(metadata.videoFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func saveCoverToPhotos(urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw OfflineDownloadError.message("封面地址无效")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let image = UIImage(data: data) else {
            throw OfflineDownloadError.message("封面解码失败")
        }
        let status = await requestPhotoAddOnly()
        guard status == .authorized || status == .limited else {
            throw OfflineDownloadError.message("无相册权限")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    private func performDownload(
        request: OfflineDownloadRequest,
        metadata initialMetadata: OfflineDownloadMetadata,
        directory: URL
    ) async {
        var metadata = initialMetadata
        do {
            metadata.status = .resolving
            metadata.updatedAt = Date()
            metadata.progress = 0.08
            upsert(metadata)
            writeMetadata(metadata, to: directory)

            let offline = try await Task.detached(priority: .userInitiated) {
                if request.item.isPGC {
                    return try CoreClient.shared.pgcOfflinePlayUrl(
                        aid: request.item.aid,
                        cid: request.item.cid,
                        epID: request.item.epID,
                        seasonID: request.item.seasonID,
                        qn: request.qn,
                        audioQn: request.audioQn,
                        cdn: request.cdn
                    )
                }
                return try CoreClient.shared.offlinePlayUrl(
                    aid: request.item.aid,
                    cid: request.item.cid,
                    qn: request.qn,
                    audioQn: request.audioQn,
                    cdn: request.cdn
                )
            }.value

            try Task.checkCancellation()
            guard offline.canLosslessRemux else {
                throw OfflineDownloadError.message(offline.losslessNote)
            }

            metadata.qn = offline.play.quality
            metadata.audioQn = offline.play.audioQuality
            metadata.qnLabel = qualityLabel(for: offline.play)
            metadata.audioQnLabel = offline.play.audioQualityLabel
            metadata.status = .downloading
            metadata.progress = 0.18
            metadata.updatedAt = Date()
            upsert(metadata)
            writeMetadata(metadata, to: directory)

            let workDir = workDirectory(for: metadata.id)
            try? fileManager.removeItem(at: workDir)
            ensureDirectory(workDir)

            let danmakuMetadata = metadata
            async let danmakuResult: Void = saveDanmaku(metadata: danmakuMetadata, directory: directory)
            let videoSource = try await Self.downloadFirstAvailable(
                urls: [offline.play.url] + offline.play.backupUrls,
                to: workDir.appendingPathComponent("video-source.mp4"),
                headers: BiliHTTP.headers
            )
            try Task.checkCancellation()

            let finalVideoURL: URL
            if let audioURLString = offline.play.audioUrl {
                let audioSource = try await Self.downloadFirstAvailable(
                    urls: [audioURLString] + offline.play.audioBackupUrls,
                    to: workDir.appendingPathComponent("audio-source.mp4"),
                    headers: BiliHTTP.headers
                )
                metadata.status = .remuxing
                metadata.progress = 0.82
                metadata.updatedAt = Date()
                upsert(metadata)
                writeMetadata(metadata, to: directory)
                let remuxed = try await Self.remuxLosslessly(
                    videoURL: videoSource,
                    audioURL: audioSource,
                    outputDirectory: workDir,
                    containerCandidates: offline.losslessContainerCandidates
                )
                finalVideoURL = remuxed
            } else {
                finalVideoURL = videoSource
            }

            try Task.checkCancellation()
            metadata.videoFileName = "video.\(finalVideoURL.pathExtension.isEmpty ? "mp4" : finalVideoURL.pathExtension)"
            let destination = directory.appendingPathComponent(metadata.videoFileName)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: finalVideoURL, to: destination)

            _ = try? await danmakuResult
            metadata.status = .completed
            metadata.progress = 1
            metadata.errorMessage = nil
            metadata.updatedAt = Date()
            upsert(metadata)
            writeMetadata(metadata, to: directory)
            try? fileManager.removeItem(at: workDir)
            activeTasks[metadata.id] = nil
            AppLog.info("offline", "离线缓存完成", metadata: [
                "id": metadata.id,
                "file": metadata.videoFileName,
            ])
        } catch is CancellationError {
            metadata.status = .paused
            metadata.updatedAt = Date()
            upsert(metadata)
            writeMetadata(metadata, to: directory)
            activeTasks[metadata.id] = nil
        } catch {
            metadata.status = .failed
            metadata.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            metadata.updatedAt = Date()
            upsert(metadata)
            writeMetadata(metadata, to: directory)
            activeTasks[metadata.id] = nil
            AppLog.error("offline", "离线缓存失败", error: error, metadata: ["id": metadata.id])
        }
    }

    private func saveDanmaku(metadata: OfflineDownloadMetadata, directory: URL) async throws {
        guard metadata.cid > 0 else { return }
        do {
            let duration = metadata.durationSec
            let track = try await Task.detached(priority: .utility) {
                try CoreClient.shared.danmakuList(cid: metadata.cid, durationSec: duration)
            }.value
            let archive = OfflineDanmakuArchive(
                schemaVersion: 1,
                cid: metadata.cid,
                durationSec: metadata.durationSec,
                generatedAt: Date(),
                items: track.items
            )
            let data = try JSONEncoder.offline.encode(archive)
            try data.write(to: directory.appendingPathComponent(danmakuFileName), options: [.atomic])
            update(id: metadata.id) {
                $0.danmakuStatus = .completed
                $0.updatedAt = Date()
            }
        } catch {
            update(id: metadata.id) {
                $0.danmakuStatus = .failed
                $0.updatedAt = Date()
            }
            throw error
        }
    }

    private func update(id: String, mutate: (inout OfflineDownloadMetadata) -> Void) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var item = entries[idx]
        mutate(&item)
        entries[idx] = item
        if let dir = matchingEntryDirectories(for: id).first {
            writeMetadata(item, to: dir)
        }
    }

    private func upsert(_ metadata: OfflineDownloadMetadata) {
        if let idx = entries.firstIndex(where: { $0.id == metadata.id }) {
            entries[idx] = metadata
        } else {
            entries.insert(metadata, at: 0)
        }
        entries.sort { $0.updatedAt > $1.updatedAt }
    }

    private func writeMetadata(_ metadata: OfflineDownloadMetadata, to directory: URL) {
        do {
            let data = try JSONEncoder.offline.encode(metadata)
            try data.write(to: directory.appendingPathComponent(metadataFileName), options: [.atomic])
        } catch {
            AppLog.error("offline", "写入离线 metadata 失败", error: error, metadata: ["id": metadata.id])
        }
    }

    private func ensureDirectory(_ url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func entryDirectory(id: String, title: String) -> URL {
        rootDirectory.appendingPathComponent("\(safeFileName(title))-\(id)", isDirectory: true)
    }

    private func matchingEntryDirectories(for id: String) -> [URL] {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return dirs.filter { $0.lastPathComponent.hasSuffix("-\(id)") }
    }

    private func workDirectory(for id: String) -> URL {
        workRootDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func stableID(for item: FeedItemDTO, qn: Int64, audioQn: Int64) -> String {
        let media = item.isPGC ? "pgc-\(item.seasonID)-\(item.epID)" : "ugc-\(item.aid)-\(item.cid)"
        return "\(media)-q\(qn)-a\(audioQn)"
    }

    private func qualityLabel(for play: PlayUrlDTO) -> String {
        if let idx = play.acceptQuality.firstIndex(of: play.quality),
           play.acceptDescription.indices.contains(idx) {
            return play.acceptDescription[idx]
        }
        return play.quality > 0 ? "\(play.quality)P" : "自动"
    }

    private func safeFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "未命名" : cleaned).prefix(60))
    }

    private func requestPhotoAddOnly() async -> PHAuthorizationStatus {
        await withCheckedContinuation { (cc: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                cc.resume(returning: status)
            }
        }
    }

    private static func downloadFirstAvailable(
        urls: [String],
        to destination: URL,
        headers: [String: String]
    ) async throws -> URL {
        var lastError: Error?
        for raw in urls where !raw.isEmpty {
            guard let url = URL(string: raw) else { continue }
            do {
                var request = URLRequest(url: url)
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                let (tempURL, response) = try await URLSession.shared.download(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw OfflineDownloadError.message("HTTP \(http.statusCode)")
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tempURL, to: destination)
                return destination
            } catch {
                lastError = error
            }
        }
        throw lastError ?? OfflineDownloadError.message("没有可下载的地址")
    }

    private static func remuxLosslessly(
        videoURL: URL,
        audioURL: URL,
        outputDirectory: URL,
        containerCandidates: [String]
    ) async throws -> URL {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first else {
            throw OfflineDownloadError.message("视频轨道不可用")
        }
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw OfflineDownloadError.message("无法创建视频轨道")
        }
        let duration = try await videoAsset.load(.duration)
        try compositionVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: videoTrack,
            at: .zero
        )
        compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        if let audioTrack = audioTracks.first,
           let compositionAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let audioDuration = try await audioAsset.load(.duration)
            try compositionAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: audioDuration),
                of: audioTrack,
                at: .zero
            )
        }

        let uniqueCandidates = (containerCandidates + ["mp4", "m4v", "mov"]).reduce(into: [String]()) { out, ext in
            let lower = ext.lowercased()
            if !out.contains(lower) { out.append(lower) }
        }
        var lastError: Error?
        for ext in uniqueCandidates {
            guard let fileType = AVFileType.offlineFileType(forExtension: ext) else { continue }
            guard AVAssetExportSession.exportPresets(compatibleWith: composition).contains(AVAssetExportPresetPassthrough),
                  let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                throw OfflineDownloadError.message("系统不支持当前流的无损封装")
            }
            if !exporter.supportedFileTypes.contains(fileType) { continue }
            let output = outputDirectory.appendingPathComponent("video.\(ext)")
            try? FileManager.default.removeItem(at: output)
            exporter.outputURL = output
            exporter.outputFileType = fileType
            exporter.shouldOptimizeForNetworkUse = false
            do {
                try await exporter.offlineExport()
                return output
            } catch {
                lastError = error
            }
        }
        throw lastError ?? OfflineDownloadError.message("不支持无损离线缓存该格式")
    }
}

enum OfflineDownloadError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

private extension JSONEncoder {
    static var offline: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var offline: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension AVFileType {
    static func offlineFileType(forExtension ext: String) -> AVFileType? {
        switch ext.lowercased() {
        case "mp4": return .mp4
        case "m4v": return .m4v
        case "mov": return .mov
        default: return nil
        }
    }
}

private extension AVAssetExportSession {
    func offlineExport() async throws {
        try await withCheckedThrowingContinuation { continuation in
            exportAsynchronously {
                switch self.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .failed:
                    continuation.resume(throwing: self.error ?? OfflineDownloadError.message("无损封装失败"))
                default:
                    continuation.resume(throwing: OfflineDownloadError.message("无损封装未完成"))
                }
            }
        }
    }
}

struct OfflineCacheListView: View {
    @StateObject private var service = OfflineDownloadService.shared
    @State private var previewURL: URL?

    var body: some View {
        Group {
            if service.entries.isEmpty {
                emptyState(title: "暂无离线缓存", symbol: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(service.entries) { entry in
                        OfflineCacheRow(
                            entry: entry,
                            videoURL: service.videoURL(for: entry),
                            onOpen: { url in previewURL = url },
                            onPause: { service.pause(entry.id) },
                            onRetry: { service.retry(entry) },
                            onDelete: { service.delete(entry) }
                        )
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(IbiliTheme.background)
        .navigationTitle("离线缓存")
        .navigationBarTitleDisplayMode(.inline)
        .task { service.reloadFromDisk() }
        .sheet(item: Binding(
            get: { previewURL.map(PreviewURL.init(url:)) },
            set: { previewURL = $0?.url }
        )) { item in
            QuickLookPreview(url: item.url)
        }
    }
}

private struct OfflineCacheRow: View {
    let entry: OfflineDownloadMetadata
    let videoURL: URL?
    let onOpen: (URL) -> Void
    let onPause: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: entry.cover,
                        contentMode: .fill,
                        targetPointSize: CGSize(width: 240, height: 150),
                        quality: 75)
                .frame(width: 110, height: 68)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(entry.status == .failed ? .red : IbiliTheme.textSecondary)
                    .lineLimit(2)
                ProgressView(value: entry.progress)
                    .tint(entry.status == .failed ? .red : IbiliTheme.accent)
            }
            Spacer(minLength: 0)
            Menu {
                if entry.status == .completed, let videoURL {
                    Button("预览播放", systemImage: "play.rectangle") {
                        onOpen(videoURL)
                    }
                    ShareLink(item: videoURL) {
                        Label("分享文件", systemImage: "square.and.arrow.up")
                    }
                }
                if entry.status == .downloading || entry.status == .resolving || entry.status == .remuxing || entry.status == .queued {
                    Button("暂停", systemImage: "pause") { onPause() }
                }
                if entry.status == .paused {
                    Button("继续", systemImage: "play") { onRetry() }
                }
                if entry.status == .failed {
                    Button("重试", systemImage: "arrow.clockwise") { onRetry() }
                }
                Button("删除", systemImage: "trash", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(IbiliTheme.textSecondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var statusLine: String {
        if let error = entry.errorMessage, entry.status == .failed {
            return "\(entry.status.label) · \(error)"
        }
        let quality = [entry.qnLabel, entry.audioQnLabel].filter { !$0.isEmpty }.joined(separator: " / ")
        let danmaku = entry.danmakuStatus == .failed ? " · 弹幕失败" : ""
        return "\(entry.status.label) · \(quality)\(danmaku)"
    }
}

private struct PreviewURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
