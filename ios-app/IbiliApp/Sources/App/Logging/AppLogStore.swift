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

@MainActor
final class AppLogStore: ObservableObject {
    static let shared = AppLogStore()

    @Published private(set) var entries: [AppLogEntry] = []

    private let persistence = AppLogPersistence()
    private let maxEntries = 1_000

    private init() {
        Task {
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
        Task {
            await persistence.saveEntries(snapshot)
        }
    }

    func clear() {
        entries.removeAll()
        Task {
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