import Foundation

/// ISO Base Media File Format helpers for the HLS proxy.
///
/// We only need two pieces of information from a B 站 fMP4 file:
/// 1. The byte range covering `ftyp` + `moov` — this becomes the HLS
///    init segment (`#EXT-X-MAP` URI w/ BYTERANGE).
/// 2. The `sidx` box — its `references[]` describe each fragment's
///    `[offset, size, durationTicks]`, which translates 1-to-1 into
///    `#EXTINF` + `#EXT-X-BYTERANGE` lines.
///
/// Spec references: ISO/IEC 14496-12:2015 §4 (box structure),
/// §8.16.3 (Segment Index Box).
enum ISOBMFF {

    struct InitSegment: Equatable {
        /// Byte offset (inclusive) where the init blob starts in the source.
        let offset: UInt64
        /// Byte length of the init blob (covers `ftyp` + everything up to
        /// the start of `sidx`).
        let length: UInt64
    }

    struct SegmentIndexEntry: Equatable {
        /// Byte offset of the fragment relative to the start of the source.
        let offset: UInt64
        /// Byte length of the fragment.
        let length: UInt64
        /// Fragment duration in `timescale` ticks.
        let durationTicks: UInt64
    }

    struct SegmentIndex: Equatable {
        let timescale: UInt32
        let entries: [SegmentIndexEntry]

        /// Total duration in seconds (sum of all entries / timescale).
        var totalDurationSec: Double {
            guard timescale > 0 else { return 0 }
            let total = entries.reduce(UInt64(0)) { $0 + $1.durationTicks }
            return Double(total) / Double(timescale)
        }

        /// Largest fragment duration in seconds (used for
        /// `#EXT-X-TARGETDURATION`).
        var targetDurationSec: Double {
            guard timescale > 0 else { return 0 }
            let max = entries.map(\.durationTicks).max() ?? 0
            return Double(max) / Double(timescale)
        }
    }

    /// Parsed initialisation + index pair extracted from the head of a
    /// fragmented MP4.
    struct Probe: Equatable {
        let initSegment: InitSegment
        let index: SegmentIndex
    }

    enum ProbeError: Error, LocalizedError, Equatable {
        case truncated
        case missingFtyp
        case missingMoov
        case missingSidx
        case unsupportedSidxVersion(UInt8)
        case malformedBox(String)

        var errorDescription: String? {
            switch self {
            case .truncated:                return "fMP4 头部数据被截断"
            case .missingFtyp:              return "fMP4 缺少 ftyp box"
            case .missingMoov:              return "fMP4 缺少 moov box"
            case .missingSidx:              return "fMP4 缺少 sidx box"
            case .unsupportedSidxVersion(let v): return "sidx 版本 \(v) 暂不支持"
            case .malformedBox(let detail): return "fMP4 box 解析失败: \(detail)"
            }
        }
    }

    /// Parse the leading boxes of a fragmented MP4 and pull out the init
    /// blob plus the segment index.
    ///
    /// `data` must begin at byte 0 of the source. It does NOT have to cover
    /// the entire file — only ftyp + moov + sidx. For B 站 streams a 1 MiB
    /// probe is comfortably enough.
    static func probe(_ data: Data) throws -> Probe {
        var reader = BoxReader(data: data)
        var sawFtyp = false
        var initEnd: UInt64?
        var sidxBoxOffset: UInt64?
        var sidxPayload: Data?

        while reader.hasMore {
            let header = try reader.readBoxHeader()
            switch header.type {
            case "ftyp":
                sawFtyp = true
                try reader.skipBody(of: header)
            case "moov":
                guard sawFtyp else { throw ProbeError.missingFtyp }
                try reader.skipBody(of: header)
                initEnd = header.endOffset
            case "sidx":
                sidxBoxOffset = header.startOffset
                sidxPayload = try reader.readBody(of: header)
            case "mdat":
                // mdat is the bulk of the file; we never look inside it.
                // Once we hit it without having found sidx, give up — the
                // probe window did not cover sidx.
                if sidxPayload != nil { return try finish(initEnd: initEnd,
                                                          sidxBoxOffset: sidxBoxOffset,
                                                          sidxPayload: sidxPayload) }
                throw ProbeError.missingSidx
            default:
                try reader.skipBody(of: header)
            }
            if sidxPayload != nil, initEnd != nil { break }
        }

        return try finish(initEnd: initEnd,
                          sidxBoxOffset: sidxBoxOffset,
                          sidxPayload: sidxPayload)
    }

    private static func finish(initEnd: UInt64?,
                               sidxBoxOffset: UInt64?,
                               sidxPayload: Data?) throws -> Probe {
        guard let initEnd else { throw ProbeError.missingMoov }
        guard let sidxBoxOffset, let sidxPayload else { throw ProbeError.missingSidx }
        let initSegment = InitSegment(offset: 0, length: initEnd)
        // The byte that immediately follows the entire sidx box is the
        // anchor against which sidx's relative offsets are computed —
        // unless `first_offset` overrides it.
        let sidxBoxEnd = sidxBoxOffset + UInt64(sidxPayload.count) + 8 // header is 8 bytes
        let index = try parseSidx(payload: sidxPayload, anchor: sidxBoxEnd)
        return Probe(initSegment: initSegment, index: index)
    }

    private static func parseSidx(payload: Data, anchor anchorAfterBox: UInt64) throws -> SegmentIndex {
        var reader = BinaryReader(data: payload)
        let versionAndFlags = try reader.readUInt32()
        let version = UInt8(versionAndFlags >> 24)
        guard version == 0 || version == 1 else {
            throw ProbeError.unsupportedSidxVersion(version)
        }
        _ = try reader.readUInt32()                    // reference_id
        let timescale = try reader.readUInt32()

        // earliest_pts and first_offset are 32-bit if version == 0, 64-bit otherwise.
        if version == 0 {
            _ = try reader.readUInt32()                // earliest_pts
        } else {
            _ = try reader.readUInt64()                // earliest_pts
        }
        let firstOffsetRelative: UInt64
        if version == 0 {
            firstOffsetRelative = UInt64(try reader.readUInt32())
        } else {
            firstOffsetRelative = try reader.readUInt64()
        }
        _ = try reader.readUInt16()                    // reserved
        let referenceCount = try reader.readUInt16()

        var cursor = anchorAfterBox + firstOffsetRelative
        var entries: [SegmentIndexEntry] = []
        entries.reserveCapacity(Int(referenceCount))

        for _ in 0..<referenceCount {
            let sizeWord = try reader.readUInt32()
            let referenceType = (sizeWord >> 31) & 0x1
            let referencedSize = UInt64(sizeWord & 0x7FFF_FFFF)
            let durationTicks = UInt64(try reader.readUInt32())
            _ = try reader.readUInt32()                // SAP info — unused
            // referenceType==1 means the reference itself points at another
            // sidx ("hierarchical sidx"). B 站 never sends those; treat as
            // an error so we don't silently miss fragments.
            guard referenceType == 0 else {
                throw ProbeError.malformedBox("unexpected hierarchical sidx reference")
            }
            entries.append(SegmentIndexEntry(offset: cursor,
                                             length: referencedSize,
                                             durationTicks: durationTicks))
            cursor &+= referencedSize
        }
        return SegmentIndex(timescale: timescale, entries: entries)
    }
}

// MARK: - Readers

private struct BoxHeader {
    let type: String
    let startOffset: UInt64
    let endOffset: UInt64           // exclusive
    let bodyOffset: UInt64          // first byte after the 8/16-byte header
}

private struct BoxReader {
    let data: Data
    var cursor: Int = 0

    init(data: Data) { self.data = data }

    var hasMore: Bool { cursor + 8 <= data.count }

    mutating func readBoxHeader() throws -> BoxHeader {
        guard cursor + 8 <= data.count else { throw ISOBMFF.ProbeError.truncated }
        let start = UInt64(cursor)
        let size32 = readUInt32At(cursor)
        let typeBytes = data.subdata(in: (cursor + 4)..<(cursor + 8))
        guard let type = String(data: typeBytes, encoding: .ascii) else {
            throw ISOBMFF.ProbeError.malformedBox("non-ascii box type")
        }
        cursor += 8
        var totalSize: UInt64
        if size32 == 1 {
            guard cursor + 8 <= data.count else { throw ISOBMFF.ProbeError.truncated }
            totalSize = readUInt64At(cursor)
            cursor += 8
        } else if size32 == 0 {
            // Box extends to end of file. We don't support that for the
            // boxes we care about, but non-target boxes can fall through to
            // skipBody which will detect the truncation.
            totalSize = UInt64(data.count) - start
        } else {
            totalSize = UInt64(size32)
        }
        let body = UInt64(cursor)
        let end = start + totalSize
        return BoxHeader(type: type, startOffset: start, endOffset: end, bodyOffset: body)
    }

    mutating func skipBody(of header: BoxHeader) throws {
        let bodyLen = Int(header.endOffset - header.bodyOffset)
        if cursor + bodyLen > data.count {
            throw ISOBMFF.ProbeError.truncated
        }
        cursor += bodyLen
    }

    mutating func readBody(of header: BoxHeader) throws -> Data {
        let bodyLen = Int(header.endOffset - header.bodyOffset)
        guard cursor + bodyLen <= data.count else { throw ISOBMFF.ProbeError.truncated }
        let slice = data.subdata(in: cursor..<(cursor + bodyLen))
        cursor += bodyLen
        return slice
    }

    private func readUInt32At(_ index: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(data[index + i]) }
        return v
    }

    private func readUInt64At(_ index: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[index + i]) }
        return v
    }
}

private struct BinaryReader {
    let data: Data
    var cursor: Int = 0

    init(data: Data) { self.data = data }

    mutating func readUInt16() throws -> UInt16 {
        guard cursor + 2 <= data.count else { throw ISOBMFF.ProbeError.truncated }
        let v = UInt16(data[cursor]) << 8 | UInt16(data[cursor + 1])
        cursor += 2
        return v
    }

    mutating func readUInt32() throws -> UInt32 {
        guard cursor + 4 <= data.count else { throw ISOBMFF.ProbeError.truncated }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(data[cursor + i]) }
        cursor += 4
        return v
    }

    mutating func readUInt64() throws -> UInt64 {
        guard cursor + 8 <= data.count else { throw ISOBMFF.ProbeError.truncated }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[cursor + i]) }
        cursor += 8
        return v
    }
}
