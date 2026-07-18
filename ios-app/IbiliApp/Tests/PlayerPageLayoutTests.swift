import XCTest
import UIKit
@testable import Ibili

final class PlayerPageLayoutTests: XCTestCase {
    func testPhoneLandscapeUsesViewportHeightForPlayerAndDetailPages() {
        let metrics = PlayerPageLayoutMetrics(
            viewportSize: CGSize(width: 844, height: 390),
            interfaceIdiom: .phone
        )

        XCTAssertTrue(metrics.usesLandscapePageScroll)
        XCTAssertEqual(metrics.expandedPlayerHeight, 390)
        XCTAssertEqual(metrics.detailViewportHeight(visiblePlayerHeight: 390), 390)
    }

    func testPhonePortraitKeepsExistingFixedPlayerAndDetailViewportLayout() {
        let metrics = PlayerPageLayoutMetrics(
            viewportSize: CGSize(width: 390, height: 844),
            interfaceIdiom: .phone
        )
        let playerHeight = 390 * 9.0 / 16.0

        XCTAssertFalse(metrics.usesLandscapePageScroll)
        XCTAssertEqual(metrics.expandedPlayerHeight, playerHeight, accuracy: 0.001)
        XCTAssertEqual(
            metrics.detailViewportHeight(visiblePlayerHeight: playerHeight),
            844 - playerHeight,
            accuracy: 0.001
        )
    }

    func testIPadLandscapeDoesNotUsePhonePageScrollMode() {
        let metrics = PlayerPageLayoutMetrics(
            viewportSize: CGSize(width: 1194, height: 834),
            interfaceIdiom: .pad
        )

        XCTAssertFalse(metrics.usesLandscapePageScroll)
        XCTAssertEqual(metrics.expandedPlayerHeight, 1194 * 9.0 / 16.0, accuracy: 0.001)
    }
}
