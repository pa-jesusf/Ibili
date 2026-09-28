import XCTest
@testable import Ibili

final class PlayerHeartbeatSessionTests: XCTestCase {
    @MainActor
    func testSwitchUsesOutgoingIdentityAndPlayhead() async {
        var reports: [PlayerHeartbeat] = []
        var oldPosition = 170.8
        var newPosition = 0.0
        let outgoing = PlayerHeartbeatSession(
            aid: 740_322_052, bvid: "BV1fk4y1E7r3", cid: 1_105_114_066,
            currentPosition: { oldPosition }, send: { reports.append($0) }
        )
        let incoming = PlayerHeartbeatSession(
            aid: 116_709_461_592_046, bvid: "BV1ebEh6bEU3", cid: 38_938_478_479,
            currentPosition: { newPosition }, send: { reports.append($0) }
        )

        // Even if the route already selected B, A's final sample still belongs to A.
        outgoing.finish()
        oldPosition = 180
        outgoing.report(seconds: oldPosition) // Queued callback from the removed observer.
        outgoing.finish()                     // Repeated teardown must be harmless.
        incoming.report(seconds: newPosition)
        newPosition = 12.4
        incoming.finish()

        XCTAssertEqual(reports, [
            PlayerHeartbeat(aid: 740_322_052, bvid: "BV1fk4y1E7r3", cid: 1_105_114_066, playedSeconds: 170),
            PlayerHeartbeat(aid: 116_709_461_592_046, bvid: "BV1ebEh6bEU3", cid: 38_938_478_479, playedSeconds: 0),
            PlayerHeartbeat(aid: 116_709_461_592_046, bvid: "BV1ebEh6bEU3", cid: 38_938_478_479, playedSeconds: 12),
        ])
    }

    @MainActor
    func testInvalidTimesAndRepeatedSecondsAreNotReported() async {
        var reports: [PlayerHeartbeat] = []
        let session = PlayerHeartbeatSession(
            aid: 42, bvid: "BV42", cid: 100,
            currentPosition: { .nan }, send: { reports.append($0) }
        )
        for seconds in [Double.nan, .infinity, -.infinity, -1, Double(Int64.max), 0, 0.9, 15, 15.9] {
            session.report(seconds: seconds)
        }
        session.finish()
        session.report(seconds: 30)
        XCTAssertEqual(reports.map(\.playedSeconds), [0, 15])
    }

    @MainActor
    func testDetachedItemCannotProduceTerminalProgress() async {
        var reports: [PlayerHeartbeat] = []
        let session = PlayerHeartbeatSession(
            aid: 42, bvid: "BV42", cid: 100,
            currentPosition: { nil }, send: { reports.append($0) }
        )
        session.finish()
        XCTAssertTrue(reports.isEmpty)
    }

    @MainActor
    func testSameVideoDifferentPartsKeepTheirOwnCid() async {
        var reports: [PlayerHeartbeat] = []
        let first = PlayerHeartbeatSession(aid: 42, bvid: "BV42", cid: 100,
            currentPosition: { 92 }, send: { reports.append($0) })
        let second = PlayerHeartbeatSession(aid: 42, bvid: "BV42", cid: 101,
            currentPosition: { 3 }, send: { reports.append($0) })
        first.finish()
        second.finish()
        XCTAssertEqual(reports.map(\.cid), [100, 101])
        XCTAssertEqual(reports.map(\.playedSeconds), [92, 3])
    }
}
