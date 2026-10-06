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
                    XCTAssertEqual(layout.titleFrame.minY - layout.coverHeight, 2)
                    XCTAssertEqual(layout.coverTransitionFrame.maxY, layout.coverHeight)
                    XCTAssertLessThanOrEqual(layout.coverTransitionFrame.height / layout.coverHeight, 0.056)
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

    func testBackdropProgressivelyDiffusesBelowJoinAndStaysOpaque() throws {
        let width = 640, height = 360
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = (x / 32).isMultiple(of: 2) ? 0 : 255
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let source = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let result = try XCTUnwrap(ExtendedCoverBackdrop.render(source))
        var contrasts: [Int] = []
        let join = Int(ceil(CGFloat(result.width) * ExtendedCoverBackdrop.transitionAspectRatio))
        for y in [join, result.height - 1] {
            var values: [UInt8] = []
            for x in stride(from: 40, through: 120, by: 2) {
                let pixel = try rgbaPixel(result, x: x, y: y)
                XCTAssertEqual(pixel[3], 255)
                values.append(pixel[0])
            }
            contrasts.append(Int(values.max()!) - Int(values.min()!))
            for x in [0, result.width - 1] {
                XCTAssertEqual(try rgbaPixel(result, x: x, y: y)[3], 255)
            }
        }
        XCTAssertGreaterThan(contrasts[0], contrasts[1], "the join must be less blurred than the area below it")
        XCTAssertLessThan(contrasts[1], 16)
        let context = try XCTUnwrap(CGContext(data: nil, width: result.width, height: result.height,
                                             bitsPerComponent: 8, bytesPerRow: result.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(result, in: CGRect(x: 0, y: 0, width: result.width, height: result.height))
        let rows = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var largestSlopeChange = 0
        let readabilityFadeEnd = Int(ceil(CGFloat(result.width) * (ExtendedCoverBackdrop.transitionAspectRatio
                                                          + ExtendedCoverBackdrop.Configuration().titleInsetRatio)))
        for y in (readabilityFadeEnd + 2)..<result.height {
            for x in 0..<result.width {
                let offset = (y * result.width + x) * 4
                let previous = offset - result.width * 4
                let slope = Int(rows[offset]) - Int(rows[previous])
                let previousSlope = Int(rows[previous]) - Int(rows[previous - result.width * 4])
                largestSlopeChange = max(largestSlopeChange, abs(slope - previousSlope))
            }
        }
        // Alpha at the join is checked separately. After the initial readability
        // fade, bands introduce abrupt slope changes in the broad blur ramp.
        XCTAssertLessThanOrEqual(largestSlopeChange, 8, "high-contrast stripes must fade without abrupt blur or tint steps")
        // CDN thumbnail sizes are integer pixels and often not exact 16:9.
        // Their lower quarter can end between pixels and must stay opaque.
        for (width, height) in [(507, 285), (354, 199), (531, 299), (1068, 601)] {
            let backdrop = try XCTUnwrap(ExtendedCoverBackdrop.render(makeCover(width: width, height: height)))
            for y in [join, join + 1, 16, backdrop.height - 1] {
                for x in [0, backdrop.width / 2, backdrop.width - 1] {
                    XCTAssertEqual(try rgbaPixel(backdrop, x: x, y: y)[3], 255, "\(width)×\(height) edge must stay opaque")
                }
            }
        }
    }

    func testBackdropUsesCoverBottomAndKeepsItsBitmapSmall() throws {
        let source = try makeCover()
        let result = try XCTUnwrap(ExtendedCoverBackdrop.render(source))
        XCTAssertEqual(result.width, ExtendedCoverBackdrop.pixelWidth)
        XCTAssertEqual(result.height, ExtendedCoverBackdrop.Configuration().pixelHeight)
        let pixel = try rgbaPixel(result, x: 80, y: 60)
        XCTAssertGreaterThan(pixel[0], 30, "the extension must retain the red bottom, not the blue top")
        XCTAssertLessThan(pixel[2], 30)
        XCTAssertLessThanOrEqual(result.bytesPerRow * result.height, 512 * 1024)
        // Processing must not replace/mutate the full-resolution cover.
        XCTAssertEqual(source.width, 640)
        XCTAssertEqual(source.height, 360)
        XCTAssertGreaterThan(try rgbaPixel(source, x: 320, y: 20)[2], 220)
    }

    func testBackdropReusesPreparedBitmapForSameCoverRequest() throws {
        let source = try makeCover()
        let key = UUID().uuidString
        let first = try XCTUnwrap(ExtendedCoverBackdrop.image(for: source, cacheKey: key, configuration: .init()))
        let second = try XCTUnwrap(ExtendedCoverBackdrop.image(for: source, cacheKey: key, configuration: .init()))
        XCTAssertTrue(first === second)
        let light = try XCTUnwrap(ExtendedCoverBackdrop.image(for: source, cacheKey: key,
                                  configuration: .init(red: 1, green: 1, blue: 1)))
        let taller = try XCTUnwrap(ExtendedCoverBackdrop.image(for: source, cacheKey: key,
                                   configuration: .init(panelAspectRatio: 1.2)))
        XCTAssertFalse(first === light)
        XCTAssertGreaterThan(try rgbaPixel(light, x: 80, y: 60)[1], try rgbaPixel(first, x: 80, y: 60)[1])
        XCTAssertGreaterThan(taller.height, first.height)
    }

    func testNarrowCoverOverlapFadesIntoTheExtensionWithoutAlphaSeam() throws {
        let image = try XCTUnwrap(ExtendedCoverBackdrop.render(makeCover()))
        let join = Int(ceil(CGFloat(image.width) * ExtendedCoverBackdrop.transitionAspectRatio))
        let alpha = try (0...join).map { try rgbaPixel(image, x: 80, y: $0)[3] }
        XCTAssertLessThanOrEqual(alpha.first!, 8)
        XCTAssertEqual(alpha.last, 255)
        XCTAssertEqual(alpha, alpha.sorted())
        let edge = try rgbaPixel(image, x: 80, y: join - 1)
        let backdrop = try rgbaPixel(image, x: 80, y: join)
        for channel in 0..<4 {
            XCTAssertLessThanOrEqual(abs(Int(edge[channel]) - Int(backdrop[channel])), 16)
        }
    }

    func testPublicationDateHasItsOwnFullWidthRow() {
        for width: CGFloat in [82, 110, 177, 241, 366] {
            for author in [false, true] {
                for movedStat in [false, true] {
                    let layout = MediaCardLayout(width: width, showsAuthor: author, showsMetadata: true,
                                                 showsDuration: true, showsPubdate: true,
                                                 showsStatWithPubdate: movedStat,
                                                 compactMetadataLines: movedStat ? 1 : 2)
                    XCTAssertGreaterThanOrEqual(layout.pubdateFrame.minY, layout.metadataFrame.maxY)
                    XCTAssertGreaterThan(layout.pubdateFrame.minY, layout.durationY + 22)
                    if author { XCTAssertLessThan(layout.pubdateFrame.maxY, layout.authorFrame.minY) }
                    XCTAssertGreaterThan(layout.pubdateFrame.width, width * 0.6)
                    XCTAssertLessThanOrEqual(layout.pubdateFrame.maxY, layout.height - 12)
                }
            }
        }
    }

    func testTitleReadabilityDoesNotWeakenWhenMetadataMakesTheCardTaller() throws {
        let white = try solidCover(value: 255)
        let black = try solidCover(value: 0)
        for width: CGFloat in [82, 177, 366, 500, 768, 1000, 1366] {
            for author in [false, true] {
                for (metadata, date, duration) in [(false, false, false), (true, false, true), (true, true, true)] {
                    let layout = MediaCardLayout(width: width, showsAuthor: author, showsMetadata: metadata,
                                                 showsDuration: duration, showsPubdate: date)
                    var configuration = ExtendedCoverBackdrop.Configuration(panelAspectRatio: layout.infoHeight / width,
                        titleInsetRatio: (layout.titleFrame.minY + 4 - layout.coverHeight) / width)
                    let firstGlyphY = Int((layout.titleFrame.minY + 4 - layout.extendedBackdropFrame.minY)
                                          / layout.extendedBackdropFrame.height * CGFloat(configuration.pixelHeight))
                    let dark = try XCTUnwrap(ExtendedCoverBackdrop.render(white, configuration: configuration))
                    let darkLuminance = try relativeLuminance(dark, x: dark.width / 2, y: firstGlyphY)
                    XCTAssertGreaterThanOrEqual(1.05 / (darkLuminance + 0.05), 4.5,
                                               "white title on a white cover still needs 4.5:1 contrast")
                    configuration.red = 1; configuration.green = 1; configuration.blue = 1
                    let light = try XCTUnwrap(ExtendedCoverBackdrop.render(black, configuration: configuration))
                    let lightLuminance = try relativeLuminance(light, x: light.width / 2, y: firstGlyphY)
                    XCTAssertGreaterThanOrEqual((lightLuminance + 0.05) / 0.05, 4.5,
                                               "black title on a black cover still needs 4.5:1 contrast")
                }
            }
        }
    }

    private func solidCover(value: UInt8) throws -> CGImage {
        let pixels = [UInt8](repeating: value, count: 640 * 360 * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: 640, height: 360, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
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
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return Array(UnsafeBufferPointer(start: data + offset, count: 4))
    }

    private func relativeLuminance(_ image: CGImage, x: Int, y: Int) throws -> Double {
        let pixel = try rgbaPixel(image, x: x, y: y)
        XCTAssertEqual(pixel[3], 255, "the background behind text must be opaque")
        let linear = pixel.prefix(3).map { value -> Double in
            let channel = Double(value) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
}
