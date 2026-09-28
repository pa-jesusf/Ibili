import XCTest
@testable import Ibili

final class PlayerResumePolicyTests: XCTestCase {
    private func item(
        aid: Int64 = 42,
        bvid: String = "BV42",
        cid: Int64,
        resumePositionMs: Int64? = nil
    ) -> FeedItemDTO {
        FeedItemDTO(
            aid: aid,
            bvid: bvid,
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

    func testUgcSeasonSwitchResetsUnknownAccountProgress() {
        let previous = item(aid: 740_322_052, bvid: "BV1fk4y1E7r3", cid: 1_105_114_066)
        let next = item(aid: 116_709_461_592_046, bvid: "BV1ebEh6bEU3", cid: 38_938_478_479)

        XCTAssertTrue(PlayerResumePolicy.isMediaReplacement(from: previous, to: next))
        XCTAssertEqual(
            PlayerResumePolicy.initialResumeMilliseconds(
                previous: previous,
                next: next,
                explicitMilliseconds: nil,
                serverMilliseconds: 621_000,
                serverCid: 0
            ),
            0
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
