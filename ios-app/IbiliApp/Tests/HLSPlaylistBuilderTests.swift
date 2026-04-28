import XCTest
@testable import Ibili

final class HLSPlaylistBuilderTests: XCTestCase {

    // MARK: - Master

    func testMasterWithSeparateAudioEmitsAudioMediaAndStreamInfWithGroup() {
        let master = HLSPlaylistBuilder.makeMaster(
            videoBandwidthHint: 4_500_000,
            hasSeparateAudio: true,
            videoMediaPath: "video.m3u8",
            audioMediaPath: "audio.m3u8"
        )
        XCTAssertTrue(master.hasPrefix("#EXTM3U\n"))
        XCTAssertTrue(master.contains("#EXT-X-VERSION:7"))
        XCTAssertTrue(master.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        XCTAssertTrue(master.contains(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud""#))
        XCTAssertTrue(master.contains(#"URI="audio.m3u8""#))
        XCTAssertTrue(master.contains(#"#EXT-X-STREAM-INF:BANDWIDTH=4500000,AUDIO="aud""#))
        XCTAssertTrue(master.contains("\nvideo.m3u8\n"))
    }

    func testMasterWithoutSeparateAudioOmitsAudioGroup() {
        let master = HLSPlaylistBuilder.makeMaster(
            videoBandwidthHint: nil,
            hasSeparateAudio: false,
            videoMediaPath: "video.m3u8",
            audioMediaPath: nil
        )
        XCTAssertFalse(master.contains("#EXT-X-MEDIA:"))
        XCTAssertFalse(master.contains(#"AUDIO="aud""#))
        XCTAssertTrue(master.contains("#EXT-X-STREAM-INF:BANDWIDTH="))
    }

    // MARK: - Media

    func testMediaPlaylistEmitsMapAndOneLinePerFragment() {
        let probe = ISOBMFF.Probe(
            initSegment: ISOBMFF.InitSegment(offset: 0, length: 1234),
            index: ISOBMFF.SegmentIndex(timescale: 1000, entries: [
                ISOBMFF.SegmentIndexEntry(offset: 1234, length: 50_000, durationTicks: 4_000),
                ISOBMFF.SegmentIndexEntry(offset: 51_234, length: 60_000, durationTicks: 5_500),
            ])
        )
        let media = HLSPlaylistBuilder.makeMedia(probe: probe, segmentPath: "v.seg")

        XCTAssertTrue(media.contains(#"#EXT-X-MAP:URI="v.seg",BYTERANGE="1234@0""#))
        // Target duration must be ceil(max fragment) = ceil(5.5) = 6.
        XCTAssertTrue(media.contains("#EXT-X-TARGETDURATION:6"))
        XCTAssertTrue(media.contains("#EXTINF:4.000000,"))
        XCTAssertTrue(media.contains("#EXT-X-BYTERANGE:50000@1234"))
        XCTAssertTrue(media.contains("#EXTINF:5.500000,"))
        XCTAssertTrue(media.contains("#EXT-X-BYTERANGE:60000@51234"))
        XCTAssertTrue(media.hasSuffix("#EXT-X-ENDLIST\n"))

        // Each fragment line should appear exactly twice in the output:
        // once as the EXT-X-BYTERANGE marker and once as the media URI.
        let occurrences = media.components(separatedBy: "\nv.seg\n").count - 1
        XCTAssertEqual(occurrences, 2)
    }
}
