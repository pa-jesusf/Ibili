import XCTest
@testable import Ibili

final class VideoLinkRequestTests: XCTestCase {
    func testNativeLinksInPlainTextKeepTheWholeQuery() throws {
        for source in ["bilibili://video/BV1fk4y1E7r3?p=2&t=12.5", "bilibili://video/42?p=2&t=12.5"] {
            let segments = MediaTextParser.parse(message: source)
            XCTAssertEqual(segments.count, 1)
            guard case .link(let label, let url) = segments.first else { return XCTFail("Native URL was split into bare identifiers") }
            XCTAssertEqual(label, source)
            let resolved = try VideoLinkRequest.resolve(shell(url), using: view())
            XCTAssertEqual(resolved.cid, 202)
            XCTAssertEqual(resolved.resumePositionMs, 12_500)
        }
    }

    func testWebPartLinkResolvesIdentityCIDDimensionAndTimeTogether() throws {
        let item = try shell("https://www.bilibili.com/video/BV1fk4y1E7r3?p=2&t=12.5&spm_id_from=tracking")
        XCTAssertEqual(item.cid, 0, "A URL hint must not be a trusted playback CID")
        XCTAssertEqual(item.linkSelection?.page, 2)
        let resolved = try VideoLinkRequest.resolve(item, using: view())
        XCTAssertEqual(resolved.aid, 42)
        XCTAssertEqual(resolved.bvid, "BV1fk4y1E7r3")
        XCTAssertEqual(resolved.cid, 202)
        XCTAssertEqual(resolved.durationSec, 240)
        XCTAssertEqual(resolved.dimension, VideoDimensionDTO(width: 1080, height: 1920))
        XCTAssertEqual(resolved.resumePositionMs, 12_500)
        XCTAssertEqual(resolved.ownerMID, 99)
        XCTAssertNil(resolved.linkSelection)
        let resume = PlayerResumePolicy.initialResumeMilliseconds(previous: nil, next: resolved,
                                                                 explicitMilliseconds: resolved.resumePositionMs,
                                                                 serverMilliseconds: 100_000, serverCid: 101)
        XCTAssertEqual(PlayerResumePolicy.targetSeconds(milliseconds: resume, duration: 240, isExplicit: true), 12.5)
    }

    func testNativeAVLinkUsesMillisecondsAndResolvesBVBeforePlayback() throws {
        let item = try shell("bilibili://video/42?cid=202&dm_progress=12345")
        XCTAssertEqual(item.linkSelection?.cid, 202)
        let resolved = try VideoLinkRequest.resolve(item, using: view())
        XCTAssertEqual(resolved.bvid, "BV1fk4y1E7r3")
        XCTAssertEqual(resolved.cid, 202)
        XCTAssertEqual(resolved.resumePositionMs, 12_345)
    }

    func testExplicitZeroAndProgressPrecedenceArePreserved() throws {
        let item = try shell("https://www.bilibili.com/video/BV1fk4y1E7r3?start_progress=0&dm_progress=20000&t=30")
        XCTAssertEqual(item.resumePositionMs, 0)
        XCTAssertEqual(try VideoLinkRequest.resolve(item, using: view()).cid, 101)
        XCTAssertNil(try shell("BV1fk4y1E7r3").resumePositionMs)
    }

    func testWrongVideoMissingPartAndMismatchedCIDNeverReachPlayurl() throws {
        for link in [
            "ibili://av/43", "ibili://bv/BV1Yq4D6PENU",
            "ibili://av/42?p=3", "ibili://av/42?cid=999",
            "ibili://av/42?p=1&cid=202"
        ] {
            let item = try shell(link)
            XCTAssertThrowsError(try VideoLinkRequest.resolve(item, using: view()), link)
        }
        XCTAssertEqual(try VideoLinkRequest.resolve(shell("ibili://av/42?p=2&cid=202"), using: view()).cid, 202)
    }

    func testInvalidIDsAndParametersDoNotBecomeInvalidAPIArguments() throws {
        for url in ["ibili://av/0", "ibili://av/-2", "ibili://av/999999999999999999999",
                    "ibili://bv/BVfake", "ibili://bv/BV1fk4y1E7r3/extra"] {
            XCTAssertNil(VideoLinkRequest.feedItem(from: URL(string: url)!))
        }
        for query in ["p=-1&cid=-1&t=-1", "p=999999999999999999999&cid=abc&t=inf", "t=1e100", "t=nan"] {
            let item = try shell("ibili://av/42?\(query)")
            XCTAssertNil(item.linkSelection?.page)
            XCTAssertNil(item.linkSelection?.cid)
            XCTAssertNil(item.resumePositionMs)
        }
    }

    func testPGCURLsKeepEpisodeIdentityAndTimeUnits() {
        XCTAssertEqual(LinkRouter.mapToInternalURL("https://www.bilibili.com/bangumi/play/ep42?t=12.5"),
                       "ibili://pgc/ep/42?start_progress=12500")
        XCTAssertEqual(LinkRouter.mapToInternalURL("bilibili://pgc/season/ep/42?dm_progress=12000"),
                       "ibili://pgc/ep/42?start_progress=12000")
        for unrelated in ["https://www.bilibili.com/video/cv42", "https://www.bilibili.com/read/BV1fk4y1E7r3",
                          "https://example.com/video/BV1fk4y1E7r3?p=2&t=10"] {
            XCTAssertEqual(LinkRouter.mapToInternalURL(unrelated), unrelated)
        }
    }

    func testOldFeedDecodingAndLinkRoundTripRemainCompatible() throws {
        let old = try JSONDecoder().decode(FeedItemDTO.self, from: Data(#"{"aid":42,"cid":101}"#.utf8))
        XCTAssertNil(old.linkSelection)
        let linked = try shell("ibili://av/42?p=2&t=1")
        XCTAssertEqual(try JSONDecoder().decode(FeedItemDTO.self, from: JSONEncoder().encode(linked)), linked)
    }

    private func shell(_ text: String) throws -> FeedItemDTO {
        let mapped = try XCTUnwrap(URL(string: LinkRouter.mapToInternalURL(text)))
        return try XCTUnwrap(VideoLinkRequest.feedItem(from: mapped))
    }

    private func view() -> VideoViewDTO {
        VideoViewDTO(aid: 42, bvid: "BV1fk4y1E7r3", cid: 101, title: "Video", cover: "cover", desc: "", descV2: [],
                     durationSec: 360, pubdate: 1, ctime: 1, videos: 2,
                     stat: VideoStatDTO(view: 1, danmaku: 2, reply: 3, favorite: 4, coin: 5, share: 6, like: 7),
                     owner: VideoOwnerDTO(mid: 99, name: "Author", face: ""),
                     pages: [
                        VideoPageDTO(cid: 101, page: 1, part: "P1", durationSec: 120, firstFrame: "", dimension: VideoDimensionDTO(width: 1920, height: 1080)),
                        VideoPageDTO(cid: 202, page: 2, part: "P2", durationSec: 240, firstFrame: "", dimension: VideoDimensionDTO(width: 1080, height: 1920))
                     ], tags: [], honor: [], ugcSeason: nil, redirectUrl: "")
    }
}
