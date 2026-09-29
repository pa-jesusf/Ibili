import Foundation

/// Retains the incoming COW array so repeated SwiftUI updates can skip all rows.
/// A supplied revision must change for every item/order change, not UI chrome.
struct CollectionItemState<Item: Identifiable & Hashable> {
    private var source: [Item] = []
    private var version: AnyHashable?
    private var initialized = false
    private(set) var revision: UInt64 = 0
    private(set) var orderedIDs: [Item.ID] = []
    private(set) var itemByID: [Item.ID: Item] = [:]

    mutating func update(_ incoming: @autoclosure () -> [Item], version: AnyHashable? = nil) -> (structure: Bool, changed: [Item.ID]) {
        if initialized, version != nil, version == self.version { return (false, []) }
        let items = incoming()
        let sameStorage = source.withUnsafeBufferPointer { old in
            items.withUnsafeBufferPointer { new in old.count == new.count && old.baseAddress == new.baseAddress }
        }
        if initialized, sameStorage { self.version = version; return (false, []) }
        self.version = version
        source = items
        var next: [Item.ID: Item] = [:]
        var ids: [Item.ID] = []
        var changed: [Item.ID] = []
        ids.reserveCapacity(items.count)
        for item in items where next[item.id] == nil {
            ids.append(item.id)
            next[item.id] = item
            if itemByID[item.id] != item { changed.append(item.id) }
        }
        let structure = !initialized || orderedIDs != ids
        initialized = true
        orderedIDs = ids
        itemByID = next
        if structure || !changed.isEmpty { revision &+= 1 }
        return (structure, changed)
    }
}
