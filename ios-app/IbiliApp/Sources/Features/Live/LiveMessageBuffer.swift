import Foundation

/// Fixed-capacity ring; eviction also removes the ID from the deduplication set.
struct LiveMessageBuffer {
    private var storage: [LiveDanmakuMessageDTO?]
    private var ids = Set<String>()
    private var head = 0
    private var count = 0
    init(capacity: Int = 1000) { storage = Array(repeating: nil, count: max(1, capacity)) }

    var messages: [LiveDanmakuMessageDTO] {
        (0..<count).compactMap { storage[(head + $0) % storage.count] }
    }

    @discardableResult
    mutating func append(_ incoming: [LiveDanmakuMessageDTO]) -> Bool {
        var changed = false
        for message in incoming where !message.text.isEmpty && ids.insert(message.id).inserted {
            if count == storage.count {
                if let old = storage[head] { ids.remove(old.id) }
                storage[head] = message
                head = (head + 1) % storage.count
            } else {
                storage[(head + count) % storage.count] = message
                count += 1
            }
            changed = true
        }
        return changed
    }

    mutating func prependHistory(_ history: [LiveDanmakuMessageDTO]) {
        let live = messages
        var seen = Set<String>()
        let merged = (history + live).filter { !$0.text.isEmpty && seen.insert($0.id).inserted }
        self = LiveMessageBuffer(capacity: storage.count)
        append(Array(merged.suffix(storage.count)))
    }
}
