import XCTest
@testable import Ibili

final class MediaTextParserTests: XCTestCase {
    func testTimecodesSupportFullWidthHoursAndRejectMalformedOrOverflow() {
        XCTAssertEqual(PlaybackTimecode.seconds("01:23"), 83)
        XCTAssertEqual(PlaybackTimecode.seconds("1：02：03"), 3723)
        XCTAssertEqual(PlaybackTimecode.seconds("123:45"), 7425)
        XCTAssertEqual(PlaybackTimecode.seconds("0:00"), 0)
        for text in ["1:60", "1:61:01", "-1:00", "1::2", "1:2:3:4", "999999999999999999999999:00"] {
            XCTAssertNil(PlaybackTimecode.seconds(text), text)
        }
        XCTAssertFalse(PlaybackTimecode.isValid(80, duration: 79))
        XCTAssertFalse(PlaybackTimecode.isValid(0, duration: .nan))
        XCTAssertFalse(PlaybackTimecode.isValid(0, duration: .infinity))
        XCTAssertFalse(PlaybackTimecode.isValid(0, duration: 0))
        XCTAssertEqual(PlaybackTimecode.firstValid(in: "空降 01：23", duration: 100), 83)
        XCTAssertNil(PlaybackTimecode.firstValid(in: "错误 01:99", duration: 100))
        XCTAssertEqual(MediaTextParser.parse(message: "1:99:00"), [.text("1:99:00")])
        XCTAssertEqual(MediaTextParser.parse(message: "-1:00"), [.text("-1:00")])
    }

    func testParserKeepsEmotesMentionsAndURLsAheadOfTimestampDetection() {
        let emote = ReplyEmoteDTO(name: "[1:23]", url: "image", size: 1)
        let mention = ReplyJumpUrlDTO(keyword: "@1:23", title: "@1:23", url: "ibili://space/42", prefixIcon: "")
        let result = MediaTextParser.parse(message: "[1:23] @1:23 https://example.com/1:23 01：23", emotes: [emote], jumps: [mention])
        XCTAssertEqual(result, [.emote("[1:23]"), .text(" "), .link(label: "@1:23", url: "ibili://space/42"), .text(" "),
                                .link(label: "https://example.com/1:23", url: "https://example.com/1:23"), .text(" "), .time(label: "01：23", seconds: 83)])
    }

    func testLinksExcludeTrailingPunctuationAndKeepTopicSearch() {
        let result = MediaTextParser.parse(message: "看 https://www.bilibili.com/video/BV1fk4y1E7r3，和 #测试话题#。")
        XCTAssertEqual(result[1], .link(label: "https://www.bilibili.com/video/BV1fk4y1E7r3", url: "ibili://bv/BV1fk4y1E7r3"))
        XCTAssertEqual(result[2], .text("，和 "))
        XCTAssertEqual(result[3], .link(label: "#测试话题#", url: LinkRouter.searchURL(keyword: "测试话题")))
        XCTAssertEqual(MediaTextParser.parse(message: "https://example.com/a)."), [
            .link(label: "https://example.com/a", url: "https://example.com/a"), .text(").")
        ])
    }

    func testNativeAndWebLinksRouteToSameDestinationWithoutStealingExternalURLs() {
        let pairs = [
            ("bv1fk4y1E7r3", "ibili://bv/BV1fk4y1E7r3"),
            ("bilibili://video/42", "ibili://av/42"),
            ("bilibili://video/BV1fk4y1E7r3", "ibili://bv/BV1fk4y1E7r3"),
            ("bilibili://space/42", "ibili://space/42"),
            ("https://space.bilibili.com/42", "ibili://space/42"),
            ("https://www.bilibili.com/read/cv123", "ibili://article/read/123"),
            ("https://www.bilibili.com/opus/123", "ibili://article/opus/123"),
            ("https://t.bilibili.com/123", "ibili://article/opus/123"),
            ("https://www.bilibili.com/bangumi/play/ep42", "ibili://pgc/ep/42"),
            ("bilibili://pgc/play/ss42", "ibili://pgc/ss/42"),
            ("bilibili://pgc/season/ep/123456", "ibili://pgc/ep/123456"),
            ("bilibili://pgc/season/123456", "ibili://pgc/ss/123456"),
            ("bilibili://bangumi/season/123456", "ibili://pgc/ss/123456"),
            ("https://live.bilibili.com/42", "ibili://live/42")
        ]
        for (input, output) in pairs { XCTAssertEqual(LinkRouter.mapToInternalURL(input), output, input) }
        for external in ["https://example.com/BV1fk4y1E7r3", "https://search.bilibili.com.evil.test/?keyword=x"] {
            XCTAssertEqual(LinkRouter.mapToInternalURL(external), external)
        }
    }

    func testPlaybackContextCannotSeekAnotherSessionOrPart() throws {
        var selected: [Int64] = []
        let context = PlaybackTextContext(identity: "session-A-cid-1", duration: 100, seek: { selected.append($0) })
        XCTAssertNil(context.url(seconds: 101))
        let url = try XCTUnwrap(context.url(seconds: 83))
        XCTAssertTrue(context.handle(url))
        XCTAssertEqual(selected, [83])
        let other = PlaybackTextContext(identity: "session-B-cid-2", duration: 100, seek: { _ in XCTFail("stale target") })
        XCTAssertTrue(other.handle(url))
        XCTAssertFalse(context.handle(URL(string: "https://example.com")!))
    }

}
