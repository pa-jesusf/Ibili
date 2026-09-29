import XCTest
import UIKit
@testable import Ibili

@MainActor
final class ImagePipelineTests: XCTestCase {
    private func image(width: Int = 48, height: Int = 32) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.magenta.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        XCTFail("expected state was not reached")
    }

    func testDownsampleUsesPixelsAndCacheChargesDecodedBacking() throws {
        let data = try XCTUnwrap(image(width: 1800, height: 900).jpegData(compressionQuality: 0.8))
        let result = try XCTUnwrap(ImagePipeline.downsampleData(data, maxPixelDimension: 300))
        let bitmap = try XCTUnwrap(result.cgImage)
        XCTAssertEqual(bitmap.width, 300)
        XCTAssertEqual(bitmap.height, 150)
        XCTAssertEqual(result.scale, 1)
        XCTAssertEqual(ImageCache.decodedCost(of: result), bitmap.bytesPerRow * bitmap.height)
        XCTAssertGreaterThan(ImageCache.decodedCost(of: result), data.count)
        let url = URL(string: "https://example.invalid/\(UUID())")!
        let cache = ImageCache()
        cache.store(result, for: url, maxPixelDimension: 300)
        XCTAssertNotNil(cache.image(for: url, maxPixelDimension: 300))
        XCTAssertNil(cache.image(for: url, maxPixelDimension: 900))
    }

    func testCancellingOneWaiterKeepsSharedImageRequest() async {
        var pending: CheckedContinuation<UIImage?, Never>?
        var loads = 0
        let pipeline = ImagePipeline { _ in
            loads += 1
            return await withCheckedContinuation { pending = $0 }
        }
        let url = URL(string: "https://example.invalid/\(UUID())")!
        let first = Task { await pipeline.image(for: url, maxPixelDimension: 100) }
        let second = Task { await pipeline.image(for: url, maxPixelDimension: 100) }
        await settle { pending != nil }
        first.cancel()
        let cancelled = await first.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(loads, 1)
        pending?.resume(returning: image())
        let result = await second.value
        XCTAssertNotNil(result)
    }

    func testAllCancelledThenSameKeyReentryIgnoresOldCompletion() async {
        var pending: [CheckedContinuation<UIImage?, Never>] = []
        let pipeline = ImagePipeline { _ in await withCheckedContinuation { pending.append($0) } }
        let url = URL(string: "https://example.invalid/\(UUID())")!
        let first = Task { await pipeline.image(for: url, maxPixelDimension: 100) }
        await settle { pending.count == 1 }
        first.cancel()
        _ = await first.value
        let second = Task { await pipeline.image(for: url, maxPixelDimension: 100) }
        await settle { pending.count == 2 }
        pending[0].resume(returning: image(width: 10))
        pending[1].resume(returning: image(width: 30))
        let result = await second.value
        XCTAssertEqual(result?.cgImage?.width, 30)
        XCTAssertEqual(ImageCache.shared.image(for: url, maxPixelDimension: 100)?.cgImage?.width, 30)
    }

    func testPreviewKeepsCachedThumbnailAndWaitsForFallbackAfterPrimaryFailure() async {
        let primary = URL(string: "https://example.invalid/\(UUID())")!
        let thumbnail = URL(string: "https://example.invalid/\(UUID())")!
        var pending: [URL: CheckedContinuation<UIImage?, Never>] = [:]
        let pipeline = ImagePipeline { request in
            await withCheckedContinuation { pending[request.url] = $0 }
        }
        let loader = CachedRemoteImageLoader(pipeline: pipeline)
        loader.load(url: primary, fallbackURL: thumbnail, fallbackPixelDimension: 160)
        await settle { pending.count == 2 }
        pending[primary]?.resume(returning: nil)
        await Task.yield()
        XCTAssertFalse(loader.failed)
        pending[thumbnail]?.resume(returning: image())
        await settle { loader.image != nil }
        XCTAssertFalse(loader.failed)

        let nextPrimary = URL(string: "https://example.invalid/\(UUID())")!
        loader.load(url: nextPrimary, fallbackURL: thumbnail, fallbackPixelDimension: 160)
        XCTAssertNotNil(loader.image, "already-visible thumbnail must display immediately")
        await settle { pending[nextPrimary] != nil }
        pending[nextPrimary]?.resume(returning: nil)
    }
}
