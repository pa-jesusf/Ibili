import Foundation
import SwiftUI

actor AppLogPersistence {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileName: String = "app-logs.json") {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = root.appendingPathComponent("Ibili", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent(fileName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func loadEntries() -> [AppLogEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([AppLogEntry].self, from: data)) ?? []
    }

    func saveEntries(_ entries: [AppLogEntry]) {
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

actor AppLogSharedFileSink {
    private let directoryURL: URL
    private let currentURL: URL
    private let maxFileBytes = 8 * 1024 * 1024
    private let maxArchiveCount = 3

    init(directoryName: String = "IbiliLogs", fileName: String = "ibili-current.log") {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directoryURL = root.appendingPathComponent(directoryName, isDirectory: true)
        self.currentURL = directoryURL.appendingPathComponent(fileName)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func markSessionStarted() {
        let cap = "cap=current 8MB + 3 archives (~32MB total)"
        appendLine("----- Ibili log session started at \(Self.timestampFormatter.string(from: Date())) | \(cap) -----")
    }

    func append(_ entry: AppLogEntry) {
        appendLine(entry.formattedLine)
    }

    func clear() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: currentURL)
        for index in 1...maxArchiveCount {
            try? fileManager.removeItem(at: archivedURL(index: index))
        }
    }

    private func appendLine(_ line: String) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        rotateIfNeeded(additionalBytes: data.count)
        if !FileManager.default.fileExists(atPath: currentURL.path) {
            FileManager.default.createFile(atPath: currentURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: currentURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            try? handle.close()
        }
    }

    private func rotateIfNeeded(additionalBytes: Int) {
        let currentSize = fileSize(at: currentURL)
        guard currentSize > 0, currentSize + UInt64(additionalBytes) > UInt64(maxFileBytes) else {
            return
        }

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: archivedURL(index: maxArchiveCount))
        if maxArchiveCount >= 2 {
            for index in stride(from: maxArchiveCount - 1, through: 1, by: -1) {
                let source = archivedURL(index: index)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try? fileManager.moveItem(at: source, to: archivedURL(index: index + 1))
            }
        }
        if fileManager.fileExists(atPath: currentURL.path) {
            try? fileManager.moveItem(at: currentURL, to: archivedURL(index: 1))
        }
    }

    private func archivedURL(index: Int) -> URL {
        directoryURL.appendingPathComponent("ibili-\(index).log")
    }

    private func fileSize(at url: URL) -> UInt64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return 0 }
        return UInt64(max(size, 0))
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

@MainActor
final class AppLogStore: ObservableObject {
    static let shared = AppLogStore()

    private struct SharedFileCoalescingState {
        let signature: String
        let sample: AppLogEntry
        var lastTimestamp: Date
        var suppressedCount: Int = 0
    }

    @Published private(set) var entries: [AppLogEntry] = []

    private let persistence = AppLogPersistence()
    private let sharedFileSink = AppLogSharedFileSink()
    private let maxEntries = 1_000
    private let sharedFileCoalescingWindow: TimeInterval = 2
    private var sharedFileCoalescingState: SharedFileCoalescingState?

    private init() {
        Task {
            await sharedFileSink.markSessionStarted()
            await restorePersistedEntries()
        }
    }

    func log(level: AppLogLevel,
             category: String,
             message: String,
             metadata: [String: String] = [:]) {
        let normalizedCategory = AppLogCategoryCatalog.normalizedKey(category)
        let entry = AppLogEntry(level: level,
                    category: normalizedCategory,
                    message: message,
                    metadata: metadata)
        entries.append(entry)
        entries = trimToMaxEntries(entries)
        let snapshot = entries
        let fileEntries = entriesForSharedFile(entry)
        Task {
            for fileEntry in fileEntries {
                await sharedFileSink.append(fileEntry)
            }
            await persistence.saveEntries(snapshot)
        }
    }

    func clear() {
        entries.removeAll()
        sharedFileCoalescingState = nil
        Task {
            await sharedFileSink.clear()
            await persistence.clear()
        }
    }

    private func restorePersistedEntries() async {
        let persisted = await persistence.loadEntries()
        let merged = mergeEntries(persisted, with: entries)
        let trimmed = trimToMaxEntries(merged)
        self.entries = trimmed
        if trimmed.count != persisted.count || trimmed != persisted {
            await persistence.saveEntries(trimmed)
        }
    }

    private func trimToMaxEntries(_ items: [AppLogEntry]) -> [AppLogEntry] {
        Array(items.suffix(maxEntries))
    }

    private func entriesForSharedFile(_ entry: AppLogEntry) -> [AppLogEntry] {
        var output: [AppLogEntry] = []
        let signature = sharedFileCoalescingSignature(for: entry)

        if let state = sharedFileCoalescingState {
            let elapsed = entry.timestamp.timeIntervalSince(state.lastTimestamp)
            if signature == state.signature, elapsed <= sharedFileCoalescingWindow {
                sharedFileCoalescingState?.lastTimestamp = entry.timestamp
                sharedFileCoalescingState?.suppressedCount += 1
                return output
            }

            if let summary = sharedFileCoalescingSummary(from: state) {
                output.append(summary)
            }
            sharedFileCoalescingState = nil
        }

        if let signature {
            sharedFileCoalescingState = SharedFileCoalescingState(
                signature: signature,
                sample: entry,
                lastTimestamp: entry.timestamp
            )
        }
        output.append(entry)
        return output
    }

    private func sharedFileCoalescingSignature(for entry: AppLogEntry) -> String? {
        guard entry.level == .debug, entry.category == "navigation" || entry.category == "player" else { return nil }
        let ignoredKeys: Set<String> = [
            "callStack",
            "point",
            "traceAgeMs",
            "traceID",
            "transientPauseSuppressionRemainingMs",
        ]
        let stableMetadata = entry.metadata
            .filter { !ignoredKeys.contains($0.key) }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "|")
        return "\(entry.category)|\(entry.message)|\(stableMetadata)"
    }

    private func sharedFileCoalescingSummary(from state: SharedFileCoalescingState) -> AppLogEntry? {
        guard state.suppressedCount > 0 else { return nil }
        return AppLogEntry(
            timestamp: state.lastTimestamp,
            level: state.sample.level,
            category: state.sample.category,
            message: "重复调试日志已折叠",
            metadata: [
                "originalMessage": state.sample.message,
                "suppressedCount": String(state.suppressedCount),
            ]
        )
    }

    private func mergeEntries(_ lhs: [AppLogEntry], with rhs: [AppLogEntry]) -> [AppLogEntry] {
        var deduped: [UUID: AppLogEntry] = [:]
        for entry in lhs + rhs {
            deduped[entry.id] = entry
        }
        return deduped.values.sorted { $0.timestamp < $1.timestamp }
    }
}

enum AppLog {
    static func debug(_ category: String,
                      _ message: String,
                      metadata: [String: String] = [:]) {
        write(level: .debug, category: category, message: message, metadata: metadata)
    }

    static func info(_ category: String,
                     _ message: String,
                     metadata: [String: String] = [:]) {
        write(level: .info, category: category, message: message, metadata: metadata)
    }

    static func warning(_ category: String,
                        _ message: String,
                        metadata: [String: String] = [:]) {
        write(level: .warning, category: category, message: message, metadata: metadata)
    }

    static func error(_ category: String,
                      _ message: String,
                      error: Error? = nil,
                      metadata: [String: String] = [:]) {
        var merged = metadata
        if let error {
            merged["error"] = error.localizedDescription
        }
        write(level: .error, category: category, message: message, metadata: merged)
    }

    private static func write(level: AppLogLevel,
                              category: String,
                              message: String,
                              metadata: [String: String]) {
        Task { @MainActor in
            AppLogStore.shared.log(level: level,
                                   category: category,
                                   message: message,
                                   metadata: metadata)
        }
    }
}
