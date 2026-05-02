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
                           videoProbe: ISOBMFF.Probe,
                           audioProbe: ISOBMFF.Probe?,
                           videoMediaPath: String,
                           audioMediaPath: String?,
                           videoCodec: String = "",
                           audioCodec: String = "",
                           videoResolutionHint: (Int, Int)? = nil,
                           videoRangeHint: String? = nil,
                           frameRateHint: String? = nil) -> String {
        let hasSeparateAudio = audioProbe != nil && audioMediaPath != nil
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        if hasSeparateAudio, let audioMediaPath {
            let mediaAttrs = #"TYPE=AUDIO,GROUP-ID="aud",NAME="default",DEFAULT=YES,AUTOSELECT=YES,URI="\#(audioMediaPath)""#
            lines.append("#EXT-X-MEDIA:\(mediaAttrs)")
        }
        let bw = measuredPeakBandwidth(videoProbe: videoProbe, audioProbe: audioProbe)
            ?? videoBandwidthHint
            ?? fallbackBandwidth
        var streamAttrs = "BANDWIDTH=\(bw)"
        if let averageBandwidth = measuredAverageBandwidth(videoProbe: videoProbe, audioProbe: audioProbe) {
            streamAttrs += ",AVERAGE-BANDWIDTH=\(averageBandwidth)"
        }
        // CODECS combines video + (separate) audio per RFC8216 §4.3.4.2.
        var codecsList: [String] = []
        if !videoCodec.isEmpty { codecsList.append(videoCodec) }
        if hasSeparateAudio, !audioCodec.isEmpty { codecsList.append(audioCodec) }
        if !codecsList.isEmpty {
            streamAttrs += #",CODECS="\#(codecsList.joined(separator: ","))""#
        }
        if let resolution = videoProbe.videoMetadata.map({ ($0.width, $0.height) }) ?? videoResolutionHint {
            streamAttrs += ",RESOLUTION=\(resolution.0)x\(resolution.1)"
        }
        if let videoRange = videoProbe.videoMetadata?.videoRange?.rawValue ?? normalizedEnumString(videoRangeHint) {
            streamAttrs += ",VIDEO-RANGE=\(videoRange)"
        }
        if let frameRate = normalizedFrameRate(frameRateHint) {
            streamAttrs += ",FRAME-RATE=\(frameRate)"
        }
        if hasSeparateAudio {
            streamAttrs += #",AUDIO="aud""#
        }
        lines.append("#EXT-X-STREAM-INF:\(streamAttrs)")
        lines.append(videoMediaPath)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func measuredPeakBandwidth(videoProbe: ISOBMFF.Probe, audioProbe: ISOBMFF.Probe?) -> Int? {
        measuredBandwidths(videoProbe: videoProbe, audioProbe: audioProbe).map(\.peak)
    }

    private static func measuredAverageBandwidth(videoProbe: ISOBMFF.Probe, audioProbe: ISOBMFF.Probe?) -> Int? {
        measuredBandwidths(videoProbe: videoProbe, audioProbe: audioProbe).map(\.average)
    }

    private static func measuredBandwidths(videoProbe: ISOBMFF.Probe, audioProbe: ISOBMFF.Probe?) -> (peak: Int, average: Int)? {
        let maxCount = max(videoProbe.index.entries.count, audioProbe?.index.entries.count ?? 0)
        guard maxCount > 0 else { return nil }

        var bitrates: [Double] = []
        for index in 0..<maxCount {
            let videoEntry = videoProbe.index.entries.indices.contains(index) ? videoProbe.index.entries[index] : nil
            let audioEntry = audioProbe?.index.entries.indices.contains(index) == true ? audioProbe?.index.entries[index] : nil
            let bytes = UInt64(videoEntry?.length ?? 0) + UInt64(audioEntry?.length ?? 0)
            guard bytes > 0 else { continue }
            let videoDuration = videoEntry.map { Double($0.durationTicks) / Double(videoProbe.index.timescale) } ?? 0
            let audioDuration = audioEntry.map { Double($0.durationTicks) / Double(audioProbe?.index.timescale ?? 1) } ?? 0
            let duration = max(videoDuration, audioDuration, 0.001)
            bitrates.append(Double(bytes * 8) / duration)
        }

        guard !bitrates.isEmpty else { return nil }
        let average = Int((bitrates.reduce(0, +) / Double(bitrates.count)).rounded(.up))
        let peak = Int((bitrates.max() ?? 0).rounded(.up))
        return (peak: peak, average: average)
    }

    private static func normalizedFrameRate(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let slash = raw.firstIndex(of: "/") {
            let numerator = raw[..<slash]
            let denominator = raw[raw.index(after: slash)...]
            guard let numeratorValue = Double(numerator),
                  let denominatorValue = Double(denominator),
                  denominatorValue > 0 else {
                return nil
            }
            return String(format: "%.3f", numeratorValue / denominatorValue)
        }
        guard let value = Double(raw), value > 0 else { return nil }
        return String(format: "%.3f", value)
    }

    private static func normalizedEnumString(_ raw: String?) -> String? {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .nilIfEmpty
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
