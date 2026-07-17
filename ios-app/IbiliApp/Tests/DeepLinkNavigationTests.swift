import XCTest
@testable import Ibili

@MainActor
final class DeepLinkNavigationTests: XCTestCase {
    func testRootContentMediaRoutesRoundTripThroughSessionRoutes() {
        let playerID = UUID()
        let item = DeepLinkRouter.makeShell(aid: 10, bvid: "BV10")
        let playerRoute = DeepLinkRouter.PlayerRoute(id: playerID, item: item, offlineOnly: true)

        let playerRootRoute = RootContentRoute(sessionRoute: .player(playerRoute))
        XCTAssertEqual(playerRootRoute.playerRoute?.id, playerID)
        XCTAssertEqual(playerRootRoute.playerRoute?.offlineOnly, true)
        XCTAssertEqual(playerRootRoute.sessionRoute?.id, playerID)

        let liveID = UUID()
        let liveRoute = DeepLinkRouter.LiveRoute(
            id: liveID,
            roomID: 123,
            title: "直播",
            cover: "cover",
            anchorName: "anchor"
        )

        let liveRootRoute = RootContentRoute(sessionRoute: .live(liveRoute))
        XCTAssertEqual(liveRootRoute.liveRoute?.id, liveID)
        XCTAssertEqual(liveRootRoute.liveRoute?.roomID, 123)
        XCTAssertEqual(liveRootRoute.sessionRoute?.id, liveID)
    }

    func testRootContentOpenPlayerDispatchesPushAndReplace() {
        let item = DeepLinkRouter.makeShell(aid: 11, bvid: "BV11")
        var pushedRoute: RootContentRoute?
        var replacedRoute: RootContentRoute?
        let actions = RootContentNavigationActions(
            open: { pushedRoute = $0 },
            replaceCurrent: { replacedRoute = $0 }
        )

        actions.openPlayer(item, offlineOnly: true)
        actions.openPlayer(item, mode: .replaceCurrent)

        XCTAssertEqual(pushedRoute?.playerRoute?.item.bvid, "BV11")
        XCTAssertEqual(pushedRoute?.playerRoute?.offlineOnly, true)
        XCTAssertEqual(replacedRoute?.playerRoute?.item.bvid, "BV11")
        XCTAssertEqual(replacedRoute?.playerRoute?.offlineOnly, false)
    }

    func testReplaceCurrentPlayerPartKeepsSessionButChangesContentIdentity() {
        let router = DeepLinkRouter()
        let first = FeedItemDTO(
            aid: 11,
            bvid: "BV11",
            cid: 101,
            title: "P1",
            cover: "",
            author: "",
            durationSec: 0,
            play: 0,
            danmaku: 0
        )
        let second = FeedItemDTO(
            aid: 11,
            bvid: "BV11",
            cid: 202,
            title: "P2",
            cover: "",
            author: "",
            durationSec: 0,
            play: 0,
            danmaku: 0
        )

        router.open(first)
        let originalRoute = router.path[0]
        let originalIdentity = originalRoute.navigationContentIdentity

        router.open(second, mode: .replaceCurrent)
        let replacementRoute = router.path[0]

        XCTAssertEqual(replacementRoute.id, originalRoute.id)
        XCTAssertNotEqual(replacementRoute.navigationContentIdentity, originalIdentity)
        XCTAssertEqual(replacementRoute.playerRoute?.item.cid, 202)
        XCTAssertTrue(DeepLinkNavigationPathCoordinator.shouldApply(
            displayedPath: [originalRoute],
            routerPath: [originalRoute],
            newPath: [replacementRoute],
            navigationGuard: PlayerPresentationNavigationGuard()
        ))
    }

    func testInitialEmptyNavigationEchoDoesNotClearActiveSession() {
        let router = DeepLinkRouter()
        router.open(DeepLinkRouter.makeShell(aid: 1, bvid: "BV1"))

        let originalIDs = router.path.map(\.id)
        XCTAssertNotNil(router.pending)
        XCTAssertEqual(originalIDs.count, 1)

        let navigationGuard = PlayerPresentationNavigationGuard()
        let shouldApply = DeepLinkNavigationPathCoordinator.shouldApply(
            displayedPath: [],
            routerPath: router.path,
            newPath: [],
            navigationGuard: navigationGuard
        )

        XCTAssertFalse(shouldApply)
        XCTAssertFalse(router.replacePathFromNavigation([]))
        XCTAssertNotNil(router.pending)
        XCTAssertEqual(router.path.map(\.id), originalIDs)
    }

    func testFullscreenExitRejectsForegroundPlayerPathShrink() {
        let router = DeepLinkRouter()
        router.selectUserSpace(mid: 100)
        router.open(DeepLinkRouter.makeShell(aid: 2, bvid: "BV2"))

        let originalPath = router.path
        XCTAssertEqual(originalPath.count, 2)
        XCTAssertNotNil(router.foregroundPlayerRouteID)

        let navigationGuard = PlayerPresentationNavigationGuard()
        navigationGuard.beginNativeFullscreenExitProtection()

        let shouldApply = DeepLinkNavigationPathCoordinator.shouldApply(
            displayedPath: originalPath,
            routerPath: router.path,
            newPath: Array(originalPath.dropLast()),
            navigationGuard: navigationGuard
        )

        XCTAssertFalse(shouldApply)
        XCTAssertEqual(router.path.map(\.id), originalPath.map(\.id))
        XCTAssertEqual(router.foregroundPlayerRouteID, originalPath.last?.id)
    }

    func testFullscreenExitRejectsRootContentForegroundPlayerPathShrink() {
        let item = DeepLinkRouter.makeShell(aid: 3, bvid: "BV3")
        let rootPath: [RootContentRoute] = [
            .userSpace(mid: 100),
            .player(DeepLinkRouter.PlayerRoute(item: item)),
        ]
        let shrunkenPath = Array(rootPath.dropLast())

        let navigationGuard = PlayerPresentationNavigationGuard()
        navigationGuard.beginNativeFullscreenExitProtection()

        XCTAssertFalse(navigationGuard.shouldAcceptPathChange(
            from: rootPath.compactMap(\.sessionRoute),
            to: shrunkenPath.compactMap(\.sessionRoute)
        ))
    }

    func testNormalBackPopStillUpdatesRouterPath() {
        let router = DeepLinkRouter()
        router.selectUserSpace(mid: 100)
        router.openSearch(keyword: "test")

        let rootRoute = router.path[0]
        let navigationGuard = PlayerPresentationNavigationGuard()
        let shouldApply = DeepLinkNavigationPathCoordinator.shouldApply(
            displayedPath: router.path,
            routerPath: router.path,
            newPath: [rootRoute],
            navigationGuard: navigationGuard
        )

        XCTAssertTrue(shouldApply)
        XCTAssertTrue(router.replacePathFromNavigation([rootRoute]))
        XCTAssertEqual(router.path.map(\.id), [rootRoute.id])
        XCTAssertEqual(router.pending?.id, rootRoute.id)
    }

    func testSplitMediaSelectionPublishesStableIdentityBeforeReplacingSession() {
        let router = DeepLinkRouter()
        let item = DeepLinkRouter.makeShell(aid: 42, bvid: "BV42")
        var observed: [(identity: FeedStableIdentity, pendingWasNil: Bool)] = []
        router.onWillSelectMedia = { identity in
            observed.append((identity, router.pending == nil))
        }

        router.select(item)

        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed[0].identity, FeedStableIdentity(item))
        XCTAssertTrue(observed[0].pendingWasNil)
    }

    func testSplitLiveSelectionUsesRoomIdentity() {
        let router = DeepLinkRouter()
        var observed: FeedStableIdentity?
        router.onWillSelectMedia = { observed = $0 }

        router.selectLive(roomID: 7788)

        XCTAssertEqual(observed, FeedStableIdentity(roomID: 7788))
    }
}
