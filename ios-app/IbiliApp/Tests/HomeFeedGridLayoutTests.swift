import XCTest
import Combine
@testable import Ibili

final class HomeFeedGridLayoutTests: XCTestCase {
    func testCollapsedChromeStopsPublishingForDeeperScrollOffsets() {
        let state = FeedChromeScrollState()
        var publishCount = 0
        let cancellable = state.objectWillChange.sink {
            publishCount += 1
        }

        state.update(rawOffset: 100)
        let collapsedPublishCount = publishCount
        state.update(rawOffset: 500)
        state.update(rawOffset: 1_000)

        XCTAssertGreaterThan(collapsedPublishCount, 0)
        XCTAssertEqual(publishCount, collapsedPublishCount)
        withExtendedLifetime(cancellable) {}
    }

    func testTwoColumnGridFitsInsideContainer() {
        let metrics = HomeFeedGridLayoutMetrics(
            containerWidth: 390,
            columns: 2,
            meta: .standard
        )

        XCTAssertEqual(metrics.cardWidth, 177)
        XCTAssertLessThanOrEqual(metrics.cardWidth * 2 + 12 + 24, 390)
    }

    func testFourColumnIPadGridFitsInsideContainer() {
        let metrics = HomeFeedGridLayoutMetrics(
            containerWidth: 1024,
            columns: 4,
            meta: .standard
        )

        XCTAssertEqual(metrics.cardWidth, 241)
        XCTAssertLessThanOrEqual(metrics.cardWidth * 4 + 12 * 3 + 24, 1024)
    }

    func testMetadataConfigurationChangesOnlyCardHeight() {
        let compact = HomeFeedGridLayoutMetrics(
            containerWidth: 390,
            columns: 2,
            meta: FeedCardMetaConfig(
                showPlay: true,
                showDuration: true,
                showPubdate: false,
                showAuthor: false,
                stat: .none
            )
        )
        let detailed = HomeFeedGridLayoutMetrics(
            containerWidth: 390,
            columns: 2,
            meta: .standard
        )

        XCTAssertEqual(compact.cardWidth, detailed.cardWidth)
        XCTAssertLessThan(compact.cardHeight, detailed.cardHeight)
    }
}

@MainActor
final class HomeFeedCollectionLifecycleTests: XCTestCase {
    func testRepeatedSectionConfigurationDoesNotLeaveInvalidCollectionState() {
        let controller = HomeFeedCollectionViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        update(controller, items: makeItems(range: 1...12), isLoading: false, isEnd: false)
        controller.view.layoutIfNeeded()
        update(controller, items: makeItems(range: 20...39), isLoading: true, isEnd: false)
        controller.view.layoutIfNeeded()
        update(controller, items: makeItems(range: 20...39), isLoading: false, isEnd: true)
        controller.view.layoutIfNeeded()
        update(controller, items: makeItems(range: 1...12), isLoading: false, isEnd: false)
        controller.view.layoutIfNeeded()
    }

    private func update(
        _ controller: HomeFeedCollectionViewController,
        items: [FeedItemDTO],
        isLoading: Bool,
        isEnd: Bool
    ) {
        controller.update(
            items: items,
            columns: 2,
            imageQuality: 75,
            meta: .standard,
            usesTopTrailingDuration: false,
            isLoading: isLoading,
            isEnd: isEnd,
            scrollToTopSignal: 0,
            scrollState: FeedChromeScrollState(),
            onRefresh: {},
            onLoadMore: {},
            onOpen: { _ in },
            onTouchDown: { _ in },
            onViewportChanged: { _ in },
            onMenuAction: { _, _ in }
        )
    }

    private func makeItems(range: ClosedRange<Int64>) -> [FeedItemDTO] {
        range.map { value in
            FeedItemDTO(
                aid: value,
                bvid: "BV\(value)",
                cid: value * 10,
                title: "视频 \(value)",
                cover: "",
                author: "UP \(value)",
                durationSec: 120,
                play: value * 100,
                danmaku: value,
                ownerMID: value
            )
        }
    }
}
