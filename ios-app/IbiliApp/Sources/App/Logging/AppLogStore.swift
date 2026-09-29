import Foundation
import SwiftUI
import Combine

protocol AppLogPersistenceStore: Sendable {
    func loadEntries() async -> [AppLogEntry]
    func saveEntries(_ entries: [AppLogEntry]) async
    func clear() async
}

protocol AppLogFileSink: Sendable {
    func markSessionStarted() async
    func append(_ entry: AppLogEntry) async
    func clear() async
}

actor AppLogPersistence: AppLogPersistenceStore {
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

actor AppLogSharedFileSink: AppLogFileSink {
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


    @Published private(set) var entries: [AppLogEntry] = []

    private let persistence: any AppLogPersistenceStore
    private let sharedFileSink: any AppLogFileSink
    private let maxEntries = 1_000
    private var coalescer = AppLogCoalescer()
    private var pendingFileEntries: [AppLogEntry] = []
    private var flushTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var lifecycleSubscription: AnyCancellable?
    private var clearGeneration = 0
    private var needsPersistence = false

    init(persistence: any AppLogPersistenceStore = AppLogPersistence(),
         sharedFileSink: any AppLogFileSink = AppLogSharedFileSink()) {
        self.persistence = persistence
        self.sharedFileSink = sharedFileSink
        lifecycleSubscription = NotificationCenter.default.publisher(for: Notification.Name("UIApplicationWillResignActiveNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.flush(force: true) }
        let generation = clearGeneration
        writeTask = Task {
            await sharedFileSink.markSessionStarted()
            await restorePersistedEntries(generation: generation)
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
        accept(coalescer.append(entry))
        if level == .error || level == .warning { flush(force: true) }
        else { scheduleFlush() }
    }

    func clear() {
        clearGeneration += 1
        flushTask?.cancel()
        flushTask = nil
        entries.removeAll()
        coalescer = AppLogCoalescer()
        pendingFileEntries.removeAll()
        needsPersistence = false
        let previous = writeTask
        writeTask = Task {
            await previous?.value
            await sharedFileSink.clear()
            await persistence.clear()
        }
    }

    private func restorePersistedEntries(generation: Int) async {
        guard generation == clearGeneration else { return }
        let persisted = await persistence.loadEntries()
        guard generation == clearGeneration else { return }
        let merged = mergeEntries(persisted, with: entries)
        let trimmed = trimToMaxEntries(merged)
        self.entries = trimmed
        if trimmed.count != persisted.count || trimmed != persisted {
            needsPersistence = true
            scheduleFlush()
        }
    }

    private func trimToMaxEntries(_ items: [AppLogEntry]) -> [AppLogEntry] {
        Array(items.suffix(maxEntries))
    }

    private func accept(_ batch: [AppLogEntry]) {
        guard !batch.isEmpty else { return }
        entries = trimToMaxEntries(entries + batch)
        pendingFileEntries.append(contentsOf: batch)
        needsPersistence = true
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            self.flush(force: false)
        }
    }

    private func flush(force: Bool) {
        flushTask?.cancel()
        flushTask = nil
        accept(coalescer.flush(at: Date(), force: force))
        let batch = pendingFileEntries
        pendingFileEntries.removeAll(keepingCapacity: true)
        if needsPersistence || !batch.isEmpty {
            needsPersistence = false
            let generation = clearGeneration
            // Serialise clear/save/append batches; an older snapshot must not win.
            let previous = writeTask
            writeTask = Task {
                await previous?.value
                guard generation == clearGeneration else { return }
                // Startup restoration belongs to the preceding write task.
                // Snapshot only after it finishes, so new logs cannot erase history.
                let snapshot = entries
                for entry in batch { await sharedFileSink.append(entry) }
                await persistence.saveEntries(snapshot)
            }
        }
        if coalescer.hasPendingSummary { scheduleFlush() }
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
        guard AppDiagnostics.shouldRecordDebug(category: category, message: message) else { return }
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
