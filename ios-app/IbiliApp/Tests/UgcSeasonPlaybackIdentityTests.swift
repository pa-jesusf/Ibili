import Foundation
import XCTest
@testable import Ibili

final class UgcSeasonPlaybackIdentityTests: XCTestCase {
    func testMultiPageVideoMatchesSeasonEntryByAidWhenActiveCidIsNotP1() throws {
        let season = try makeSeason()
        let identity = UgcSeasonPlaybackIdentity(
            aid: 117_182_293_875_338,
            bvid: "BV1Yq4D6PENU",
            cid: 41_416_526_587
        )

        let episode = try XCTUnwrap(season.episode(matching: identity))
        XCTAssertEqual(episode.bvid, "BV1Yq4D6PENU")
        XCTAssertEqual(episode.cid, 41_416_199_288)
    }

    func testNextEpisodeUsesVideoIdentityInsteadOfPageCid() throws {
        let season = try makeSeason()
        let identity = UgcSeasonPlaybackIdentity(
            aid: 117_172_580_063_443,
            bvid: "BV1CztA6HENd",
            cid: 99_999
        )

        XCTAssertEqual(
            season.nextEpisode(after: identity)?.bvid,
            "BV1Yq4D6PENU"
        )
    }

    func testCidRemainsFallbackForIncompleteVideoIdentity() throws {
        let season = try makeSeason()
        let identity = UgcSeasonPlaybackIdentity(
            aid: 0,
            bvid: "",
            cid: 41_362_067_080
        )

        XCTAssertEqual(
            season.episode(matching: identity)?.bvid,
            "BV1CztA6HENd"
        )
    }

    private func makeSeason() throws -> UgcSeasonDTO {
        let json = #"""
        {
          "id": 8928853,
          "title": "无职转生",
          "cover": "",
          "mid": 1,
          "intro": "",
          "ep_count": 2,
          "sections": [
            {
              "id": 9959207,
              "title": "正片",
              "episodes": [
                {
                  "id": 219295368,
                  "aid": 117172580063443,
                  "bvid": "BV1CztA6HENd",
                  "cid": 41362067080,
                  "title": "第10话预告",
                  "cover": "",
                  "duration_sec": 90
                },
                {
                  "id": 219587988,
                  "aid": 117182293875338,
                  "bvid": "BV1Yq4D6PENU",
                  "cid": 41416199288,
                  "title": "全14集",
                  "cover": "",
                  "duration_sec": 1773
                }
              ]
            }
          ]
        }
        """#
        return try JSONDecoder().decode(UgcSeasonDTO.self, from: Data(json.utf8))
    }
}
