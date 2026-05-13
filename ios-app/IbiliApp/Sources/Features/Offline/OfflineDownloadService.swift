import Foundation
import SwiftUI
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
        case .remuxing: return "整理文件"
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
    var audioFileName: String?
    var indexFileName: String?
    var storageMode: String?
    var streamType: String?
    var videoCodec: String?
    var audioCodec: String?
    var videoWidth: Int?
    var videoHeight: Int?
    var videoFrameRate: String?
    var videoRange: String?
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var downloadSpeedBytesPerSecond: Double?
    var downloadProgressNote: String?
}

struct OfflineDanmakuArchive: Codable {
    let schemaVersion: Int
    let cid: Int64
    let durationSec: Int64
    let generatedAt: Date
    let items: [DanmakuItemDTO]
}

struct OfflineMediaIndex: Codable {
    let schemaVersion: Int
    let storageMode: String
    let sourceType: String
    let aid: Int64
    let bvid: String
    let cid: Int64
    let epID: Int64
    let seasonID: Int64
    let title: String
    let author: String
    let generatedAt: Date
    let play: PlayUrlDTO
    let videoFileName: String
    let audioFileName: String?
    let danmakuFileName: String
}

struct OfflinePlaybackSource {
    let metadata: OfflineDownloadMetadata
    let directory: URL
    let play: PlayUrlDTO
}

struct OfflineDownloadRequest: Hashable {
    let item: FeedItemDTO
    let qn: Int64
    let qnLabel: String
    let audioQn: Int64
    let audioQnLabel: String
    let cdn: String
}

private struct OfflineDownloadProgress: Sendable {
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let speedBytesPerSecond: Double
}

private struct PendingOfflineDownload {
    let request: OfflineDownloadRequest
    let metadata: OfflineDownloadMetadata
    let directory: URL
}

@MainActor
final class OfflineDownloadService: ObservableObject {
    static let shared = OfflineDownloadService()

    @Published private(set) var entries: [OfflineDownloadMetadata] = []

    private let maxConcurrentDownloads = 1
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var pendingDownloads: [PendingOfflineDownload] = []
    private let fileManager = FileManager.default
    private let metadataFileName = "metadata.json"
    private let indexFileName = "index.json"
    private let danmakuFileName = "danmaku.json"
    private let nativeDashVideoFileName = "video.m4s"
    private let nativeDashAudioFileName = "audio.m4s"

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
        pendingDownloads.removeAll { $0.metadata.id == id }
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
        metadata.downloadedBytes = 0
        metadata.totalBytes = nil
        metadata.downloadSpeedBytesPerSecond = 0
        metadata.downloadProgressNote = nil
        metadata.indexFileName = indexFileName
        metadata.storageMode = "pending"
        upsert(metadata)
        writeMetadata(metadata, to: dir)

        pendingDownloads.append(PendingOfflineDownload(request: request, metadata: metadata, directory: dir))
        scheduleDownloads()
    }

    func pause(_ id: String) {
        pendingDownloads.removeAll { $0.metadata.id == id }
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
        pendingDownloads.removeAll { $0.metadata.id == metadata.id }
        activeTasks[metadata.id]?.cancel()
        activeTasks[metadata.id] = nil
        let dirs = matchingEntryDirectories(for: metadata.id)
        dirs.forEach { try? fileManager.removeItem(at: $0) }
        try? fileManager.removeItem(at: workDirectory(for: metadata.id))
        entries.removeAll { $0.id == metadata.id }
    }

    func videoURL(for metadata: OfflineDownloadMetadata) -> URL? {
        guard metadata.storageMode != "bilibili_dash",
              metadata.audioFileName?.isEmpty != false else {
            return nil
        }
        guard let dir = matchingEntryDirectories(for: metadata.id).first else { return nil }
        let url = dir.appendingPathComponent(metadata.videoFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func directoryURL(for metadata: OfflineDownloadMetadata) -> URL? {
        guard let dir = matchingEntryDirectories(for: metadata.id).first else { return nil }
        return fileManager.fileExists(atPath: dir.path) ? dir : nil
    }

    func playbackSource(for item: FeedItemDTO, preferredQn: Int64 = 0, audioQn: Int64 = 0) -> OfflinePlaybackSource? {
        let matches = entries.filter { metadata in
            guard metadata.status == .completed else { return false }
            guard metadata.cid == item.cid else { return false }
            if item.isPGC || metadata.sourceType == "pgc" {
                if item.epID > 0, metadata.epID > 0, item.epID != metadata.epID { return false }
                if item.seasonID > 0, metadata.seasonID > 0, item.seasonID != metadata.seasonID { return false }
            } else if item.aid > 0, metadata.aid > 0, item.aid != metadata.aid {
                return false
            }
            return true
        }
        guard let metadata = bestPlaybackMetadata(
            from: matches,
            preferredQn: preferredQn,
            audioQn: audioQn
        ),
              let directory = matchingEntryDirectories(for: metadata.id).first,
              let index = readIndex(in: directory) else {
            return nil
        }

        let videoURL = directory.appendingPathComponent(index.videoFileName)
        guard fileManager.fileExists(atPath: videoURL.path) else { return nil }
        let audioURL = index.audioFileName.map { directory.appendingPathComponent($0) }
        if let audioURL, !fileManager.fileExists(atPath: audioURL.path) {
            return nil
        }
        var play = index.play
        play = play.replacingLocalMediaURLs(
            videoURL: videoURL,
            audioURL: audioURL
        )
        return OfflinePlaybackSource(metadata: metadata, directory: directory, play: play)
    }

    func danmakuItems(for item: FeedItemDTO) -> [DanmakuItemDTO]? {
        guard let source = playbackSource(for: item),
              !source.metadata.danmakuFileName.isEmpty else {
            return nil
        }
        let url = source.directory.appendingPathComponent(source.metadata.danmakuFileName)
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder.offline.decode(OfflineDanmakuArchive.self, from: data) else {
            return nil
        }
        return archive.items.sorted { $0.timeSec < $1.timeSec }
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
                    bvid: request.item.bvid,
                    cid: request.item.cid,
                    qn: request.qn,
                    audioQn: request.audioQn,
                    cdn: request.cdn
                )
            }.value

            try Task.checkCancellation()
            let trimmedAudioURL = offline.play.audioUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasSeparateAudio = trimmedAudioURL?.isEmpty == false
            let storageMode = hasSeparateAudio ? "bilibili_dash" : "bilibili_single"
            let videoFileName = hasSeparateAudio
                ? nativeDashVideoFileName
                : Self.singleStreamFileName(for: offline.play)
            let audioFileName = hasSeparateAudio ? nativeDashAudioFileName : nil
            let mediaDownloadCount = hasSeparateAudio ? 2 : 1

            metadata.qn = offline.play.quality
            metadata.audioQn = offline.play.audioQuality
            metadata.qnLabel = qualityLabel(for: offline.play)
            metadata.audioQnLabel = offline.play.audioQualityLabel
            metadata.videoFileName = videoFileName
            metadata.audioFileName = audioFileName
            metadata.indexFileName = indexFileName
            metadata.storageMode = storageMode
            metadata.streamType = offline.play.streamType
            metadata.videoCodec = offline.play.videoCodec
            metadata.audioCodec = offline.play.audioCodec
            metadata.videoWidth = offline.play.videoWidth
            metadata.videoHeight = offline.play.videoHeight
            metadata.videoFrameRate = offline.play.videoFrameRate
            metadata.videoRange = offline.play.videoRange
            metadata.status = .downloading
            metadata.progress = 0.18
            metadata.downloadedBytes = 0
            metadata.totalBytes = nil
            metadata.downloadSpeedBytesPerSecond = 0
            metadata.downloadProgressNote = mediaDownloadCount > 1 ? "视频 1/2" : "视频"
            metadata.updatedAt = Date()
            upsert(metadata)
            writeMetadata(metadata, to: directory)

            let workDir = workDirectory(for: metadata.id)
            try? fileManager.removeItem(at: workDir)
            ensureDirectory(workDir)

            let danmakuMetadata = metadata
            async let danmakuResult: Void = saveDanmaku(metadata: danmakuMetadata, directory: directory)
            var completedMediaBytes: Int64 = 0
            var totalMediaBytes: Int64?
            let progressID = metadata.id
            let mediaCount = mediaDownloadCount
            let videoCompletedBefore: Int64 = 0
            let videoSource = try await Self.downloadFirstAvailable(
                urls: [offline.play.url] + offline.play.backupUrls,
                to: workDir.appendingPathComponent(videoFileName),
                headers: BiliHTTP.headers,
                progress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.applyDownloadProgress(
                            id: progressID,
                            completedBytesBeforeCurrentFile: videoCompletedBefore,
                            currentFileProgress: progress,
                            fileIndex: 1,
                            fileCount: mediaCount,
                            label: "视频",
                            baseProgress: 0.18,
                            mediaProgressSpan: 0.72
                        )
                    }
                }
            )
            completedMediaBytes += Self.fileSize(at: videoSource)
            if let currentTotal = entries.first(where: { $0.id == metadata.id })?.totalBytes, currentTotal > 0 {
                totalMediaBytes = currentTotal
            }
            try Task.checkCancellation()

            metadata.progress = hasSeparateAudio ? 0.55 : 0.82
            if let latest = entries.first(where: { $0.id == metadata.id }) {
                metadata.downloadedBytes = latest.downloadedBytes
                metadata.totalBytes = latest.totalBytes
                metadata.downloadSpeedBytesPerSecond = latest.downloadSpeedBytesPerSecond
            }
            metadata.updatedAt = Date()
            upsert(metadata)
            writeMetadata(metadata, to: directory)

            var audioSource: URL?
            if let audioURLString = trimmedAudioURL, !audioURLString.isEmpty {
                let audioCompletedBefore = completedMediaBytes
                let audioKnownTotalBefore = totalMediaBytes
                audioSource = try await Self.downloadFirstAvailable(
                    urls: [audioURLString] + offline.play.audioBackupUrls,
                    to: workDir.appendingPathComponent(nativeDashAudioFileName),
                    headers: BiliHTTP.headers,
                    progress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.applyDownloadProgress(
                                id: progressID,
                                completedBytesBeforeCurrentFile: audioCompletedBefore,
                                knownTotalBytesBeforeCurrentFile: audioKnownTotalBefore,
                                currentFileProgress: progress,
                                fileIndex: 2,
                                fileCount: mediaCount,
                                label: "音频",
                                baseProgress: 0.18,
                                mediaProgressSpan: 0.72
                            )
                        }
                    }
                )
                try Task.checkCancellation()
                metadata.status = .remuxing
                metadata.progress = 0.82
                if let latest = entries.first(where: { $0.id == metadata.id }) {
                    metadata.downloadedBytes = latest.downloadedBytes
                    metadata.totalBytes = latest.totalBytes
                    metadata.downloadSpeedBytesPerSecond = latest.downloadSpeedBytesPerSecond
                }
                metadata.updatedAt = Date()
                upsert(metadata)
                writeMetadata(metadata, to: directory)
            }

            try Task.checkCancellation()
            ensureDirectory(directory)
            try replaceDownloadedFile(at: videoSource, to: directory.appendingPathComponent(videoFileName))
            if let audioSource, let audioFileName {
                try replaceDownloadedFile(at: audioSource, to: directory.appendingPathComponent(audioFileName))
            }
            let index = OfflineMediaIndex(
                schemaVersion: 1,
                storageMode: storageMode,
                sourceType: metadata.sourceType,
                aid: metadata.aid,
                bvid: metadata.bvid,
                cid: metadata.cid,
                epID: metadata.epID,
                seasonID: metadata.seasonID,
                title: metadata.title,
                author: metadata.author,
                generatedAt: Date(),
                play: offline.play,
                videoFileName: videoFileName,
                audioFileName: audioFileName,
                danmakuFileName: danmakuFileName
            )
            try writeIndex(index, to: directory)

            _ = try? await danmakuResult
            if let latest = entries.first(where: { $0.id == metadata.id }) {
                metadata.danmakuStatus = latest.danmakuStatus
                metadata.downloadedBytes = latest.downloadedBytes
                metadata.totalBytes = latest.totalBytes
            }
            metadata.status = .completed
            metadata.progress = 1
            metadata.downloadSpeedBytesPerSecond = 0
            metadata.downloadProgressNote = nil
            metadata.errorMessage = nil
            metadata.updatedAt = Date()
            upsert(metadata)
            writeMetadata(metadata, to: directory)
            try? fileManager.removeItem(at: workDir)
            activeTasks[metadata.id] = nil
            AppLog.info("offline", "离线缓存完成", metadata: [
                "id": metadata.id,
                "file": metadata.videoFileName,
                "audioFile": metadata.audioFileName ?? "-",
                "storageMode": metadata.storageMode ?? "-",
            ])
            scheduleDownloads()
        } catch is CancellationError {
            if let latest = entries.first(where: { $0.id == metadata.id }) {
                metadata.progress = latest.progress
                metadata.downloadedBytes = latest.downloadedBytes
                metadata.totalBytes = latest.totalBytes
                metadata.downloadProgressNote = latest.downloadProgressNote
            }
            metadata.status = .paused
            metadata.downloadSpeedBytesPerSecond = 0
            metadata.updatedAt = Date()
            upsert(metadata)
            writeMetadata(metadata, to: directory)
            activeTasks[metadata.id] = nil
            scheduleDownloads()
        } catch {
            if let latest = entries.first(where: { $0.id == metadata.id }) {
                metadata.progress = latest.progress
                metadata.downloadedBytes = latest.downloadedBytes
                metadata.totalBytes = latest.totalBytes
                metadata.downloadProgressNote = latest.downloadProgressNote
            }
            metadata.status = .failed
            metadata.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            metadata.downloadSpeedBytesPerSecond = 0
            metadata.updatedAt = Date()
            upsert(metadata)
            writeMetadata(metadata, to: directory)
            activeTasks[metadata.id] = nil
            AppLog.error("offline", "离线缓存失败", error: error, metadata: ["id": metadata.id])
            scheduleDownloads()
        }
    }

    private func scheduleDownloads() {
        while activeTasks.count < maxConcurrentDownloads, !pendingDownloads.isEmpty {
            let pending = pendingDownloads.removeFirst()
            activeTasks[pending.metadata.id] = Task { [weak self] in
                await self?.performDownload(
                    request: pending.request,
                    metadata: pending.metadata,
                    directory: pending.directory
                )
            }
            AppLog.info("offline", "离线任务开始", metadata: [
                "id": pending.metadata.id,
                "active": "\(activeTasks.count)",
                "pending": "\(pendingDownloads.count)",
            ])
        }
    }

    private func saveDanmaku(metadata: OfflineDownloadMetadata, directory: URL) async throws {
        guard metadata.cid > 0 else { return }
        do {
            ensureDirectory(directory)
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

    private func updateMemoryOnly(id: String, mutate: (inout OfflineDownloadMetadata) -> Void) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var item = entries[idx]
        mutate(&item)
        entries[idx] = item
        entries.sort { $0.updatedAt > $1.updatedAt }
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
            ensureDirectory(directory)
            let data = try JSONEncoder.offline.encode(metadata)
            try data.write(to: directory.appendingPathComponent(metadataFileName), options: [.atomic])
        } catch {
            AppLog.error("offline", "写入离线 metadata 失败", error: error, metadata: ["id": metadata.id])
        }
    }

    private func applyDownloadProgress(
        id: String,
        completedBytesBeforeCurrentFile: Int64,
        knownTotalBytesBeforeCurrentFile: Int64? = nil,
        currentFileProgress: OfflineDownloadProgress,
        fileIndex: Int,
        fileCount: Int,
        label: String,
        baseProgress: Double,
        mediaProgressSpan: Double
    ) {
        let downloaded = completedBytesBeforeCurrentFile + currentFileProgress.downloadedBytes
        let total = knownTotalBytesBeforeCurrentFile.flatMap { known -> Int64? in
            guard let currentTotal = currentFileProgress.totalBytes, currentTotal > 0 else { return nil }
            return known + currentTotal
        } ?? currentFileProgress.totalBytes.map { completedBytesBeforeCurrentFile + $0 }
        let mediaFraction: Double
        if let total, total > 0 {
            mediaFraction = min(1, max(0, Double(downloaded) / Double(total)))
        } else {
            let perFile = 1.0 / Double(max(fileCount, 1))
            let currentFraction = min(1, max(0, Double(currentFileProgress.downloadedBytes) / Double(max(currentFileProgress.totalBytes ?? 0, 1))))
            mediaFraction = min(1, (Double(fileIndex - 1) * perFile) + currentFraction * perFile)
        }
        let progress = min(0.94, max(baseProgress, baseProgress + mediaProgressSpan * mediaFraction))
        updateMemoryOnly(id: id) {
            $0.status = .downloading
            $0.progress = progress
            $0.downloadedBytes = downloaded
            $0.totalBytes = total
            $0.downloadSpeedBytesPerSecond = currentFileProgress.speedBytesPerSecond
            $0.downloadProgressNote = fileCount > 1 ? "\(label) \(fileIndex)/\(fileCount)" : label
            $0.updatedAt = Date()
        }
    }

    private func ensureDirectory(_ url: URL) {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                try? fileManager.removeItem(at: url)
                try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
        } else {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func replaceDownloadedFile(at source: URL, to destination: URL) throws {
        ensureDirectory(destination.deletingLastPathComponent())
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: source, to: destination)
    }

    private func writeIndex(_ index: OfflineMediaIndex, to directory: URL) throws {
        ensureDirectory(directory)
        let data = try JSONEncoder.offline.encode(index)
        try data.write(to: directory.appendingPathComponent(indexFileName), options: [.atomic])
    }

    private func readIndex(in directory: URL) -> OfflineMediaIndex? {
        let url = directory.appendingPathComponent(indexFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.offline.decode(OfflineMediaIndex.self, from: data)
    }

    private func bestPlaybackMetadata(
        from matches: [OfflineDownloadMetadata],
        preferredQn: Int64,
        audioQn: Int64
    ) -> OfflineDownloadMetadata? {
        guard !matches.isEmpty else { return nil }
        return matches.sorted { lhs, rhs in
            let lhsExactVideo = preferredQn > 0 && lhs.qn == preferredQn
            let rhsExactVideo = preferredQn > 0 && rhs.qn == preferredQn
            if lhsExactVideo != rhsExactVideo { return lhsExactVideo }
            let lhsExactAudio = audioQn > 0 && lhs.audioQn == audioQn
            let rhsExactAudio = audioQn > 0 && rhs.audioQn == audioQn
            if lhsExactAudio != rhsExactAudio { return lhsExactAudio }
            if lhs.qn != rhs.qn { return lhs.qn > rhs.qn }
            if lhs.audioQn != rhs.audioQn { return lhs.audioQn > rhs.audioQn }
            return lhs.updatedAt > rhs.updatedAt
        }.first
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

    private static func singleStreamFileName(for play: PlayUrlDTO) -> String {
        let ext = originalFileExtension(from: play.url, format: play.format)
        return "video.\(ext)"
    }

    private static func originalFileExtension(from rawURL: String, format: String) -> String {
        let allowed = Set(["mp4", "m4v", "mov", "flv", "m4s"])
        if let ext = URL(string: rawURL)?.pathExtension.lowercased(),
           allowed.contains(ext) {
            return ext
        }
        let lowerFormat = format.lowercased()
        if lowerFormat.contains("flv") { return "flv" }
        if lowerFormat.contains("m4s") { return "m4s" }
        if lowerFormat.contains("m4v") { return "m4v" }
        if lowerFormat.contains("mov") { return "mov" }
        return "mp4"
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
        headers: [String: String],
        progress: @escaping @Sendable (OfflineDownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        var lastError: Error?
        for raw in urls where !raw.isEmpty {
            guard let url = URL(string: raw) else { continue }
            do {
                var request = URLRequest(url: url)
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                let downloader = OfflineProgressDownloader(progress: progress)
                let (tempURL, response) = try await downloader.download(request)
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

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
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

private final class OfflineProgressDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (OfflineDownloadProgress) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var response: URLResponse?
    private var lastSampleDate = Date()
    private var lastSampleBytes: Int64 = 0
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = BiliHTTP.headers
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(progress: @escaping @Sendable (OfflineDownloadProgress) -> Void) {
        self.progress = progress
    }

    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = session.downloadTask(with: request)
                task.resume()
            }
        }, onCancel: {
            self.session.invalidateAndCancel()
        })
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleDate)
        let byteDelta = totalBytesWritten - lastSampleBytes
        let speed = elapsed > 0 ? Double(byteDelta) / elapsed : 0
        if elapsed >= 0.35 || totalBytesWritten == totalBytesExpectedToWrite {
            lastSampleDate = now
            lastSampleBytes = totalBytesWritten
            progress(OfflineDownloadProgress(
                downloadedBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil,
                speedBytesPerSecond: max(0, speed)
            ))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        response = downloadTask.response
        guard let response else {
            continuation?.resume(throwing: OfflineDownloadError.message("下载响应为空"))
            continuation = nil
            session.finishTasksAndInvalidate()
            return
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.moveItem(at: location, to: temp)
            continuation?.resume(returning: (temp, response))
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error, continuation != nil {
            continuation?.resume(throwing: error)
            continuation = nil
            session.finishTasksAndInvalidate()
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

struct OfflineCacheListView: View {
    @StateObject private var service = OfflineDownloadService.shared
    @State private var previewURL: URL?
    @State private var searchText = ""
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.prefersSplitRootSelection) private var prefersSplitRootSelection

    private var filteredEntries: [OfflineDownloadMetadata] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return service.entries }
        return service.entries.filter { entry in
            [
                entry.title,
                entry.author,
                entry.bvid,
                entry.qnLabel,
                entry.audioQnLabel,
            ].contains { $0.localizedCaseInsensitiveContains(keyword) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !service.entries.isEmpty {
                OfflineCacheSearchBar(text: $searchText)
            }
            Group {
                if service.entries.isEmpty {
                    emptyState(title: "暂无离线缓存", symbol: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredEntries.isEmpty {
                    emptyState(title: "没有搜索结果", symbol: "magnifyingglass")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredEntries) { entry in
                            OfflineCacheRow(
                                entry: entry,
                                videoURL: service.videoURL(for: entry),
                                directoryURL: service.directoryURL(for: entry),
                                onOpen: { url in previewURL = url },
                                onPlay: {
                                    if prefersSplitRootSelection {
                                        router.selectOffline(entry.feedItem)
                                    } else {
                                        router.openOffline(entry.feedItem)
                                    }
                                },
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

private struct OfflineCacheSearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(IbiliTheme.textSecondary)
            TextField("搜索离线缓存", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

private struct OfflineCacheRow: View {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    let entry: OfflineDownloadMetadata
    let videoURL: URL?
    let directoryURL: URL?
    let onOpen: (URL) -> Void
    let onPlay: () -> Void
    let onPause: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: {
                if entry.status == .completed { onPlay() }
            }) {
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
                            .foregroundStyle(IbiliTheme.textPrimary)
                            .lineLimit(2)
                        if entry.status == .completed {
                            if !entry.author.isEmpty {
                                Label(entry.author, systemImage: "person.crop.circle")
                                    .font(.caption2)
                                    .foregroundStyle(IbiliTheme.textSecondary)
                                    .lineLimit(1)
                            }
                        } else {
                            Text(statusLine)
                                .font(.caption2)
                                .foregroundStyle(entry.status == .failed ? .red : IbiliTheme.textSecondary)
                                .lineLimit(2)
                            ProgressView(value: entry.progress)
                                .tint(entry.status == .failed ? .red : IbiliTheme.accent)
                        }
                        if let progressDetail {
                            Text(progressDetail)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(IbiliTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(entry.status != .completed)
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
                if entry.status == .completed, let directoryURL {
                    ShareLink(item: directoryURL) {
                        Label("分享原始文件夹", systemImage: "folder")
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
        let storage = storageLabel
        let danmaku = entry.danmakuStatus == .failed ? " · 弹幕失败" : ""
        return "\(entry.status.label) · \(storage) · \(quality)\(danmaku)"
    }

    private var progressDetail: String? {
        guard entry.status == .downloading || entry.status == .resolving || entry.status == .remuxing || entry.status == .paused else {
            return nil
        }
        let percent = "\(Int((entry.progress * 100).rounded()))%"
        let speed = formatSpeed(entry.downloadSpeedBytesPerSecond ?? 0)
        let bytes = bytesProgressText
        let note = entry.downloadProgressNote?.isEmpty == false ? "\(entry.downloadProgressNote!) · " : ""
        return "\(note)\(percent) · \(speed)\(bytes.map { " · \($0)" } ?? "")"
    }

    private var bytesProgressText: String? {
        guard let downloaded = entry.downloadedBytes, downloaded > 0 else { return nil }
        if let total = entry.totalBytes, total > 0 {
            return "\(formatBytes(downloaded)) / \(formatBytes(total))"
        }
        return formatBytes(downloaded)
    }

    private var storageLabel: String {
        switch entry.storageMode {
        case "bilibili_dash":
            return "B站原始 DASH"
        case "bilibili_single":
            return "原始单流"
        case "pending":
            return "原始结构"
        default:
            if entry.audioFileName?.isEmpty == false {
                return "B站原始 DASH"
            }
            return "原始文件"
        }
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 1 else { return "0 KB/s" }
        return "\(formatBytes(Int64(bytesPerSecond)))/s"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = Self.byteFormatter
        formatter.allowedUnits = bytes >= 1024 * 1024 ? [.useMB, .useGB] : [.useKB]
        return formatter.string(fromByteCount: bytes)
    }
}

private extension OfflineDownloadMetadata {
    var feedItem: FeedItemDTO {
        FeedItemDTO(
            aid: aid,
            bvid: bvid,
            cid: cid,
            title: title,
            cover: cover,
            author: author,
            durationSec: durationSec,
            play: 0,
            danmaku: 0,
            epID: epID,
            seasonID: seasonID,
            isPGC: sourceType == "pgc"
        )
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
