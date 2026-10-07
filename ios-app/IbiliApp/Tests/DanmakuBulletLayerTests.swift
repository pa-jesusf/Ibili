import CoreGraphics
import QuartzCore
import XCTest
#if os(macOS)
import Metal
#endif
@testable import Ibili

final class DanmakuBulletLayerTests: XCTestCase {
    func testConfigurationPreservesBitmapScaleAndSelfHighlight() throws {
        let bullet = DanmakuBulletLayer()
        let image = try bitmap()
        let size = CGSize(width: 120, height: 24)
        bullet.configure(image: image, size: size, isSelf: true, contentsScale: 3)

        let content = try XCTUnwrap(bullet.sublayers?.first)
        XCTAssertEqual(bullet.sublayers?.count, 1)
        XCTAssertEqual(bullet.bounds.size, size)
        XCTAssertEqual(content.frame, bullet.bounds)
        XCTAssertEqual(content.contentsScale, 3)
        XCTAssertTrue((content.contents as AnyObject?) === image)
        XCTAssertEqual(bullet.borderWidth, 1.2)
        XCTAssertNotNil(bullet.backgroundColor)
    }

    func testReuseClearsOldBitmapAnimationsAndHighlight() throws {
        let root = CALayer()
        let bullet = DanmakuBulletLayer()
        root.addSublayer(bullet)
        bullet.configure(image: try bitmap(), size: CGSize(width: 120, height: 24),
                         isSelf: true, contentsScale: 3)
        let content = try XCTUnwrap(bullet.sublayers?.first)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.duration = 10
        bullet.add(animation, forKey: "bullet")
        content.add(animation, forKey: "content")
        bullet.opacity = 0.2
        bullet.transform = CATransform3DMakeScale(2, 2, 1)
        bullet.prepareForReuse()

        XCTAssertNil(bullet.superlayer)
        XCTAssertNil(content.contents)
        XCTAssertNil(bullet.animationKeys())
        XCTAssertNil(content.animationKeys())
        XCTAssertEqual(bullet.opacity, 1)
        XCTAssertTrue(CATransform3DIsIdentity(bullet.transform))
        XCTAssertNil(bullet.backgroundColor)
        XCTAssertNil(bullet.borderColor)
        XCTAssertEqual(bullet.borderWidth, 0)

        let nextImage = try bitmap()
        bullet.configure(image: nextImage, size: CGSize(width: 80, height: 20),
                         isSelf: false, contentsScale: 2)
        XCTAssertEqual(bullet.sublayers?.count, 1)
        XCTAssertTrue(bullet.sublayers?.first === content)
        XCTAssertTrue((content.contents as AnyObject?) === nextImage)
        XCTAssertEqual(content.frame, bullet.bounds)
        XCTAssertEqual(content.contentsScale, 2)
        XCTAssertEqual(bullet.borderWidth, 0)
    }

    #if os(macOS)
    /// Render offscreen with the system compositor so presentation() actually
    /// invokes Core Animation's copy initializer, as the player's tap does.
    func testAnimatedPresentationPreservesContentAndHitTesting() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 400, height: 200, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let renderer = CARenderer(mtlTexture: texture, options: nil)
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        root.speed = 0
        root.timeOffset = 3
        let bullet = DanmakuBulletLayer()
        let image = try bitmap()
        bullet.configure(image: image, size: CGSize(width: 120, height: 24),
                         isSelf: true, contentsScale: 2)
        bullet.position = CGPoint(x: 60, y: 30)
        root.addSublayer(bullet)
        renderer.layer = root
        renderer.bounds = root.bounds

        let now = CACurrentMediaTime()
        let movement = CABasicAnimation(keyPath: "position.x")
        movement.fromValue = 300
        movement.toValue = 60
        // A zero beginTime is replaced with the commit time by Core Animation.
        movement.beginTime = 1
        movement.duration = 8
        movement.timingFunction = CAMediaTimingFunction(name: .linear)
        bullet.add(movement, forKey: "danmaku.scroll")
        CATransaction.flush()
        renderer.beginFrame(atTime: now, timeStamp: nil)
        renderer.addUpdate(root.bounds)
        renderer.render()
        renderer.endFrame()

        let rootPresentation = try XCTUnwrap(root.presentation())
        for _ in 0..<20 {
            let presentation = try XCTUnwrap(bullet.presentation())
            XCTAssertEqual(presentation.position.x, 240, accuracy: 0.01)
            XCTAssertEqual(presentation.sublayers?.count, 1)
            let content = try XCTUnwrap(presentation.sublayers?.first)
            XCTAssertTrue((content.contents as AnyObject?) === image)
            XCTAssertFalse(content === bullet.sublayers?.first)
            let visiblePoint = CGPoint(x: 240, y: 30)
            XCTAssertTrue(presentation.bounds.contains(
                presentation.convert(visiblePoint, from: rootPresentation)))
            XCTAssertFalse(presentation.bounds.contains(
                presentation.convert(bullet.position, from: rootPresentation)))
        }
        XCTAssertEqual(bullet.sublayers?.count, 1)
        XCTAssertEqual(bullet.position.x, 60)
        renderer.layer = nil
    }
    #endif

    private func bitmap() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 120, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 24))
        return try XCTUnwrap(context.makeImage())
    }
}
