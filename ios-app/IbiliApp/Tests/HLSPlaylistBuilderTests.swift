import XCTest
@testable import Ibili

final class HLSPlaylistBuilderTests: XCTestCase {

    private let videoProbe = ISOBMFF.Probe(
        initSegment: ISOBMFF.InitSegment(offset: 0, length: 1024),
        index: ISOBMFF.SegmentIndex(timescale: 1000, entries: [
            ISOBMFF.SegmentIndexEntry(offset: 1024, length: 2_000_000, durationTicks: 4_000),
        ]),
        videoMetadata: nil
    )

    private let audioProbe = ISOBMFF.Probe(
        initSegment: ISOBMFF.InitSegment(offset: 0, length: 512),
        index: ISOBMFF.SegmentIndex(timescale: 1000, entries: [
            ISOBMFF.SegmentIndexEntry(offset: 512, length: 96_000, durationTicks: 4_000),
        ]),
        videoMetadata: nil
    )

    // MARK: - Master

    func testMasterWithSeparateAudioEmitsAudioMediaAndStreamInfWithGroup() {
        let master = HLSPlaylistBuilder.makeMaster(
            videoBandwidthHint: 4_500_000,
            videoProbe: videoProbe,
            audioProbe: audioProbe,
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
            videoProbe: videoProbe,
            audioProbe: nil,
            videoMediaPath: "video.m3u8",
            audioMediaPath: nil
        )
        XCTAssertFalse(master.contains("#EXT-X-MEDIA:"))
        XCTAssertFalse(master.contains(#"AUDIO="aud""#))
        XCTAssertTrue(master.contains("#EXT-X-STREAM-INF:BANDWIDTH="))
    }

    func testMasterWithCodecsEmitsCodecsOnStreamInf() {
        let master = HLSPlaylistBuilder.makeMaster(
            videoBandwidthHint: 6_000_000,
            videoProbe: videoProbe,
            audioProbe: audioProbe,
            videoMediaPath: "video.m3u8",
            audioMediaPath: "audio.m3u8",
            videoCodec: "avc1.640032",
            audioCodec: "mp4a.40.2"
        )
        XCTAssertTrue(master.contains(#"CODECS="avc1.640032,mp4a.40.2""#),
                      "EXT-X-STREAM-INF must combine video+audio codecs")
        XCTAssertTrue(master.contains(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud""#))
        XCTAssertFalse(master.contains("VIDEO-RANGE="),
                       "AVC must not be tagged as HDR")
    }

    func testMasterWithHEVCMain10OmitsVideoRange() {
        let master = HLSPlaylistBuilder.makeMaster(
            videoBandwidthHint: 12_000_000,
            videoProbe: videoProbe,
            audioProbe: audioProbe,
            videoMediaPath: "video.m3u8",
            audioMediaPath: "audio.m3u8",
            videoCodec: "hvc1.2.4.L150.B0",
            audioCodec: "mp4a.40.2"
        )
        XCTAssertTrue(master.contains(#"CODECS="hvc1.2.4.L150.B0,mp4a.40.2""#))
        XCTAssertFalse(master.contains("VIDEO-RANGE="))
    }

    func testMasterWithDolbyVisionHLGEmitsBaseCodecAndSupplementalCodecs() {
        let videoMetadata = ISOBMFF.VideoMetadata(
            width: 4096,
            height: 2160,
            videoRange: .hlg,
            codecString: "hvc1.2.20000000.L153.90",
            supplementalCodecString: "dvh1.08.09/db4h"
        )
        let probe = ISOBMFF.Probe(
            initSegment: videoProbe.initSegment,
            index: videoProbe.index,
            videoMetadata: videoMetadata
        )
        let master = HLSPlaylistBuilder.makeMaster(
            videoBandwidthHint: 18_000_000,
            videoProbe: probe,
            audioProbe: audioProbe,
            videoMediaPath: "video.m3u8",
            audioMediaPath: "audio.m3u8",
            videoCodec: "dvh1.08.07",
            audioCodec: "mp4a.40.2"
        )
        XCTAssertTrue(master.contains(#"CODECS=\"hvc1.2.20000000.L153.90,mp4a.40.2\""#))
        XCTAssertTrue(master.contains(#"SUPPLEMENTAL-CODECS=\"dvh1.08.09/db4h\""#))
        XCTAssertTrue(master.contains("VIDEO-RANGE=HLG"))
    }

    func testMasterAudioMediaDoesNotCarryCodecs() {
        let master = HLSPlaylistBuilder.makeMaster(
            videoBandwidthHint: 6_000_000,
            videoProbe: videoProbe,
            audioProbe: audioProbe,
            videoMediaPath: "video.m3u8",
            audioMediaPath: "audio.m3u8",
            videoCodec: "hev1.1.6.L120.90",
            audioCodec: "mp4a.40.2"
        )
        let mediaLine = master.components(separatedBy: "\n")
            .first { $0.hasPrefix("#EXT-X-MEDIA:") } ?? ""
        XCTAssertFalse(mediaLine.contains("CODECS="),
                       "EXT-X-MEDIA must not carry CODECS (not a valid attribute per RFC 8216)")
    }

    // MARK: - Media

    func testMediaPlaylistEmitsMapAndOneLinePerFragment() {
        let probe = ISOBMFF.Probe(
            initSegment: ISOBMFF.InitSegment(offset: 0, length: 1234),
            index: ISOBMFF.SegmentIndex(timescale: 1000, entries: [
                ISOBMFF.SegmentIndexEntry(offset: 1234, length: 50_000, durationTicks: 4_000),
                ISOBMFF.SegmentIndexEntry(offset: 51_234, length: 60_000, durationTicks: 5_500),
            ]),
            videoMetadata: nil
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
