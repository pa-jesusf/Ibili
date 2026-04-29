import Foundation
import SwiftUI

/// MRU-ordered, capped, persisted search history. Backed by
/// `@AppStorage` storing a JSON-encoded `[String]` so we don't need a
/// real persistence stack for a list of strings.
@MainActor
final class SearchHistoryStore: ObservableObject {
    /// Maximum number of distinct queries to remember. Beyond this we
    /// drop the oldest entry on every new push.
    static let capacity: Int = 30

    @Published private(set) var entries: [String]

    private static let storageKey = "ibili.search.history.v1"

    init() {
        self.entries = Self.load()
    }

    /// Push `query` to the front of the history. Empty / whitespace-only
    /// queries are ignored. Existing duplicates are removed first so the
    /// new entry takes the most-recent slot.
    func push(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = entries.filter { $0 != trimmed }
        next.insert(trimmed, at: 0)
        if next.count > Self.capacity {
            next = Array(next.prefix(Self.capacity))
        }
        entries = next
        save()
    }

    /// Remove a single entry (e.g. the user tapped its delete affordance).
    func remove(_ query: String) {
        let next = entries.filter { $0 != query }
        guard next.count != entries.count else { return }
        entries = next
        save()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        save()
    }

    // MARK: - Persistence

    private static func load() -> [String] {
        guard
            let raw = UserDefaults.standard.string(forKey: storageKey),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private func save() {
        let data = (try? JSONEncoder().encode(entries)) ?? Data()
        let raw = String(data: data, encoding: .utf8) ?? "[]"
        UserDefaults.standard.set(raw, forKey: Self.storageKey)
    }
}
