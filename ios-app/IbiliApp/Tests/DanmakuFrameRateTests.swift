import XCTest
import AVFoundation
@testable import Ibili

@MainActor
final class DanmakuFrameRateTests: XCTestCase {
    func testSupportedOptionsIncludeHighRefreshRatesAndDefaultToSixty() {
        XCTAssertEqual(
            DanmakuFrameRateOption.allCases.map(\.rawValue),
            [30, 60, 90, 120]
        )
        XCTAssertEqual(DanmakuFrameRateOption.defaultValue, 60)
        XCTAssertEqual(DanmakuFrameRateOption.resolve(75), 60)
    }

    func testRequestedFrameRateIsCappedByDisplayCapability() {
        XCTAssertEqual(
            DanmakuCanvasView.effectiveFrameRate(
                requested: 120,
                maximumFramesPerSecond: 60
            ),
            60
        )
        XCTAssertEqual(
            DanmakuCanvasView.effectiveFrameRate(
                requested: 90,
                maximumFramesPerSecond: 120
            ),
            90
        )
    }

    func testNormalTrackHeightIsTypographyBoundOnTallPlayers() {
        XCTAssertEqual(
            DanmakuCanvasView.normalTrackHeight(
                containerHeight: 844,
                laneCount: 14,
                fontSize: 18
            ),
            29
        )
    }

    func testNormalTrackHeightStillCompressesOnShortPlayers() {
        XCTAssertEqual(
            DanmakuCanvasView.normalTrackHeight(
                containerHeight: 330,
                laneCount: 14,
                fontSize: 18
            ),
            22
        )
        XCTAssertEqual(
            DanmakuCanvasView.normalTrackHeight(
                containerHeight: 220,
                laneCount: 14,
                fontSize: 18
            ),
            20
        )
    }
}

final class DanmakuLaneAllocatorTests: XCTestCase {
    func testBurstReusesEarliestLaneInsteadOfDroppingDanmaku() {
        var allocator = DanmakuLaneAllocator(laneCount: 2)

        XCTAssertEqual(
            allocator.reserveScrollingLane(at: 10, duration: 8),
            0
        )
        XCTAssertEqual(
            allocator.reserveScrollingLane(at: 10, duration: 8),
            1
        )
        XCTAssertEqual(
            allocator.reserveScrollingLane(at: 10, duration: 8),
            0
        )
    }

    func testTopAndBottomLanesHaveIndependentCapacity() {
        var allocator = DanmakuLaneAllocator(laneCount: 3)

        XCTAssertEqual(
            allocator.reserveTopLane(at: 5, duration: 4),
            0
        )
        XCTAssertEqual(
            allocator.reserveBottomLane(at: 5, duration: 4),
            0
        )
    }
}

@MainActor
final class DanmakuSynchronizedLayerTests: XCTestCase {
    func testDenseBurstMaterializesEveryDanmaku() async throws {
        let canvas = DanmakuCanvasView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        let items = (0..<200).map { index in
            DanmakuItemDTO(
                timeSec: 0,
                mode: 1,
                color: 0xFFFFFF,
                fontSize: 25,
                text: "burst-\(index)"
            )
        }
        canvas.setItems(items)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        canvas.attach(player)
        canvas.layoutIfNeeded()
        await Task.yield()
        await Task.yield()

        let synchronizedLayer = canvas.layer.sublayers?
            .compactMap { $0 as? AVSynchronizedLayer }
            .first
        XCTAssertNotNil(synchronizedLayer)
        let materializedLayers = synchronizedLayer?.sublayers?
            .flatMap { $0.sublayers ?? [] }
            ?? []
        XCTAssertEqual(materializedLayers.count, items.count)
        let movement = materializedLayers.first?
            .animation(forKey: "danmaku.scroll")
        XCTAssertNotNil(movement)
        XCTAssertEqual(movement?.preferredFrameRateRange.preferred, 60)
        let content = try XCTUnwrap(
            materializedLayers.first?.sublayers?.first(where: { $0.contents != nil })
        )
        let image = try XCTUnwrap(content.contents) as! CGImage
        XCTAssertTrue(hasBrightOpaquePixel(in: image))
        canvas.detach()
    }

    func testNormalAndModeSevenBulletsShareSynchronizedTimeline() async throws {
        let canvas = DanmakuCanvasView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        let modeSevenPayload: [Any] = [
            "0.1", "0.1", "1-0.4", 4, "advanced", 0, 0,
            "0.7", "0.6", 1_000, 200, 1, "", 1,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: modeSevenPayload)
        let payloadText = try XCTUnwrap(String(data: payloadData, encoding: .utf8))
        canvas.setItems([
            DanmakuItemDTO(
                timeSec: 0,
                mode: 1,
                color: 0xFFFFFF,
                fontSize: 25,
                text: "normal"
            ),
            DanmakuItemDTO(
                timeSec: 0,
                mode: 7,
                color: 0xFFFFFF,
                fontSize: 25,
                text: payloadText
            ),
        ])
        let player = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        canvas.attach(player)
        canvas.layoutIfNeeded()
        await Task.yield()
        await Task.yield()

        let synchronizedLayer = try XCTUnwrap(
            canvas.layer.sublayers?.compactMap { $0 as? AVSynchronizedLayer }.first
        )
        XCTAssertEqual(synchronizedLayer.sublayers?.count, 2)
        let materializedLayers = synchronizedLayer.sublayers?
            .flatMap { $0.sublayers ?? [] }
            ?? []
        XCTAssertEqual(materializedLayers.count, 2)
        XCTAssertTrue(materializedLayers.contains(where: {
            $0.animation(forKey: "danmaku.special.position") != nil
                && $0.animation(forKey: "danmaku.visibility") != nil
        }))
        let specialLayer = materializedLayers.first(where: {
            $0.animation(forKey: "danmaku.special.position") != nil
        })
        XCTAssertTrue(specialLayer?.sublayers?.contains(where: { $0.contents != nil }) == true)

        canvas.attach(player)
        await Task.yield()
        let attachedAgain = canvas.layer.sublayers?
            .compactMap { $0 as? AVSynchronizedLayer }
            .first
        XCTAssertTrue(attachedAgain === synchronizedLayer)
        canvas.detach()
    }

    private func hasBrightOpaquePixel(in image: CGImage) -> Bool {
        let bytesPerPixel = 4
        let bytesPerRow = image.width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        guard let context = CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        return stride(from: 0, to: pixels.count, by: bytesPerPixel).contains { offset in
            let alpha = pixels[offset + 3]
            let brightestChannel = max(pixels[offset], pixels[offset + 1], pixels[offset + 2])
            return alpha > 32 && brightestChannel > 180
        }
    }
}
