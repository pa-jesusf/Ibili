import XCTest
@testable import Ibili

final class ImageZoomGeometryTests: XCTestCase {
    func testCentersSmallAxisAndFitsPortraitAndLandscape() {
        let size = ImageZoomGeometry.fittedSize(image: CGSize(width: 1000, height: 2000), viewport: CGSize(width: 400, height: 800))
        XCTAssertEqual(size, CGSize(width: 400, height: 800))
        let wide = ImageZoomGeometry.fittedSize(image: CGSize(width: 2000, height: 1000), viewport: CGSize(width: 400, height: 800))
        XCTAssertEqual(wide, CGSize(width: 400, height: 200))
        XCTAssertEqual(ImageZoomGeometry.centeringInset(content: wide, viewport: CGSize(width: 400, height: 800)), CGPoint(x: 0, y: 300))
        XCTAssertEqual(ImageZoomGeometry.centeringInset(content: CGSize(width: 1000, height: 1000), viewport: CGSize(width: 400, height: 800)), .zero)
    }
}
