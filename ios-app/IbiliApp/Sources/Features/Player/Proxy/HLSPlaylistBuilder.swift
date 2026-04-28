import Foundation

/// Synthesises HLS playlists that wrap a fragmented MP4 source described by
/// an ``ISOBMFF.Probe``.
///
/// The output is a tiny VOD-style master + per-track media playlist that
/// uses `EXT-X-MAP` (so the init segment is delivered separately) and
/// `EXT-X-BYTERANGE` (so each fragment is referenced as a byte range in
/// one upstream blob, with no remuxing).
enum HLSPlaylistBuilder {

    /// Reasonable default if we cannot derive a real bandwidth value.
    private static let fallbackBandwidth: Int = 2_000_000

    /// Master playlist:
    /// * one video variant
    /// * one audio rendition group, when separate audio is present
    static func makeMaster(videoBandwidthHint: Int?,
                           hasSeparateAudio: Bool,
                           videoMediaPath: String,
                           audioMediaPath: String?) -> String {
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        if hasSeparateAudio, let audioMediaPath {
            lines.append(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="default",DEFAULT=YES,AUTOSELECT=YES,URI="\#(audioMediaPath)""#)
        }
        let bw = videoBandwidthHint ?? fallbackBandwidth
        if hasSeparateAudio {
            lines.append(#"#EXT-X-STREAM-INF:BANDWIDTH=\#(bw),AUDIO="aud""#)
        } else {
            lines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(bw)")
        }
        lines.append(videoMediaPath)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Media playlist describing one fMP4 source by byte ranges.
    /// `segmentPath` is the proxy URL (relative or absolute) used both for
    /// `EXT-X-MAP` and for each fragment line.
    static func makeMedia(probe: ISOBMFF.Probe, segmentPath: String) -> String {
        let target = max(1, Int(probe.index.targetDurationSec.rounded(.up)))
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            #"#EXT-X-MAP:URI="\#(segmentPath)",BYTERANGE="\#(probe.initSegment.length)@\#(probe.initSegment.offset)""#,
        ]
        for entry in probe.index.entries {
            let dur = String(format: "%.6f", Double(entry.durationTicks) / Double(probe.index.timescale))
            lines.append("#EXTINF:\(dur),")
            lines.append("#EXT-X-BYTERANGE:\(entry.length)@\(entry.offset)")
            lines.append(segmentPath)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}
