import XCTest
@testable import Ibili

final class PlayerResumePolicyTests: XCTestCase {
    private func item(cid: Int64, resumePositionMs: Int64? = nil) -> FeedItemDTO {
        FeedItemDTO(
            aid: 42,
            bvid: "BV42",
            cid: cid,
            title: "video",
            cover: "",
            author: "author",
            durationSec: 600,
            play: 0,
            danmaku: 0,
            resumePositionMs: resumePositionMs
        )
    }

    func testPartSwitchIgnoresUnknownAidLevelProgress() {
        XCTAssertTrue(PlayerResumePolicy.isPartSwitch(from: item(cid: 1), to: item(cid: 2)))
        XCTAssertEqual(
            PlayerResumePolicy.initialResumeMilliseconds(
                previous: item(cid: 1),
                next: item(cid: 2),
                explicitMilliseconds: nil,
                serverMilliseconds: 621_000,
                serverCid: 0
            ),
            0
        )
    }

    func testPartSwitchKeepsProgressOnlyWhenServerIdentifiesTargetCid() {
        XCTAssertEqual(
            PlayerResumePolicy.initialResumeMilliseconds(
                previous: item(cid: 1),
                next: item(cid: 2),
                explicitMilliseconds: nil,
                serverMilliseconds: 37_000,
                serverCid: 2
            ),
            37_000
        )
    }

    func testExplicitHistoryPositionOverridesServerProgress() {
        XCTAssertEqual(
            PlayerResumePolicy.initialResumeMilliseconds(
                previous: nil,
                next: item(cid: 2, resumePositionMs: 12_000),
                explicitMilliseconds: 12_000,
                serverMilliseconds: 621_000,
                serverCid: 0
            ),
            12_000
        )
    }
}
