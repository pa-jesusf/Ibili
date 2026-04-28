import XCTest
@testable import Ibili

/// Verifies ``ISOBMFF/probe(_:)`` against synthesized fragmented MP4 heads.
/// Real B 站 streams aren't shipped as fixtures (they're huge and rotate
/// often) — instead these tests build a minimal box layout from scratch
/// and assert the parser extracts the correct init range and segment list.
final class ISOBMFFParserTests: XCTestCase {

    func testParsesInitRangeAndSegmentIndexFromSynthesizedFMP4() throws {
        // ftyp = 24 bytes, moov = 32 bytes, sidx = (8 header + payload), then mdat.
        let ftyp = makeBox(type: "ftyp", body: Data(count: 16))         // 24 B
        let moov = makeBox(type: "moov", body: Data(count: 24))         // 32 B
        let timescale: UInt32 = 1000
        // Two fragments: 5 s @ 100_000 bytes, 6 s @ 120_000 bytes.
        let sidxPayload = makeSidxPayload(
            timescale: timescale,
            references: [
                (size: 100_000, durationTicks: 5_000),
                (size: 120_000, durationTicks: 6_000),
            ]
        )
        let sidx = makeBox(type: "sidx", body: sidxPayload)
        let mdat = makeBox(type: "mdat", body: Data(count: 8))          // ignored

        var stream = Data()
        stream.append(ftyp)
        stream.append(moov)
        stream.append(sidx)
        stream.append(mdat)

        let probe = try ISOBMFF.probe(stream)

        // init = ftyp + moov = 24 + 32 = 56
        XCTAssertEqual(probe.initSegment.offset, 0)
        XCTAssertEqual(probe.initSegment.length, 56)

        XCTAssertEqual(probe.index.timescale, timescale)
        XCTAssertEqual(probe.index.entries.count, 2)

        // sidx box ends at 56 (ftyp+moov) + 8 (sidx header) + sidxPayload.count
        let sidxEnd = UInt64(56 + 8 + sidxPayload.count)
        XCTAssertEqual(probe.index.entries[0].offset, sidxEnd)
        XCTAssertEqual(probe.index.entries[0].length, 100_000)
        XCTAssertEqual(probe.index.entries[0].durationTicks, 5_000)
        XCTAssertEqual(probe.index.entries[1].offset, sidxEnd + 100_000)
        XCTAssertEqual(probe.index.entries[1].length, 120_000)
        XCTAssertEqual(probe.index.entries[1].durationTicks, 6_000)

        XCTAssertEqual(probe.index.totalDurationSec, 11.0, accuracy: 0.001)
        XCTAssertEqual(probe.index.targetDurationSec, 6.0, accuracy: 0.001)
    }

    func testThrowsWhenSidxBoxMissing() {
        let ftyp = makeBox(type: "ftyp", body: Data(count: 16))
        let moov = makeBox(type: "moov", body: Data(count: 24))
        let mdat = makeBox(type: "mdat", body: Data(count: 8))
        var stream = Data(); stream.append(ftyp); stream.append(moov); stream.append(mdat)

        XCTAssertThrowsError(try ISOBMFF.probe(stream)) { error in
            XCTAssertEqual(error as? ISOBMFF.ProbeError, .missingSidx)
        }
    }

    func testThrowsWhenTruncatedBeforeMoov() {
        let ftyp = makeBox(type: "ftyp", body: Data(count: 16))
        // Half of a box header — the parser must report truncation, not crash.
        let truncated = Data([0x00, 0x00, 0x00])
        var stream = Data(); stream.append(ftyp); stream.append(truncated)

        XCTAssertThrowsError(try ISOBMFF.probe(stream))
    }

    // MARK: - Box / sidx synthesis

    private func makeBox(type: String, body: Data) -> Data {
        precondition(type.utf8.count == 4)
        var data = Data()
        let total = UInt32(8 + body.count)
        data.append(uint32: total)
        data.append(Data(type.utf8))
        data.append(body)
        return data
    }

    private func makeSidxPayload(timescale: UInt32,
                                 references: [(size: UInt32, durationTicks: UInt32)]) -> Data {
        // version 0:
        //   uint32 versionAndFlags
        //   uint32 reference_id
        //   uint32 timescale
        //   uint32 earliest_pts
        //   uint32 first_offset           (relative to *end of sidx box*)
        //   uint16 reserved
        //   uint16 reference_count
        //   per ref: uint32 (type|size), uint32 duration, uint32 sap
        var data = Data()
        data.append(uint32: 0)                       // version 0, no flags
        data.append(uint32: 1)                       // reference_id
        data.append(uint32: timescale)
        data.append(uint32: 0)                       // earliest_pts
        data.append(uint32: 0)                       // first_offset
        data.append(uint16: 0)                       // reserved
        data.append(uint16: UInt16(references.count))
        for ref in references {
            // referenceType=0, referenced_size in lower 31 bits.
            data.append(uint32: ref.size & 0x7FFF_FFFF)
            data.append(uint32: ref.durationTicks)
            data.append(uint32: 0x9000_0000)         // SAP info — opaque, parser ignores
        }
        return data
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
    mutating func append(uint32 value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
