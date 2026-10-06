import CoreGraphics
import Foundation
import XCTest
@testable import Ibili

final class ArtworkBackdropTests: XCTestCase {
    func testHorizontalSurfaceUsesWholeCoverPaletteAndKeepsReadableTextOpaque() throws {
        let cover = try image(width: 160, height: 100) { x, _ in x < 80 ? (0, 0, 255) : (255, 0, 0) }
        let artwork = [ExtendedCoverBackdrop.Artwork(image: cover, frame: CGRect(x: 4, y: 8, width: 120, height: 75))]
        for background: CGFloat in [0, 1] {
            let config = configuration(width: 366, height: 100, style: .trailing, background: background)
            let result = try XCTUnwrap(ExtendedCoverBackdrop.renderSurface(artwork, configuration: config))
            let edge = try pixel(result, x: Int(150 * config.scale), y: Int(45 * config.scale))
            XCTAssertEqual(Int(edge[0]), Int(edge[2]), accuracy: 2, "both halves contribute; the right edge isn't copied")
            if background == 0 { XCTAssertGreaterThan(edge[0], edge[1]) }
            XCTAssertEqual(edge[3], 255)
            let luminance = relativeLuminance(edge)
            let contrast = background == 0 ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05
            XCTAssertGreaterThan(contrast, 4.5)
            for x in [0, result.width - 1] {
                for y in [0, result.height - 1] { XCTAssertEqual(try pixel(result, x: x, y: y)[3], 255) }
            }
        }
    }

    func testGridColorsFollowActualTileOrderIncludingIncompleteLastRow() throws {
        let red = try image { _, _ in (255, 0, 0) }
        let blue = try image { _, _ in (0, 0, 255) }
        let green = try image { _, _ in (0, 255, 0) }
        let left = CGRect(x: 16, y: 100, width: 164, height: 164)
        let right = CGRect(x: 184, y: 100, width: 164, height: 164)
        let bottom = CGRect(x: 16, y: 268, width: 164, height: 164)
        let config = configuration(width: 364, height: 484, style: .ambient)
        func rendered(swapped: Bool) throws -> CGImage {
            try XCTUnwrap(ExtendedCoverBackdrop.renderSurface([
                .init(image: swapped ? blue : red, frame: left),
                .init(image: swapped ? red : blue, frame: right),
                .init(image: green, frame: bottom),
            ], configuration: config))
        }
        let normal = try rendered(swapped: false)
        let swapped = try rendered(swapped: true)
        let leftTint = try pixel(normal, x: Int(55 * config.scale), y: Int(150 * config.scale))
        let rightTint = try pixel(normal, x: Int(310 * config.scale), y: Int(150 * config.scale))
        let lowerTint = try pixel(normal, x: Int(55 * config.scale), y: Int(400 * config.scale))
        XCTAssertGreaterThan(leftTint[0], leftTint[2])
        XCTAssertGreaterThan(rightTint[2], rightTint[0])
        XCTAssertGreaterThan(lowerTint[1], lowerTint[0])
        let swappedLeft = try pixel(swapped, x: Int(55 * config.scale), y: Int(150 * config.scale))
        XCTAssertGreaterThan(swappedLeft[2], swappedLeft[0], "changing grid positions must change the corresponding background")
        for x in [0, normal.width - 1] {
            for y in [0, normal.height - 1] { XCTAssertEqual(try pixel(normal, x: x, y: y)[3], 255) }
        }
    }

    func testSurfaceCacheSeparatesThemeAndAxisAndBoundsTallPosts() throws {
        let cover = try image { _, _ in (255, 0, 0) }
        let artwork = [ExtendedCoverBackdrop.Artwork(image: cover, frame: CGRect(x: 16, y: 80, width: 220, height: 260))]
        let key = UUID().uuidString
        let dark = configuration(width: 252, height: 390, style: .ambient)
        let first = try XCTUnwrap(ExtendedCoverBackdrop.surface(for: artwork, cacheKey: key, configuration: dark))
        let second = try XCTUnwrap(ExtendedCoverBackdrop.surface(for: artwork, cacheKey: key, configuration: dark))
        XCTAssertTrue(first === second)
        let light = try XCTUnwrap(ExtendedCoverBackdrop.surface(for: artwork, cacheKey: key,
                    configuration: configuration(width: 252, height: 390, style: .ambient, background: 1)))
        let horizontal = try XCTUnwrap(ExtendedCoverBackdrop.surface(for: artwork, cacheKey: key,
                    configuration: configuration(width: 252, height: 390, style: .trailing)))
        XCTAssertFalse(first === light)
        XCTAssertFalse(first === horizontal)
        XCTAssertGreaterThan(try pixel(light, x: 20, y: 20)[1], try pixel(first, x: 20, y: 20)[1])
        let tall = try XCTUnwrap(ExtendedCoverBackdrop.renderSurface(artwork,
                    configuration: configuration(width: 300, height: 4000, style: .ambient)))
        XCTAssertLessThanOrEqual(tall.width, 384)
        XCTAssertLessThanOrEqual(tall.height, 768)
        XCTAssertLessThanOrEqual(tall.bytesPerRow * tall.height, 384 * 768 * 4)
        XCTAssertNil(ExtendedCoverBackdrop.renderSurface([], configuration: dark))
    }

    func testTransparentArtworkCompositesIntoOpaqueThemedSurface() throws {
        let translucent = try image(alpha: 128) { _, _ in (255, 0, 0) }
        let artwork = [ExtendedCoverBackdrop.Artwork(image: translucent, frame: CGRect(x: 4, y: 8, width: 120, height: 75))]
        for style in [ExtendedCoverBackdrop.SurfaceStyle.ambient, .trailing] {
            for background: CGFloat in [0, 1] {
                let result = try XCTUnwrap(ExtendedCoverBackdrop.renderSurface(artwork,
                    configuration: configuration(width: 366, height: 100, style: style, background: background)))
                for x in [0, result.width / 2, result.width - 1] {
                    for y in [0, result.height / 2, result.height - 1] {
                        XCTAssertEqual(try pixel(result, x: x, y: y)[3], 255)
                    }
                }
            }
        }
    }

    func testHorizontalSurfaceDiscardsImagePatterns() throws {
        let stripes = try image { x, _ in (x / 8).isMultiple(of: 2) ? (0, 0, 0) : (255, 255, 255) }
        let horizontalStripes = try image { _, y in (y / 5).isMultiple(of: 2) ? (0, 0, 0) : (255, 255, 255) }
        let config = configuration(width: 366, height: 100, style: .trailing)
        func render(_ image: CGImage) throws -> CGImage {
            try XCTUnwrap(ExtendedCoverBackdrop.renderSurface([
                .init(image: image, frame: CGRect(x: 4, y: 8, width: 120, height: 75)),
            ], configuration: config))
        }
        let vertical = try render(stripes)
        let horizontal = try render(horizontalStripes)
        for x in [140, 180, 240, 350] {
            let values = try [10, 45, 90].map { y in
                try pixel(vertical, x: Int(CGFloat(x) * config.scale), y: Int(CGFloat(y) * config.scale))[0]
            }
            XCTAssertLessThanOrEqual(Int(values.max()!) - Int(values.min()!), 2)
            XCTAssertEqual(Int(try pixel(vertical, x: Int(CGFloat(x) * config.scale), y: 30)[0]),
                           Int(try pixel(horizontal, x: Int(CGFloat(x) * config.scale), y: 30)[0]), accuracy: 2,
                           "changing stripe direction must not change a color-only background")
        }
    }

    func testDynamicArtworkKeepsSoftTintWhileFadingAwayFromImages() throws {
        let cover = try image { _, _ in (160, 125, 70) }
        let config = configuration(width: 371, height: 403, style: .ambient, background: 0.11)
        let output = try XCTUnwrap(ExtendedCoverBackdrop.renderSurface([
            .init(image: cover, frame: CGRect(x: 21, y: 161, width: 328, height: 184)),
        ], configuration: config))
        let center = output.width / 2
        // The exposed heading gradually gains the image's color as it approaches
        // the photo; a uniformly sampled card would fail this comparison.
        let heading = try [0, 20, 50, 80, 110, 140, 155].map { y in
            try pixel(output, x: center, y: Int(CGFloat(y) * config.scale))
        }
        for (farther, nearer) in zip(heading, heading.dropFirst()) {
            XCTAssertLessThanOrEqual(Int(farther[0]), Int(nearer[0]) + 2)
        }
        XCTAssertGreaterThan(Int(heading.last![0]) - Int(heading.first![0]), 18)
        XCTAssertGreaterThan(Int(heading.last![0]) - Int(heading.last![2]), 10)
        for (x, y) in [(0, output.height / 2), (output.width - 1, output.height / 2),
                       (center, 0), (center, output.height - 1)] {
            let edge = try pixel(output, x: x, y: y)
            XCTAssertGreaterThan(edge[0], 30, "outside edges retain the artwork tint instead of turning black")
            XCTAssertGreaterThan(Int(edge[0]) - Int(edge[2]), 2)
            XCTAssertEqual(edge[3], 255)
        }
        let middle = try pixel(output, x: center, y: output.height / 2)
        for x in [0, output.width - 1] {
            let side = try pixel(output, x: x, y: output.height / 2)
            XCTAssertEqual(Int(side[0]), Int(middle[0]), accuracy: 2, "no extra dark rim along the side edges")
        }
        for color in heading { XCTAssertGreaterThan(1.05 / (relativeLuminance(color) + 0.05), 4.5) }
        let actions = try pixel(output, x: center, y: Int(365 * config.scale))
        XCTAssertGreaterThan(Int(actions[0]) - Int(actions[2]), 5, "the transition also reaches below the photo")
    }

    func testDynamicArtworkKeepsSpatialColorsInsteadOfOneAverage() throws {
        let cover = try image(width: 320, height: 180) { x, _ in x < 160 ? (255, 0, 0) : (0, 0, 255) }
        for background: CGFloat in [0, 1] {
            let config = configuration(width: 360, height: 350, style: .ambient, background: background)
            let output = try XCTUnwrap(ExtendedCoverBackdrop.renderSurface([
                .init(image: cover, frame: CGRect(x: 20, y: 100, width: 320, height: 180)),
            ], configuration: config))
            let left = try pixel(output, x: Int(70 * config.scale), y: Int(85 * config.scale))
            let right = try pixel(output, x: Int(290 * config.scale), y: Int(85 * config.scale))
            XCTAssertGreaterThan(Int(left[0]) - Int(left[2]), 12)
            XCTAssertGreaterThan(Int(right[2]) - Int(right[0]), 12)
            for color in [left, right] {
                let luminance = relativeLuminance(color)
                let contrast = background == 0 ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05
                XCTAssertGreaterThan(contrast, 4.5)
                XCTAssertEqual(color[3], 255)
            }
        }
    }

    func testSquareTileSamplesVisibleCropAndSkipsTransparentArtwork() throws {
        let cover = try image(width: 300, height: 100) { x, _ in
            (100..<200).contains(x) ? (0, 0, 255) : (255, 0, 0)
        }
        let config = configuration(width: 200, height: 250, style: .ambient)
        let output = try XCTUnwrap(ExtendedCoverBackdrop.renderSurface([
            .init(image: cover, frame: CGRect(x: 20, y: 60, width: 160, height: 160)),
        ], configuration: config))
        let color = try pixel(output, x: output.width / 2, y: 10)
        XCTAssertGreaterThan(color[2], color[0], "cropped-out red edges must not color a visible blue square")
        let clear = try image(alpha: 0) { _, _ in (255, 0, 0) }
        XCTAssertNil(ExtendedCoverBackdrop.renderSurface([
            .init(image: clear, frame: CGRect(x: 20, y: 60, width: 160, height: 160)),
        ], configuration: config))
    }

    private func configuration(width: CGFloat, height: CGFloat, style: ExtendedCoverBackdrop.SurfaceStyle,
                               background: CGFloat = 0) -> ExtendedCoverBackdrop.SurfaceConfiguration {
        .init(width: width, height: height, style: style, red: background, green: background, blue: background)
    }

    private func image(width: Int = 160, height: Int = 100, alpha: UInt8 = 255,
                       color: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = color(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(Int(rgb.0) * Int(alpha) / 255)
                bytes[offset + 1] = UInt8(Int(rgb.1) * Int(alpha) / 255)
                bytes[offset + 2] = UInt8(Int(rgb.2) * Int(alpha) / 255)
                bytes[offset + 3] = alpha
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes + (y * image.width + x) * 4, count: 4))
    }

    private func relativeLuminance(_ pixel: [UInt8]) -> Double {
        let linear = pixel.prefix(3).map { value -> Double in
            let channel = Double(value) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
}
