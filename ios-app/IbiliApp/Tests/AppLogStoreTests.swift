import XCTest
@testable import Ibili

final class AppLogStoreTests: XCTestCase {
    @MainActor
    func testErrorDuringStartupNeverOverwritesRestoredHistory() async {
        let gate = LogStartupGate()
        let saved = expectation(description: "first durable snapshot includes history")
        let old = AppLogEntry(level: .error, category: "app", message: "old")
        let storage = ControlledLogStorage(entries: [old], saved: saved)
        let sink = ControlledLogSink(gate: gate)
        let store = AppLogStore(persistence: storage, sharedFileSink: sink)
        await gate.waitUntilEntered()
        store.log(level: .error, category: "app", message: "new")
        await gate.release()
        await fulfillment(of: [saved], timeout: 2)
        let firstSnapshot = await storage.firstSnapshot
        XCTAssertEqual(firstSnapshot?.map(\.message), ["old", "new"])
        XCTAssertEqual(store.entries.map(\.message), ["old", "new"])
    }

    @MainActor
    func testClearDuringSessionStartupCannotRestoreOldLogs() async {
        let gate = LogStartupGate()
        let saved = expectation(description: "post-clear snapshot saved")
        let old = AppLogEntry(level: .info, category: "app", message: "old")
        let storage = ControlledLogStorage(entries: [old], saved: saved)
        let sink = ControlledLogSink(gate: gate)
        let store = AppLogStore(persistence: storage, sharedFileSink: sink)
        await gate.waitUntilEntered()
        store.clear()
        store.log(level: .error, category: "app", message: "new")
        await gate.release()
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(store.entries.map(\.message), ["new"])
        let persisted = await storage.loadEntries()
        let exported = await sink.messages
        XCTAssertEqual(persisted.map(\.message), ["new"])
        XCTAssertEqual(exported, ["new"])
    }

    @MainActor
    func testStormIsCoalescedForUIAndBothPersistenceDestinations() async {
        let saved = expectation(description: "single batched snapshot")
        let storage = ControlledLogStorage(entries: [], saved: saved)
        let sink = ControlledLogSink()
        let store = AppLogStore(persistence: storage, sharedFileSink: sink)
        for _ in 0..<1000 {
            store.log(level: .debug, category: "player", message: "layout", metadata: ["sessionID": "A"])
        }
        XCTAssertEqual(store.entries.count, 1)
        // Warnings force a durable batch and flush the last repeat summary.
        store.log(level: .warning, category: "player", message: "buffer failed")
        await fulfillment(of: [saved], timeout: 2)
        let persisted = await storage.loadEntries()
        let exported = await sink.messages
        let writes = await storage.saveCount
        XCTAssertEqual(persisted.count, 3)
        XCTAssertEqual(exported.count, 3)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(persisted.first { $0.metadata["suppressedCount"] != nil }?.metadata["suppressedCount"], "999")
        XCTAssertTrue(persisted.contains { $0.message == "buffer failed" })
    }
}

private actor LogStartupGate {
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ControlledLogStorage: AppLogPersistenceStore {
    private var entries: [AppLogEntry]
    private let saved: XCTestExpectation
    private(set) var saveCount = 0
    private(set) var firstSnapshot: [AppLogEntry]?

    init(entries: [AppLogEntry], saved: XCTestExpectation) {
        self.entries = entries
        self.saved = saved
    }
    func loadEntries() -> [AppLogEntry] { entries }
    func saveEntries(_ entries: [AppLogEntry]) {
        self.entries = entries
        if firstSnapshot == nil { firstSnapshot = entries }
        saveCount += 1
        saved.fulfill()
    }
    func clear() { entries.removeAll() }
}

private actor ControlledLogSink: AppLogFileSink {
    let gate: LogStartupGate?
    private(set) var messages: [String] = []
    init(gate: LogStartupGate? = nil) { self.gate = gate }
    func markSessionStarted() async { await gate?.pause() }
    func append(_ entry: AppLogEntry) { messages.append(entry.message) }
    func clear() { messages.removeAll() }
}
