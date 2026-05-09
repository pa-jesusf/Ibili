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
    /// Keep normal videos bit-for-bit close to the authored `sidx`.
    /// Only very fragmented assets need playlist compaction.
    private static let mergeEntryCountThreshold = 4_000
    private static let outputEntrySoftLimit = 20_000
    private static let baseMergedSegmentDurationSec: Double = 6
    private static let maxMergedSegmentDurationSec: Double = 12
    private static let bandwidthSampleMaxSegments = 240
    private static let bandwidthSampleMaxDurationSec: Double = 15 * 60

    struct MediaPlan {
        let entries: [ISOBMFF.SegmentIndexEntry]
        let targetDuration: Int
        let wasMerged: Bool
    }

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
        let measured = measuredBandwidths(videoProbe: videoProbe, audioProbe: audioProbe)
        let bw = measured?.peak ?? videoBandwidthHint ?? fallbackBandwidth
        var streamAttrs = "BANDWIDTH=\(bw)"
        if let average = measured?.average {
            streamAttrs += ",AVERAGE-BANDWIDTH=\(average)"
        }
        // CODECS combines video + (separate) audio per RFC8216 §4.3.4.2.
        var codecsList: [String] = []
        let authoredVideoCodec = normalizedCodecString(videoProbe.videoMetadata?.codecString) ?? normalizedCodecString(videoCodec)
        if let authoredVideoCodec { codecsList.append(authoredVideoCodec) }
        if hasSeparateAudio, !audioCodec.isEmpty { codecsList.append(audioCodec) }
        if !codecsList.isEmpty {
            streamAttrs += #",CODECS="\#(codecsList.joined(separator: ","))""#
        }
        if let supplementalVideoCodec = normalizedCodecString(videoProbe.videoMetadata?.supplementalCodecString) {
            streamAttrs += #",SUPPLEMENTAL-CODECS="\#(supplementalVideoCodec)""#
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

    private static func measuredBandwidths(videoProbe: ISOBMFF.Probe, audioProbe: ISOBMFF.Probe?) -> (peak: Int, average: Int)? {
        let maxCount = max(videoProbe.index.entries.count, audioProbe?.index.entries.count ?? 0)
        guard maxCount > 0 else { return nil }

        var bitrates: [Double] = []
        var sampledDuration: Double = 0
        for index in 0..<maxCount {
            let videoEntry = videoProbe.index.entries.indices.contains(index) ? videoProbe.index.entries[index] : nil
            let audioEntry = audioProbe?.index.entries.indices.contains(index) == true ? audioProbe?.index.entries[index] : nil
            let bytes = UInt64(videoEntry?.length ?? 0) + UInt64(audioEntry?.length ?? 0)
            guard bytes > 0 else { continue }
            let videoDuration = videoEntry.map { Double($0.durationTicks) / Double(videoProbe.index.timescale) } ?? 0
            let audioDuration = audioEntry.map { Double($0.durationTicks) / Double(audioProbe?.index.timescale ?? 1) } ?? 0
            let duration = max(videoDuration, audioDuration, 0.001)
            bitrates.append(Double(bytes * 8) / duration)
            sampledDuration += duration
            if bitrates.count >= bandwidthSampleMaxSegments || sampledDuration >= bandwidthSampleMaxDurationSec {
                break
            }
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

    private static func normalizedCodecString(_ raw: String?) -> String? {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    /// Media playlist describing one fMP4 source by byte ranges.
    /// `segmentPath` is the proxy URL (relative or absolute) used both for
    /// `EXT-X-MAP` and for each fragment line.
    static func makeMedia(probe: ISOBMFF.Probe, segmentPath: String, targetDurationOverride: Int? = nil) -> String {
        let plan = makeMediaPlan(probe: probe, targetDurationOverride: targetDurationOverride)
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-TARGETDURATION:\(plan.targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            #"#EXT-X-MAP:URI="\#(segmentPath)",BYTERANGE="\#(probe.initSegment.length)@\#(probe.initSegment.offset)""#,
        ]
        for entry in plan.entries {
            let dur = String(format: "%.6f", Double(entry.durationTicks) / Double(probe.index.timescale))
            lines.append("#EXTINF:\(dur),")
            lines.append("#EXT-X-BYTERANGE:\(entry.length)@\(entry.offset)")
            lines.append(segmentPath)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    static func makeMediaPlan(probe: ISOBMFF.Probe, targetDurationOverride: Int? = nil) -> MediaPlan {
        let entries = plannedMediaEntries(for: probe)
        let measuredTargetDuration = entries
            .map { Double($0.durationTicks) / Double(probe.index.timescale) }
            .max() ?? probe.index.targetDurationSec
        let target = max(1, Int(measuredTargetDuration.rounded(.up)), targetDurationOverride ?? 0)
        return MediaPlan(
            entries: entries,
            targetDuration: target,
            wasMerged: entries.count != probe.index.entries.count
        )
    }

    static func plannedMediaEntryCount(probe: ISOBMFF.Probe) -> Int {
        plannedMediaEntries(for: probe).count
    }

    static func plannedMediaTargetDuration(probe: ISOBMFF.Probe) -> Int {
        makeMediaPlan(probe: probe).targetDuration
    }

    private static func plannedMediaEntries(for probe: ISOBMFF.Probe) -> [ISOBMFF.SegmentIndexEntry] {
        let entries = probe.index.entries
        guard entries.count > mergeEntryCountThreshold, probe.index.timescale > 0 else { return entries }

        let baseMerged = mergedMediaEntries(for: probe, targetDurationSec: baseMergedSegmentDurationSec)
        guard baseMerged.count > outputEntrySoftLimit else { return baseMerged }

        return mergedMediaEntries(for: probe, targetDurationSec: maxMergedSegmentDurationSec)
    }

    private static func mergedMediaEntries(for probe: ISOBMFF.Probe,
                                           targetDurationSec: Double) -> [ISOBMFF.SegmentIndexEntry] {
        let entries = probe.index.entries
        guard entries.count > 1, probe.index.timescale > 0 else { return entries }
        let targetTicks = UInt64((targetDurationSec * Double(probe.index.timescale)).rounded())
        guard targetTicks > 0 else { return entries }

        var merged: [ISOBMFF.SegmentIndexEntry] = []
        merged.reserveCapacity(max(1, entries.count / 3))
        var currentOffset = entries[0].offset
        var currentLength = entries[0].length
        var currentDuration = entries[0].durationTicks
        var expectedNextOffset = entries[0].offset + entries[0].length

        for entry in entries.dropFirst() {
            let isContiguous = entry.offset == expectedNextOffset
            if isContiguous, currentDuration < targetTicks {
                currentLength += entry.length
                currentDuration += entry.durationTicks
                expectedNextOffset = entry.offset + entry.length
                continue
            }
            merged.append(ISOBMFF.SegmentIndexEntry(
                offset: currentOffset,
                length: currentLength,
                durationTicks: currentDuration
            ))
            currentOffset = entry.offset
            currentLength = entry.length
            currentDuration = entry.durationTicks
            expectedNextOffset = entry.offset + entry.length
        }

        merged.append(ISOBMFF.SegmentIndexEntry(
            offset: currentOffset,
            length: currentLength,
            durationTicks: currentDuration
        ))
        return merged
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
