import Foundation

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

struct OfflineLibraryRecord {
    var metadata: OfflineDownloadMetadata
    let directory: URL
    var index: OfflineMediaIndex?
    var videoURL: URL?
    var allDirectories: [URL] = []
}

enum OfflineLibraryIndex {
    static func scan(_ root: URL) throws -> [String: OfflineLibraryRecord] {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let directories = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [String: OfflineLibraryRecord] = [:]
        for directory in directories {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("metadata.json")),
                  let metadata = try? decoder.decode(OfflineDownloadMetadata.self, from: data) else { continue }
            let allDirectories = (records[metadata.id]?.allDirectories ?? []) + [directory]
            if let existing = records[metadata.id], existing.metadata.updatedAt >= metadata.updatedAt {
                records[metadata.id]?.allDirectories = allDirectories
                continue
            }
            let index = (try? Data(contentsOf: directory.appendingPathComponent("index.json")))
                .flatMap { try? decoder.decode(OfflineMediaIndex.self, from: $0) }
            let video = directory.appendingPathComponent(metadata.videoFileName)
            let standalone = metadata.storageMode != "bilibili_dash" && metadata.audioFileName?.isEmpty != false
            records[metadata.id] = OfflineLibraryRecord(metadata: metadata, directory: directory, index: index,
                videoURL: standalone && fm.fileExists(atPath: video.path) ? video : nil, allDirectories: allDirectories)
        }
        return records
    }
}
