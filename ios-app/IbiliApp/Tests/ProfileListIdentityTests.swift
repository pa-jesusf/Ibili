import XCTest
@testable import Ibili

final class ProfileListIdentityTests: XCTestCase {
    func testFavoriteResourceIdentityIncludesPart() {
        let first = FavResourceItemDTO(
            aid: 42,
            bvid: "BV42",
            cid: 1001,
            title: "P1",
            cover: "",
            author: "author",
            durationSec: 60,
            play: 0,
            danmaku: 0,
            pubdate: 0
        )
        let second = FavResourceItemDTO(
            aid: 42,
            bvid: "BV42",
            cid: 1002,
            title: "P2",
            cover: "",
            author: "author",
            durationSec: 60,
            play: 0,
            danmaku: 0,
            pubdate: 0
        )

        XCTAssertNotEqual(first.id, second.id)
    }
}
