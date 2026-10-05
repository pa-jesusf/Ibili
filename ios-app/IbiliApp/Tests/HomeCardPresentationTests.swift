import CoreGraphics
import Foundation
import XCTest
@testable import Ibili

final class HomeCardPresentationTests: XCTestCase {
    func testOriginalCoverAndInformationHaveSeparateNonoverlappingFramesAtEveryGridWidth() {
        for width: CGFloat in [82, 90, 110, 177, 241, 366, 500] {
            for author in [false, true] {
                for metadata in [false, true] {
                    let layout = MediaCardLayout(width: width, showsAuthor: author, showsMetadata: metadata)
                    XCTAssertEqual(layout.coverHeight, width * 9 / 16)
                    XCTAssertEqual(layout.backdropFrame.minY, layout.coverFrame.maxY)
                    XCTAssertGreaterThan(layout.titleFrame.minY, layout.coverFrame.maxY)
                    XCTAssertEqual(layout.backdropFrame.maxY, layout.height)
                    for frame in [layout.titleFrame] + (author ? [layout.authorFrame] : []) + (metadata ? [layout.metadataFrame] : []) {
                        XCTAssertGreaterThan(frame.width, 0)
                        XCTAssertLessThanOrEqual(frame.maxX, width)
                        XCTAssertLessThanOrEqual(frame.maxY, layout.height - 12)
                    }
                }
            }
        }
    }

    func testPlayCountPrecedesAuthorAndNarrowDurationHasItsOwnLine() {
        for width: CGFloat in [82, 90, 110, 177, 241, 366, 500] {
            let layout = MediaCardLayout(width: width, showsAuthor: true, showsMetadata: true, showsDuration: true)
            XCTAssertLessThan(layout.metadataFrame.maxY, layout.authorFrame.minY)
            if width >= 150 {
                XCTAssertLessThan(layout.durationY + 22, layout.authorFrame.minY)
            }
        }
        for width: CGFloat in [150, 159, 177] {
            let layout = MediaCardLayout(width: width, showsAuthor: false, showsMetadata: true, showsDuration: true)
            XCTAssertTrue(layout.durationUsesSeparateLine)
            XCTAssertLessThan(layout.metadataFrame.maxY, layout.durationY)
            XCTAssertGreaterThanOrEqual(layout.durationAvailableWidth, 100)
        }
        for width: CGFloat in [82, 90, 110] {
            for metadata in [false, true] {
                let layout = MediaCardLayout(width: width, showsAuthor: true, showsMetadata: metadata, showsDuration: true)
                XCTAssertTrue(layout.durationUsesSeparateLine)
                XCTAssertLessThan(layout.durationY + 22, layout.authorFrame.minY)
                XCTAssertGreaterThanOrEqual(layout.durationAvailableWidth, 62)
                if metadata { XCTAssertLessThan(layout.metadataFrame.maxY, layout.durationY) }
            }
        }
    }

    func testLiveAndArticleLayoutPreserveInformationWithoutReservingVideoMenu() {
        for width: CGFloat in [82, 110, 177, 241, 366] {
            let live = MediaCardLayout(width: width, showsAuthor: true, showsMetadata: true, showsOverflowMenu: false)
            XCTAssertFalse(live.menuUsesSeparateLine)
            XCTAssertEqual(live.authorFrame.maxX, width - live.horizontalInset)
            XCTAssertLessThan(live.metadataFrame.maxY, live.authorFrame.minY)
            let article = MediaCardLayout(width: width, showsAuthor: false, showsMetadata: true,
                                          showsOverflowMenu: false, showsSummary: true, showsSecondaryMetadata: true,
                                          compactMetadataLines: 3)
            XCTAssertGreaterThan(article.summaryFrame.minY, article.titleFrame.maxY)
            XCTAssertGreaterThan(article.secondaryMetadataFrame.minY, article.summaryFrame.maxY)
            XCTAssertGreaterThan(article.metadataFrame.minY, article.secondaryMetadataFrame.maxY)
            XCTAssertEqual(article.metadataFrame.maxY, article.height - 12)
            XCTAssertEqual(article.metadataFrame.width, width - article.horizontalInset * 2)
        }
    }

    func testBackdropIsAlreadyFrostedAtTopAndHasNoTransparentEdge() throws {
        let width = 640, height = 360
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = (x / 8).isMultiple(of: 2) ? 0 : 255
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let source = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let result = try XCTUnwrap(ExtendedCoverBackdrop.render(source))
        for y in [0, result.height - 1] {
            var values: [UInt8] = []
            for x in stride(from: 40, through: 120, by: 2) {
                let pixel = try rgbaPixel(result, x: x, y: y)
                XCTAssertGreaterThan(pixel[0], 120, "the top must not retain sharp black stripes")
                XCTAssertLessThan(pixel[0], 225, "the top must not retain sharp white stripes")
                XCTAssertEqual(pixel[3], 255)
                values.append(pixel[0])
            }
            XCTAssertLessThan(Int(values.max()!) - Int(values.min()!), 16)
            for x in [0, result.width - 1] {
                XCTAssertEqual(try rgbaPixel(result, x: x, y: y)[3], 255)
            }
        }
        // CDN thumbnail sizes are integer pixels and often not exact 16:9.
        // Their lower quarter can end between pixels and must stay opaque.
        for (width, height) in [(507, 285), (354, 199), (531, 299), (1068, 601)] {
            let backdrop = try XCTUnwrap(ExtendedCoverBackdrop.render(makeCover(width: width, height: height)))
            for y in [0, 1, 16, backdrop.height - 1] {
                for x in [0, backdrop.width / 2, backdrop.width - 1] {
                    XCTAssertEqual(try rgbaPixel(backdrop, x: x, y: y)[3], 255, "\(width)×\(height) edge must stay opaque")
                }
            }
        }
    }

    func testBackdropUsesCoverBottomAndKeepsItsBitmapSmall() throws {
        let source = try makeCover()
        let result = try XCTUnwrap(ExtendedCoverBackdrop.render(source))
        XCTAssertEqual(result.width, 160)
        XCTAssertEqual(result.height, 120)
        let pixel = try rgbaPixel(result, x: 80, y: 60)
        XCTAssertGreaterThan(pixel[0], 220, "the extension must use the red bottom, not the blue top")
        XCTAssertLessThan(pixel[2], 30)
        XCTAssertLessThanOrEqual(result.bytesPerRow * result.height, 100_000)
        // Processing must not replace/mutate the full-resolution cover.
        XCTAssertEqual(source.width, 640)
        XCTAssertEqual(source.height, 360)
        XCTAssertGreaterThan(try rgbaPixel(source, x: 320, y: 20)[2], 220)
    }

    func testBackdropReusesPreparedBitmapForSameCoverRequest() throws {
        let source = try makeCover()
        let key = UUID().uuidString
        let first = try XCTUnwrap(ExtendedCoverBackdrop.image(for: source, cacheKey: key))
        let second = try XCTUnwrap(ExtendedCoverBackdrop.image(for: source, cacheKey: key))
        XCTAssertTrue(first === second)
    }

    func testDynamicDTOAcceptsNewFormattedStatsAndHistoricalPayloads() throws {
        let decoder = JSONDecoder()
        let video = try decoder.decode(DynamicVideoDTO.self, from: Data(#"{"aid":123,"bvid":"BV123","play_label":"3.2万","danmaku_label":"0"}"#.utf8))
        XCTAssertEqual(video.playLabel, "3.2万")
        XCTAssertEqual(video.danmakuLabel, "0")
        XCTAssertEqual(video.aid, 123)
        let old = try decoder.decode(DynamicVideoDTO.self, from: Data(#"{"stat_label":"3.2万观看"}"#.utf8))
        XCTAssertEqual(old.statLabel, "3.2万观看")
        XCTAssertEqual(old.playLabel, "")
        XCTAssertEqual(old.danmakuLabel, "")
    }

    private func makeCover(width: Int = 640, height: Int = 360) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = y >= height * 3 / 4 ? 255 : 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = y >= height * 3 / 4 ? 0 : 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    private func rgbaPixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                            bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return Array(UnsafeBufferPointer(start: data + offset, count: 4))
    }
}
