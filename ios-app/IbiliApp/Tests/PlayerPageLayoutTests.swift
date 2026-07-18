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

final class PlayerCollapseScrollTrackerTests: XCTestCase {
    func testCollapseLatchesAfterPausedScrollThreshold() {
        let tracker = PlayerCollapseScrollTracker(
            collapseTriggerDistance: 56,
            topRestoreOverscroll: 36
        )
        _ = tracker.update(offset: 120, pauseEligible: false, isCollapsed: false)
        tracker.pauseBecameEligible()

        XCTAssertNil(tracker.update(offset: 175, pauseEligible: true, isCollapsed: false))
        XCTAssertEqual(
            tracker.update(offset: 176, pauseEligible: true, isCollapsed: false),
            .collapse
        )
    }

    func testCollapsedPlayerIgnoresRememberedPositionAndOnlyExpandsPastTop() {
        let tracker = PlayerCollapseScrollTracker(
            collapseTriggerDistance: 56,
            topRestoreOverscroll: 36
        )

        XCTAssertNil(tracker.update(offset: 120, pauseEligible: true, isCollapsed: true))
        XCTAssertNil(tracker.update(offset: 0, pauseEligible: true, isCollapsed: true))
        XCTAssertNil(tracker.update(offset: -35, pauseEligible: true, isCollapsed: true))
        XCTAssertEqual(
            tracker.update(offset: -36, pauseEligible: true, isCollapsed: true),
            .expandAtTop
        )
    }

    func testPlayingScrollNeverArmsCollapse() {
        let tracker = PlayerCollapseScrollTracker()

        XCTAssertNil(tracker.update(offset: 0, pauseEligible: false, isCollapsed: false))
        XCTAssertNil(tracker.update(offset: 200, pauseEligible: false, isCollapsed: false))
    }
}

final class DynamicLayoutTests: XCTestCase {
    func testCardAndInnerContentWidthsUseDistinctInsets() {
        let cardWidth = DynamicLayout.cardWidth(containerWidth: 390)
        let contentWidth = DynamicLayout.contentWidth(cardWidth: cardWidth)

        XCTAssertEqual(cardWidth, 366)
        XCTAssertEqual(contentWidth, 338)
        XCTAssertEqual(
            contentWidth + DynamicLayout.cardPad * 2 + DynamicLayout.outerPad * 2,
            390
        )
    }
}
