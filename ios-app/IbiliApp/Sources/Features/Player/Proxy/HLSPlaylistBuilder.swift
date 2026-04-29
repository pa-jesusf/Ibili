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
    ///
    /// `videoCodec` / `audioCodec` are RFC6381 codec strings (e.g.
    /// `"avc1.640032"`, `"hvc1.2.4.L150.B0"`, `"mp4a.40.2"`). When
    /// non-empty they are emitted into the `CODECS` attribute on the
    /// variant. AVPlayer needs this to dispatch HEVC Main10 / HDR
    /// content to the correct decoder before fetching segments —
    /// without it some HDR variants fail with `CoreMediaErrorDomain
    /// -12927` ("MIME type not supported") even on devices that fully
    /// support HDR (iPhone 17 Pro Max etc.).
    static func makeMaster(videoBandwidthHint: Int?,
                           hasSeparateAudio: Bool,
                           videoMediaPath: String,
                           audioMediaPath: String?,
                           videoCodec: String = "",
                           audioCodec: String = "") -> String {
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        if hasSeparateAudio, let audioMediaPath {
            var mediaAttrs = #"TYPE=AUDIO,GROUP-ID="aud",NAME="default",DEFAULT=YES,AUTOSELECT=YES"#
            if !audioCodec.isEmpty {
                mediaAttrs += #",CODECS="\#(audioCodec)""#
            }
            mediaAttrs += #",URI="\#(audioMediaPath)""#
            lines.append("#EXT-X-MEDIA:\(mediaAttrs)")
        }
        let bw = videoBandwidthHint ?? fallbackBandwidth
        var streamAttrs = "BANDWIDTH=\(bw)"
        // CODECS combines video + (separate) audio per RFC8216 §4.3.4.2.
        var codecsList: [String] = []
        if !videoCodec.isEmpty { codecsList.append(videoCodec) }
        if hasSeparateAudio, !audioCodec.isEmpty { codecsList.append(audioCodec) }
        if !codecsList.isEmpty {
            streamAttrs += #",CODECS="\#(codecsList.joined(separator: ","))""#
        }
        // HEVC profile 2 = Main10 (Bilibili HDR10/qn=125) and Dolby
        // Vision codec strings (`dvh1.*`/`dvhe.*`, qn=126) both ride
        // PQ transfer in the wild on Bilibili. Plain Main profile
        // (`hvc1.1.*`) and H.264 (`avc1.*`) are always SDR; we omit
        // the attribute and let AVPlayer default to SDR.
        if Self.isHDRTransfer(codec: videoCodec) {
            streamAttrs += ",VIDEO-RANGE=PQ"
        }
        if hasSeparateAudio {
            streamAttrs += #",AUDIO="aud""#
        }
        lines.append("#EXT-X-STREAM-INF:\(streamAttrs)")
        lines.append(videoMediaPath)
        return lines.joined(separator: "\n") + "\n"
    }

    /// True when `codec` advertises an HDR transfer characteristic on
    /// the Bilibili side: HEVC Main10 (`hvc1.2.*` / `hev1.2.*`) or
    /// Dolby Vision (`dvh1.*` / `dvhe.*`). Bilibili always ships these
    /// with PQ transfer.
    ///
    /// AV1 HDR uses `av01.P.LLX.DD.*` where `DD` = bit depth; `10`
    /// indicates 10-bit HDR content.
    private static func isHDRTransfer(codec: String) -> Bool {
        let lower = codec.lowercased()
        if lower.hasPrefix("hvc1.2") || lower.hasPrefix("hev1.2")
            || lower.hasPrefix("dvh1.") || lower.hasPrefix("dvhe.") {
            return true
        }
        if lower.hasPrefix("av01.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 4 {
                let bitDepth = parts[3]
                return bitDepth == "10" || bitDepth == "12"
            }
        }
        return false
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
