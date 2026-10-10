import UIKit
import XCTest
@testable import Ibili

@MainActor
final class PlayerDanmakuOverlayTests: XCTestCase {
    func testWindowCameraSafeAreaAppliesEvenWhenAVKitOverlayHasZeroInset() {
        let window = DanmakuTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.cameraInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let canvas = DanmakuCanvasView(), overlay = PlayerDanmakuOverlayView(canvas: canvas)
        overlay.frame = window.bounds
        window.addSubview(overlay)
        overlay.layoutSubviews()
        XCTAssertGreaterThanOrEqual(canvas.frame.minY, 59)
        XCTAssertEqual(canvas.frame.maxY, overlay.bounds.maxY)
        XCTAssertEqual(canvas.frame.width, 390)
        // Returning to an inline player below the system safe area clears the
        // fullscreen offset instead of retaining a fixed phone-specific value.
        overlay.frame = CGRect(x: 0, y: 120, width: 390, height: 220)
        overlay.layoutSubviews()
        XCTAssertEqual(canvas.frame.minY, 0)
        XCTAssertEqual(canvas.frame.height, 220)
    }

    func testRotationAndWindowMigrationRecalculateTheProtectedBoundary() {
        let portrait = DanmakuTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        portrait.cameraInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let canvas = DanmakuCanvasView(), overlay = PlayerDanmakuOverlayView(canvas: canvas)
        portrait.addSubview(overlay)
        overlay.frame = portrait.bounds; overlay.layoutSubviews()
        XCTAssertGreaterThanOrEqual(canvas.frame.minY, 59)
        let landscape = DanmakuTestWindow(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        landscape.cameraInsets = UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)
        landscape.addSubview(overlay)
        overlay.frame = landscape.bounds; overlay.layoutSubviews()
        XCTAssertEqual(canvas.frame.minY, 0)
        XCTAssertEqual(canvas.frame.height, 390)
    }
}

private final class DanmakuTestWindow: UIWindow {
    var cameraInsets: UIEdgeInsets = .zero
    override var safeAreaInsets: UIEdgeInsets { cameraInsets }
}
