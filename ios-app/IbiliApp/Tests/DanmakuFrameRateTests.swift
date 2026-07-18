import XCTest
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
}
