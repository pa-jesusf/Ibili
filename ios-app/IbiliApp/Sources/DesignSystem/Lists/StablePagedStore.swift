import Foundation

/// Small, deterministic page store for infinite feeds.
///
/// The store deliberately does not sort or replace existing rows on append:
/// commercial feeds keep visible rows stable while pagination lands, otherwise
/// duplicate IDs or server-side re-ranking can make cells jump.
@MainActor
final class StablePagedStore<ItemID: Hashable, Item> {
    private let identity: (Item) -> ItemID?

    private(set) var items: [Item] = []
    private(set) var generation: UInt64 = 0
    private(set) var isLoading = false
    private(set) var isEnd = false

    private var loadedIDs = Set<ItemID>()

    init(identity: @escaping (Item) -> ItemID?) {
        self.identity = identity
    }

    @discardableResult
    func reset(preservingItems: Bool = false) -> UInt64 {
        generation &+= 1
        if !preservingItems {
            items.removeAll(keepingCapacity: true)
            loadedIDs.removeAll(keepingCapacity: true)
        }
        isLoading = false
        isEnd = false
        return generation
    }

    func beginLoading() {
        isLoading = true
    }

    func finishLoading(generation expectedGeneration: UInt64) {
        guard accepts(generation: expectedGeneration) else { return }
        isLoading = false
    }

    func markEnd(_ value: Bool, generation expectedGeneration: UInt64) {
        guard accepts(generation: expectedGeneration) else { return }
        isEnd = value
    }

    func accepts(generation expectedGeneration: UInt64) -> Bool {
        expectedGeneration == generation
    }

    @discardableResult
    func replace(with incoming: [Item], generation expectedGeneration: UInt64) -> [Item] {
        guard accepts(generation: expectedGeneration) else { return [] }
        items.removeAll(keepingCapacity: true)
        loadedIDs.removeAll(keepingCapacity: true)
        let fresh = uniqueItems(from: incoming)
        items = fresh
        return fresh
    }

    @discardableResult
    func append(_ incoming: [Item], generation expectedGeneration: UInt64) -> [Item] {
        guard accepts(generation: expectedGeneration) else { return [] }
        let fresh = uniqueItems(from: incoming)
        guard !fresh.isEmpty else { return [] }
        items.append(contentsOf: fresh)
        return fresh
    }

    func remove(where shouldRemove: (Item) -> Bool) {
        let removedIDs = items.compactMap { item -> ItemID? in
            shouldRemove(item) ? identity(item) : nil
        }
        guard !removedIDs.isEmpty else { return }
        items.removeAll(where: shouldRemove)
        for id in removedIDs {
            loadedIDs.remove(id)
        }
    }

    private func uniqueItems(from incoming: [Item]) -> [Item] {
        var fresh: [Item] = []
        fresh.reserveCapacity(incoming.count)
        for item in incoming {
            guard let id = identity(item) else { continue }
            guard loadedIDs.insert(id).inserted else { continue }
            fresh.append(item)
        }
        return fresh
    }
}
