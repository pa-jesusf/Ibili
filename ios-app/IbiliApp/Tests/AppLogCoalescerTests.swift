import XCTest
@testable import Ibili

final class AppLogCoalescerTests: XCTestCase {
    func testInterleavedStormPreservesFirstSamplesAndCountsForAllDestinations() {
        var coalescer = AppLogCoalescer()
        let start = Date(timeIntervalSince1970: 10)
        var output: [AppLogEntry] = []
        for index in 0..<1000 {
            for name in ["layout", "hit-test"] {
                output += coalescer.append(AppLogEntry(timestamp: start.addingTimeInterval(Double(index) / 1000),
                    level: .debug, category: "player", message: name,
                    metadata: ["sessionID": "A", "point": String(index)]))
            }
        }
        XCTAssertEqual(output.count, 2)
        let summaries = coalescer.flush(at: start.addingTimeInterval(2))
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.map { $0.metadata["suppressedCount"] }, ["999", "999"])
        XCTAssertFalse(coalescer.hasPendingSummary)
    }

    func testErrorsStateChangesAndDifferentUserActionsAreNeverCollapsed() {
        var coalescer = AppLogCoalescer()
        let date = Date()
        for level in [AppLogLevel.error, .warning, .info] {
            for _ in 0..<10 {
                XCTAssertEqual(coalescer.append(AppLogEntry(timestamp: date, level: level, category: "player", message: "failed")).count, 1)
            }
        }
        for metadata in [["sessionID": "A"], ["sessionID": "B"], ["sessionID": "A", "traceID": "1"],
                         ["sessionID": "A", "traceID": "2"], ["sessionID": "A", "status": "paused"]] {
            XCTAssertEqual(coalescer.append(AppLogEntry(timestamp: date, level: .debug, category: "player", message: "state", metadata: metadata)).count, 1)
        }
    }

    func testContinuousRepeatsFlushAtFixedWindowAndForceFlushDrainsLastSummary() {
        var coalescer = AppLogCoalescer()
        let start = Date(timeIntervalSince1970: 10)
        func entry(_ seconds: Double) -> AppLogEntry {
            .init(timestamp: start.addingTimeInterval(seconds), level: .debug, category: "navigation", message: "same")
        }
        XCTAssertEqual(coalescer.append(entry(0)).count, 1)
        XCTAssertTrue(coalescer.append(entry(1.9)).isEmpty)
        let next = coalescer.append(entry(2.1))
        XCTAssertEqual(next.count, 2)
        XCTAssertEqual(next[0].metadata["suppressedCount"], "1")
        XCTAssertTrue(coalescer.append(entry(2.2)).isEmpty)
        XCTAssertEqual(coalescer.flush(at: start.addingTimeInterval(2.3), force: true).count, 1)
        XCTAssertTrue(coalescer.flush(at: start.addingTimeInterval(3), force: true).isEmpty)
    }

    func testStateRoundTripPreservesRecoveryAndSummarizesOnlyConsecutiveSamples() {
        var coalescer = AppLogCoalescer()
        let start = Date(timeIntervalSince1970: 10)
        let states = ["playing", "playing", "paused", "paused", "playing"]
        var result: [AppLogEntry] = []
        for (index, state) in states.enumerated() {
            result += coalescer.append(.init(timestamp: start.addingTimeInterval(Double(index) / 10),
                level: .debug, category: "player", message: "播放器会话事件已应用",
                metadata: ["sessionID": "A", "event": "playbackIntentChanged(\(state))"]))
        }
        let transitions = result.filter { $0.metadata["suppressedCount"] == nil }
        XCTAssertEqual(transitions.map { $0.metadata["event"] }, [
            "playbackIntentChanged(playing)", "playbackIntentChanged(paused)", "playbackIntentChanged(playing)"
        ])
        XCTAssertEqual(result.filter { $0.metadata["suppressedCount"] == "1" }.count, 2)
    }
}
