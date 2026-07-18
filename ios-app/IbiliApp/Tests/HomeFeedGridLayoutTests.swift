import XCTest
import Combine
import SwiftUI
import UIKit
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

    func testSplitGeometryKeepsSelectedCardAtSameVerticalAnchor() {
        let geometry = SplitFeedGridGeometry(
            columns: 2,
            itemWidth: 241,
            itemHeight: 220,
            horizontalInset: 12,
            interitemSpacing: 12,
            rowSpacing: 14
        )

        let selectedFrame = geometry.frame(
            for: 7,
            anchorIndex: 7,
            anchorScreenY: 286
        )
        let followingFrame = geometry.frame(
            for: 9,
            anchorIndex: 7,
            anchorScreenY: 286
        )

        XCTAssertEqual(selectedFrame.minY, 286)
        XCTAssertEqual(followingFrame.minY, 520)
        XCTAssertEqual(selectedFrame.minX, 265)
    }

    func testSplitGeometryChoosesTopRightVisibleCardForExitAnchor() {
        let frames: [(index: Int, frame: CGRect)] = [
            (6, CGRect(x: 12, y: 100, width: 200, height: 180)),
            (7, CGRect(x: 224, y: 100, width: 200, height: 180)),
            (8, CGRect(x: 12, y: 294, width: 200, height: 180)),
        ]

        XCTAssertEqual(SplitFeedGridGeometry.topRightIndex(in: frames), 7)
    }

    func testSplitAnchorOffsetIsClampedToScrollableRange() {
        XCTAssertEqual(
            SplitFeedGridGeometry.contentOffsetY(
                anchorContentY: 900,
                anchorScreenY: 300,
                collectionScreenMinY: 80,
                minimumY: -64,
                maximumY: 620
            ),
            620
        )
    }
}

@MainActor
final class HomeFeedCollectionLifecycleTests: XCTestCase {
    func testRefreshControlIsDetachedUntilHomeFeedHasContent() {
        let controller = HomeFeedCollectionViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        update(controller, items: [], isLoading: true, isEnd: false)
        XCTAssertNil(collectionView(in: controller).refreshControl)

        update(controller, items: makeItems(range: 1...4), isLoading: false, isEnd: false)
        XCTAssertNotNil(collectionView(in: controller).refreshControl)
    }

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

    private func collectionView(in controller: HomeFeedCollectionViewController) -> UICollectionView {
        guard let collectionView = controller.view.subviews.compactMap({ $0 as? UICollectionView }).first else {
            XCTFail("Expected home collection view")
            return UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        }
        return collectionView
    }
}

@MainActor
final class VirtualizedCollectionLifecycleTests: XCTestCase {
    private struct Item: Identifiable, Hashable {
        let id: Int
        let title: String
    }

    func testSingleColumnMaximumWidthKeepsFullWidthScrollSurface() {
        let layout = VirtualizedCollectionLayout.list(
            horizontalInset: 16,
            maximumItemWidth: 608
        )

        XCTAssertEqual(layout.itemWidth(containerWidth: 1024), 608)
        XCTAssertEqual(layout.resolvedHorizontalInset(containerWidth: 1024), 208)
        XCTAssertEqual(layout.itemWidth(containerWidth: 430), 398)
        XCTAssertEqual(layout.resolvedHorizontalInset(containerWidth: 430), 16)
    }

    func testRepeatedGridAndListUpdatesKeepStableCollectionState() {
        let controller = VirtualizedCollectionViewController<Item>()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)

        update(controller, items: makeItems(0..<40), layout: .grid(columns: 4, height: .absolute(180)))
        controller.view.layoutIfNeeded()
        update(
            controller,
            items: makeItems(0..<40),
            layout: .grid(columns: 2, height: .absolute(220)),
            footerText: "加载中"
        )
        controller.view.layoutIfNeeded()
        update(controller, items: makeItems(20..<60), layout: .list(spacing: 8, estimatedHeight: 96))
        controller.view.layoutIfNeeded()
    }

    func testRefreshControlIsOnlyAttachedWhenRefreshableContentExists() throws {
        let controller = VirtualizedCollectionViewController<Item>()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.isHidden = false
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            window.rootViewController = nil
            window.isHidden = true
        }

        update(controller, items: [], layout: .list(), showsRefresh: true)
        XCTAssertNil(collectionView(in: controller).refreshControl)

        update(controller, items: makeItems(0..<4), layout: .list(), showsRefresh: true)
        let refreshControl = try XCTUnwrap(collectionView(in: controller).refreshControl)
        refreshControl.beginRefreshing()

        update(
            controller,
            items: makeItems(0..<4),
            layout: .list(),
            showsRefresh: true,
            isRefreshing: true
        )
        XCTAssertTrue(refreshControl.isRefreshing)

        update(controller, items: makeItems(0..<4), layout: .list(), showsRefresh: true)
        XCTAssertFalse(refreshControl.isRefreshing)

        update(controller, items: [], layout: .list(), showsRefresh: true)
        XCTAssertNil(collectionView(in: controller).refreshControl)
    }

    private func update(
        _ controller: VirtualizedCollectionViewController<Item>,
        items: [Item],
        layout: VirtualizedCollectionLayout,
        footerText: String? = nil,
        showsRefresh: Bool = false,
        isRefreshing: Bool = false
    ) {
        controller.update(
            items: items,
            layout: layout,
            header: nil,
            footer: footerText.map { text in { AnyView(Text(text)) } },
            showsRefresh: showsRefresh,
            isRefreshing: isRefreshing,
            scrollToTopSignal: 0,
            prefetchThreshold: 4,
            scrollState: nil,
            onRefresh: {},
            onLoadMore: {},
            onOpen: nil,
            onPrefetch: { _, _ in },
            onViewportChanged: { _ in },
            onScrollOffsetChanged: { _ in },
            splitTransitionCoordinator: nil,
            splitTransitionConfiguration: nil,
            splitTransitionIdentity: nil,
            splitTransitionTargets: nil,
            splitTransitionHeight: nil,
            contentVersion: 0,
            content: { item, _ in AnyView(Text(item.title)) }
        )
    }

    private func makeItems(_ range: Range<Int>) -> [Item] {
        range.map { Item(id: $0, title: "Item \($0)") }
    }

    private func collectionView(in controller: VirtualizedCollectionViewController<Item>) -> UICollectionView {
        guard let collectionView = controller.view.subviews.compactMap({ $0 as? UICollectionView }).first else {
            XCTFail("Expected virtualized collection view")
            return UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        }
        return collectionView
    }

    func testDiffableCoordinatorKeepsLatestRapidSnapshot() {
        enum Section: Hashable { case content }
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        let dataSource = UICollectionViewDiffableDataSource<Section, Int>(collectionView: collectionView) {
            _, _, _ in UICollectionViewCell()
        }
        let coordinator = DiffableSnapshotCoordinator<Section, Int>()

        for count in 1...20 {
            var snapshot = NSDiffableDataSourceSnapshot<Section, Int>()
            snapshot.appendSections([.content])
            snapshot.appendItems(Array(0..<count))
            coordinator.apply(snapshot, to: dataSource)
        }

        let applied = expectation(description: "latest snapshot applied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(dataSource.snapshot().itemIdentifiers, Array(0..<20))
            applied.fulfill()
        }
        wait(for: [applied], timeout: 1)
    }
}
