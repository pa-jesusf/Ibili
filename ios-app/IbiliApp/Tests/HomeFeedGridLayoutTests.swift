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
                showDuration: false,
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

    @MainActor
    func testNativeCardKeepsAllTextBelowFullCoverAndClearsBothImagesOnReuse() async throws {
        let payload: [String: Any] = [
            "aid": 1, "bvid": "BV1fk4y1E7r3", "duration_sec": 114,
            "cover": "https://example.invalid/home-card-\(UUID().uuidString).jpg",
            "title": "封面完整保留，标题与信息位于下方",
        ]
        let item = try JSONDecoder().decode(FeedItemDTO.self, from: JSONSerialization.data(withJSONObject: payload))
        let width: CGFloat = 177
        let target = CGSize(width: width, height: width * 9 / 16)
        let url = try XCTUnwrap(URL(string: BiliImageURL.resized(item.cover, pointSize: target, quality: 75)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        ImageCache.shared.store(image, for: url, maxPixelDimension: ImagePipeline.displayPixelDimension(for: target))
        let model = MediaCardRenderModel(feed: item, imageQuality: 75, meta: .standard)
        let cell = HomeFeedCardCell(frame: CGRect(x: 0, y: 0, width: width,
                                                  height: HomeFeedCardCell.preferredHeight(width: width, meta: .standard)))
        cell.configure(item: item, model: model, targetWidth: width, menuAction: { _ in })
        cell.layoutIfNeeded()
        cell.card.layoutIfNeeded()
        let images = cell.card.subviews.compactMap { $0 as? UIImageView }
        let cover = try XCTUnwrap(images.first)
        XCTAssertEqual(cover.frame.height, target.height)
        XCTAssertEqual(cover.contentMode, .scaleAspectFit)
        for label in cell.card.subviews.compactMap({ $0 as? UILabel }) where !label.isHidden {
            XCTAssertGreaterThanOrEqual(label.frame.minY, cover.frame.maxY)
        }
        cell.prepareForReuse()
        await Task.yield()
        XCTAssertNil(images[0].image)
        XCTAssertNil(images[1].image)
        XCTAssertTrue(cell.card.subviews.compactMap { $0 as? UIButton }.allSatisfy { $0.menu == nil })
    }

    @MainActor
    func testCardRowsKeepPlayAboveAuthorAndDoNotOverlapDurationOrMenu() throws {
        let item = try JSONDecoder().decode(FeedItemDTO.self, from: Data(#"{"aid":1,"title":"标题","author":"测试作者","duration_sec":3723,"play":1074000}"#.utf8))
        for width: CGFloat in [82, 90, 110, 150, 159, 177, 366] {
            for author in [false, true] {
                for play in [false, true] {
                    for duration in [false, true] {
                        let meta = FeedCardMetaConfig(showPlay: play, showDuration: duration,
                                                      showPubdate: false, showAuthor: author, stat: .none)
                        let cell = HomeFeedCardCell(frame: CGRect(x: 0, y: 0, width: width,
                                                                  height: HomeFeedCardCell.preferredHeight(width: width, meta: meta)))
                        cell.configure(item: item, model: MediaCardRenderModel(feed: item, imageQuality: 75, meta: meta),
                                       targetWidth: width, menuAction: { _ in })
                        cell.layoutIfNeeded()
                        cell.card.layoutIfNeeded()
                        let menu = try XCTUnwrap(cell.card.subviews.compactMap { $0 as? UIButton }.first)
                        let labels = cell.card.subviews.compactMap({ $0 as? UILabel }).filter { !$0.isHidden }
                        for label in labels {
                            XCTAssertGreaterThan(label.frame.width, 0)
                            XCTAssertFalse(label.frame.intersects(menu.frame))
                            for other in labels where label !== other { XCTAssertFalse(label.frame.intersects(other.frame)) }
                        }
                        if author && play {
                            let authorLabel = try XCTUnwrap(labels.first { $0.text == "测试作者" })
                            let playLabel = try XCTUnwrap(labels.first { $0.attributedText?.string.contains("107.4万") == true })
                            XCTAssertLessThan(playLabel.frame.maxY, authorLabel.frame.minY)
                        }
                        cell.prepareForReuse()
                    }
                }
            }
        }
    }

    @MainActor
    func testSharedLivePresentationRetainsStatsAndUsesSameHeightForEmptyMetadata() throws {
        let populated = try JSONDecoder().decode(LiveFeedItemDTO.self, from: Data(#"{"room_id":123,"title":"直播标题","uname":"主播","watched_label":"3.2万观看","area_name":"聊天","system_cover":"https://example.invalid/cover.jpg","is_followed":true}"#.utf8))
        let empty = try JSONDecoder().decode(LiveFeedItemDTO.self, from: Data(#"{"room_id":456,"title":"直播标题","uname":"主播"}"#.utf8))
        for width: CGFloat in [82, 110, 177, 366] {
            for item in [populated, empty] {
                let model = MediaCardRenderModel(live: item, imageQuality: 75)
                let height = MediaCardContentView.preferredHeight(width: width, model: model)
                XCTAssertEqual(height, LiveCardView.preferredHeight(width: width))
                let card = MediaCardContentView(frame: CGRect(x: 0, y: 0, width: width, height: height))
                card.configure(model: model, targetWidth: width)
                card.layoutIfNeeded()
                XCTAssertFalse(card.isUserInteractionEnabled, "the outer SwiftUI/collection navigation owns taps")
                let labels = card.subviews.compactMap { $0 as? UILabel }.filter { !$0.isHidden }
                let author = try XCTUnwrap(labels.first { $0.text == "主播" })
                XCTAssertEqual(author.frame.maxX, width - (width < 220 ? 10 : 14))
                if item.roomID == populated.roomID {
                    let stats = try XCTUnwrap(labels.first { $0.attributedText?.string.contains("3.2万观看") == true })
                    XCTAssertTrue(stats.attributedText!.string.contains("聊天"))
                    XCTAssertLessThan(stats.frame.maxY, author.frame.minY)
                }
                card.reset()
            }
        }
    }

    @MainActor
    func testCompactVideoCardAllocatesAllThreeConfiguredStatisticsLines() throws {
        let item = try JSONDecoder().decode(FeedItemDTO.self, from: Data(#"{"aid":1,"title":"标题","author":"作者","duration_sec":3723,"play":1074000,"pubdate":1700000000,"danmaku":4321}"#.utf8))
        let meta = FeedCardMetaConfig(showPlay: true, showDuration: true, showPubdate: true, showAuthor: true, stat: .danmaku)
        for width: CGFloat in [82, 110] {
            let model = MediaCardRenderModel(feed: item, imageQuality: nil, meta: meta)
            let card = MediaCardContentView(frame: CGRect(x: 0, y: 0, width: width,
                                                          height: MediaCardContentView.preferredHeight(width: width, meta: meta)))
            XCTAssertEqual(card.bounds.height, MediaCardContentView.preferredHeight(width: width, model: model))
            card.configure(model: model, targetWidth: width)
            card.layoutIfNeeded()
            let stats = try XCTUnwrap(card.subviews.compactMap { $0 as? UILabel }.first {
                $0.attributedText?.string.contains("107.4万") == true
            })
            XCTAssertEqual(stats.attributedText!.string.split(separator: "\n").count, 3)
            XCTAssertEqual(stats.numberOfLines, 3)
            XCTAssertGreaterThanOrEqual(stats.bounds.height, ceil(stats.font.lineHeight * 3))
            card.reset()
        }
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
final class SplitFeedTransitionCoordinatorTests: XCTestCase {
    private final class Source: SplitFeedTransitionSource {
        var canEnter = false
        var canExit = false
        var hiddenStates: [Bool] = []
        var exitRequestCount = 0

        func makeSnapshots(
            direction: SplitFeedTransitionDirection,
            selectedTarget: SplitFeedTransitionTarget?,
            configuration: SplitFeedTransitionConfiguration
        ) -> [SplitFeedCardSnapshot] {
            switch direction {
            case .entering:
                guard canEnter else { return [] }
            case .exiting:
                exitRequestCount += 1
                guard canExit else { return [] }
            }
            return [SplitFeedCardSnapshot(
                view: UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 80)),
                startFrame: CGRect(x: 0, y: 0, width: 100, height: 80),
                endFrame: CGRect(x: 20, y: 20, width: 120, height: 90)
            )]
        }

        func setTransitionCardsHidden(_ hidden: Bool) {
            hiddenStates.append(hidden)
        }
    }

    func testExitFallsBackToCurrentPageWhenEnteringSourceIsNoLongerVisible() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.isHidden = false
        let coordinator = SplitFeedTransitionCoordinator(
            windowProvider: { window },
            animationDuration: 0.01
        )
        let configuration = SplitFeedTransitionConfiguration(
            containerSize: window.bounds.size,
            targetLeftWidth: 500,
            fullColumns: 4,
            splitColumns: 2
        )
        let enteringSource = Source()
        enteringSource.canEnter = true
        coordinator.register(source: enteringSource, configuration: configuration)

        XCTAssertTrue(coordinator.prepareEntering(target: .media(FeedStableIdentity(aid: 1))))
        waitForAnimations()

        let currentPageSource = Source()
        currentPageSource.canExit = true
        coordinator.register(source: currentPageSource, configuration: configuration)

        XCTAssertTrue(coordinator.prepareExiting())
        XCTAssertEqual(enteringSource.exitRequestCount, 1)
        XCTAssertEqual(currentPageSource.exitRequestCount, 1)
        XCTAssertEqual(currentPageSource.hiddenStates.last, true)
        waitForAnimations()
        XCTAssertEqual(currentPageSource.hiddenStates.last, false)
    }

    func testVisibilityRejectsAnOccludedBackgroundPage() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let root = UIViewController()
        root.view.frame = window.bounds
        window.rootViewController = root
        window.isHidden = false
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }

        let backgroundPage = UIView(frame: root.view.bounds)
        let foregroundPage = UIView(frame: root.view.bounds)
        root.view.addSubview(backgroundPage)
        root.view.addSubview(foregroundPage)

        XCTAssertFalse(SplitFeedTransitionVisibility.isVisible(backgroundPage, in: window))
        XCTAssertTrue(SplitFeedTransitionVisibility.isVisible(foregroundPage, in: window))
    }

    private func waitForAnimations() {
        let completed = expectation(description: "transition animation completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
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

    func testRotationResolvesCardWidthFromFinalLayoutAttributes() {
        let controller = HomeFeedCollectionViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }

        update(controller, items: makeItems(range: 1...12), isLoading: false, isEnd: false)
        controller.view.layoutIfNeeded()

        window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        let collectionView = collectionView(in: controller)
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()

        let indexPath = IndexPath(item: 0, section: 0)
        guard let finalWidth = collectionView.collectionViewLayout
            .layoutAttributesForItem(at: indexPath)?.bounds.width else {
            return XCTFail("Expected final home feed layout attributes")
        }
        XCTAssertEqual(controller.cardWidth(at: indexPath), finalWidth, accuracy: 0.5)
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

    func testRetainedCellReceivesLatestProviderWhenDisplayedAgain() {
        let controller = VirtualizedCollectionViewController<Item>()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.rootViewController = nil; window.isHidden = true }
        var configuredTitles: [String] = []
        let content: (Item, CGFloat) -> AnyView = { item, _ in
            configuredTitles.append(item.title)
            return AnyView(Text(item.title))
        }
        let items = makeItems(0..<50)
        let layout = VirtualizedCollectionLayout(height: .absolute(44))
        update(controller, items: items, layout: layout, content: content)
        controller.view.layoutIfNeeded()
        let collection = collectionView(in: controller)
        let path = IndexPath(item: 0, section: 0)
        guard let retained = collection.cellForItem(at: path) else { return XCTFail("missing visible cell") }
        collection.setContentOffset(CGPoint(x: 0, y: 1000), animated: false)
        collection.layoutIfNeeded()
        var changed = items
        changed[0] = Item(id: 0, title: "updated while prefetched")
        update(controller, items: changed, layout: layout, content: content)
        configuredTitles.removeAll()
        controller.collectionView(collection, willDisplay: retained, forItemAt: path)
        XCTAssertTrue(configuredTitles.contains("updated while prefetched"))
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

    func testGridWidthChangeRebuildsVisibleContentWithCurrentWidth() {
        let controller = VirtualizedCollectionViewController<Item>()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 1200))
        window.rootViewController = controller
        window.isHidden = false
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            window.rootViewController = nil
            window.isHidden = true
        }

        let items = makeItems(0..<8)
        var observedWidths: [Int: [CGFloat]] = [:]
        let splitLayout = VirtualizedCollectionLayout.grid(
            columns: 2,
            height: .absolute(180)
        )
        update(
            controller,
            items: items,
            layout: splitLayout,
            content: { item, width in
                observedWidths[item.id, default: []].append(width)
                return AnyView(Text(item.title).frame(width: width))
            }
        )
        controller.view.layoutIfNeeded()

        let expanded = expectation(description: "expanded layout applied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            window.frame = CGRect(x: 0, y: 0, width: 1600, height: 1200)
            controller.view.frame = window.bounds
            let fullLayout = VirtualizedCollectionLayout.grid(
                columns: 4,
                height: .absolute(180)
            )
            self.update(
                controller,
                items: items,
                layout: fullLayout,
                content: { item, width in
                    observedWidths[item.id, default: []].append(width)
                    return AnyView(Text(item.title).frame(width: width))
                }
            )
            controller.view.layoutIfNeeded()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let expectedWidth = fullLayout.itemWidth(containerWidth: window.bounds.width)
                for item in items {
                    guard let lastWidth = observedWidths[item.id]?.last else {
                        XCTFail("Item \(item.id) was not reconfigured after the width change")
                        continue
                    }
                    XCTAssertEqual(
                        lastWidth,
                        expectedWidth,
                        accuracy: 0.5,
                        "Item \(item.id) retained a stale split-mode width"
                    )
                }
                expanded.fulfill()
            }
        }
        wait(for: [expanded], timeout: 1)
    }

    func testListBoundsOnlyRotationRebuildsVisibleContentWithFinalWidth() {
        let controller = VirtualizedCollectionViewController<Item>()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            window.rootViewController = nil
            window.isHidden = true
        }

        let items = makeItems(0..<8)
        let layout = VirtualizedCollectionLayout.list(
            horizontalInset: 12,
            spacing: 14,
            estimatedHeight: 120,
            maximumItemWidth: 608
        )
        var observedWidths: [Int: [CGFloat]] = [:]
        update(
            controller,
            items: items,
            layout: layout,
            content: { item, width in
                observedWidths[item.id, default: []].append(width)
                return AnyView(Text(item.title).frame(width: width, height: 80))
            }
        )
        controller.view.layoutIfNeeded()

        // UIKit can publish one or more intermediate bounds during rotation.
        // Only the final width is allowed to survive the coalesced refresh.
        window.frame = CGRect(x: 0, y: 0, width: 700, height: 534)
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()

        let reconfigured = expectation(description: "final landscape width applied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let expectedWidth = layout.itemWidth(containerWidth: 844)
            let visibleIDs = self.collectionView(in: controller).indexPathsForVisibleItems.map(\.item)
            XCTAssertFalse(visibleIDs.isEmpty)
            for id in visibleIDs {
                guard let lastWidth = observedWidths[id]?.last else {
                    XCTFail("Visible item \(id) was not rebuilt after rotation")
                    continue
                }
                XCTAssertEqual(
                    lastWidth,
                    expectedWidth,
                    accuracy: 0.5,
                    "Visible item \(id) retained its portrait width after a bounds-only rotation"
                )
            }
            reconfigured.fulfill()
        }
        wait(for: [reconfigured], timeout: 1)
    }

    func testStableHeaderVersionSurvivesContentLayoutChanges() {
        let controller = VirtualizedCollectionViewController<Item>()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 1200))
        window.rootViewController = controller
        window.isHidden = false
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            window.rootViewController = nil
            window.isHidden = true
        }

        var headerBuildCount = 0
        let header = {
            headerBuildCount += 1
            return AnyView(Text("Header"))
        }
        let items = makeItems(0..<12)
        update(
            controller,
            items: items,
            layout: .grid(columns: 2, height: .absolute(180)),
            header: header,
            headerVersion: "user-space",
            contentVersion: "archives"
        )
        controller.view.layoutIfNeeded()

        let initialHeader = expectation(description: "initial header configured")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertGreaterThan(headerBuildCount, 0)
            let initialBuildCount = headerBuildCount

            self.update(
                controller,
                items: items,
                layout: .list(spacing: 8, estimatedHeight: 96),
                header: header,
                headerVersion: "user-space",
                contentVersion: "dynamics"
            )
            controller.view.layoutIfNeeded()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                XCTAssertEqual(
                    headerBuildCount,
                    initialBuildCount,
                    "A content-layout switch rebuilt the stable native header"
                )
                initialHeader.fulfill()
            }
        }
        wait(for: [initialHeader], timeout: 1)
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

    func testScrollToBottomSignalAnchorsTheLastItem() {
        let controller = VirtualizedCollectionViewController<Item>()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        window.rootViewController = controller
        window.isHidden = false
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            window.rootViewController = nil
            window.isHidden = true
        }

        let items = makeItems(0..<40)
        let layout = VirtualizedCollectionLayout(
            bottomInset: 8,
            height: .absolute(44)
        )
        update(controller, items: items, layout: layout)
        controller.view.layoutIfNeeded()
        update(
            controller,
            items: items,
            layout: layout,
            scrollToBottomSignal: 1
        )

        let scrolled = expectation(description: "last item anchored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let collectionView = self.collectionView(in: controller)
            collectionView.layoutIfNeeded()
            let distanceToBottom = collectionView.contentSize.height
                + collectionView.adjustedContentInset.bottom
                - collectionView.bounds.height
                - collectionView.contentOffset.y
            XCTAssertLessThanOrEqual(distanceToBottom, 1)
            scrolled.fulfill()
        }
        wait(for: [scrolled], timeout: 1)
    }

    private func update(
        _ controller: VirtualizedCollectionViewController<Item>,
        items: [Item],
        layout: VirtualizedCollectionLayout,
        footerText: String? = nil,
        header: (() -> AnyView)? = nil,
        headerVersion: AnyHashable? = nil,
        showsRefresh: Bool = false,
        isRefreshing: Bool = false,
        scrollToBottomSignal: Int = 0,
        contentVersion: AnyHashable = 0,
        splitIdentity: ((Item) -> FeedStableIdentity?)? = nil,
        splitColumns: ((CGFloat, Int?) -> Int)? = nil,
        splitHeight: ((Item, CGFloat) -> CGFloat?)? = nil,
        content: ((Item, CGFloat) -> AnyView)? = nil
    ) {
        controller.update(
            items: items,
            layout: layout,
            header: header,
            headerVersion: headerVersion,
            footer: footerText.map { text in { AnyView(Text(text)) } },
            showsRefresh: showsRefresh,
            isRefreshing: isRefreshing,
            scrollToTopSignal: 0,
            scrollToBottomSignal: scrollToBottomSignal,
            scrollToBottomAnimated: false,
            bottomProximity: 36,
            prefetchThreshold: 4,
            scrollState: nil,
            onRefresh: {},
            onLoadMore: {},
            onOpen: nil,
            onPrefetch: { _, _ in },
            onViewportChanged: { _ in },
            onScrollOffsetChanged: { _ in },
            onBottomStateChanged: { _ in },
            splitTransitionCoordinator: nil,
            splitTransitionConfiguration: nil,
            splitTransitionIdentity: splitIdentity,
            splitTransitionTargets: nil,
            splitTransitionColumns: splitColumns,
            splitTransitionHeight: splitHeight,
            contentVersion: contentVersion,
            content: content ?? { item, _ in AnyView(Text(item.title)) }
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

    func testSplitSnapshotsUseDestinationColumnsForWidthAndHeight() {
        verifySplitSnapshots(fullColumns: 4, splitColumns: 2,
                             enteringWidth: 241, exitingWidth: 241)
    }

    func testSingleColumnSplitSnapshotsIgnoreGlobalFeedColumns() {
        verifySplitSnapshots(fullColumns: 1, splitColumns: 1,
                             enteringWidth: 494, exitingWidth: 1000)
    }

    func testUserSearchSplitSnapshotsUseItsOwnResponsiveColumns() {
        verifySplitSnapshots(fullColumns: 2, splitColumns: 1,
                             enteringWidth: 494, exitingWidth: 494,
                             columnResolver: { width, limit in
                                 SearchResultType.user.columnCount(width: width, preferredColumns: 4, columnLimit: limit)
                             })
    }

    private func verifySplitSnapshots(
        fullColumns: Int,
        splitColumns: Int,
        enteringWidth: CGFloat,
        exitingWidth: CGFloat,
        columnResolver: ((CGFloat, Int?) -> Int)? = nil
    ) {
        let controller = VirtualizedCollectionViewController<Item>()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = controller
        window.isHidden = false
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            window.rootViewController = nil
            window.isHidden = true
        }
        let items = makeItems(0..<12)
        let identity: (Item) -> FeedStableIdentity? = { FeedStableIdentity(aid: Int64($0.id + 1)) }
        let height: (Item, CGFloat) -> CGFloat? = { _, width in
            MediaCardLayout(width: width, showsAuthor: true, showsMetadata: true, showsDuration: true).height
        }
        update(controller, items: items, layout: .grid(columns: fullColumns, height: .absolute(256)),
               splitIdentity: identity, splitColumns: columnResolver, splitHeight: height)
        controller.view.layoutIfNeeded()
        let ready = expectation(description: "split source cells displayed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            controller.view.layoutIfNeeded()
            let configuration = SplitFeedTransitionConfiguration(containerSize: window.bounds.size, targetLeftWidth: 518,
                                                                  fullColumns: 4, splitColumns: 2)
            let entering = controller.makeSnapshots(direction: .entering, selectedTarget: .media(FeedStableIdentity(aid: 1)),
                                                     configuration: configuration)
            XCTAssertFalse(entering.isEmpty)
            for snapshot in entering {
                XCTAssertEqual(snapshot.endFrame.width, enteringWidth)
                XCTAssertEqual(snapshot.endFrame.height, height(items[0], enteringWidth))
            }
            controller.view.frame.size.width = 518
            self.update(controller, items: items, layout: .grid(columns: splitColumns, height: .absolute(256)),
                        splitIdentity: identity, splitColumns: columnResolver, splitHeight: height)
            controller.view.layoutIfNeeded()
            let exiting = controller.makeSnapshots(direction: .exiting, selectedTarget: nil, configuration: configuration)
            XCTAssertFalse(exiting.isEmpty)
            for snapshot in exiting {
                XCTAssertEqual(snapshot.endFrame.width, exitingWidth)
                XCTAssertEqual(snapshot.endFrame.height, height(items[0], exitingWidth))
            }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 1)
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
