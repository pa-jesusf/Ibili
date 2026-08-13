import XCTest
import UIKit
@testable import Ibili

final class PlayerFullscreenOrientationResolverTests: XCTestCase {
    func testLandscapePresentationSizeOverridesPortraitSourceHint() {
        XCTAssertEqual(
            PlayerFullscreenOrientationResolver.contentOrientation(
                presentationSize: CGSize(width: 1920, height: 1080),
                sourceSizeHint: CGSize(width: 1080, height: 1920)
            ),
            .landscape
        )
    }

    func testPortraitPresentationSizeOverridesLandscapeSourceHint() {
        XCTAssertEqual(
            PlayerFullscreenOrientationResolver.contentOrientation(
                presentationSize: CGSize(width: 1080, height: 1920),
                sourceSizeHint: CGSize(width: 1920, height: 1080)
            ),
            .portrait
        )
    }

    func testSourceHintIsUsedWhenPresentationSizeIsInvalid() {
        XCTAssertEqual(
            PlayerFullscreenOrientationResolver.contentOrientation(
                presentationSize: .zero,
                sourceSizeHint: CGSize(width: 1080, height: 1920)
            ),
            .portrait
        )
    }

    func testSquareContentUsesPortrait() {
        XCTAssertEqual(
            PlayerFullscreenOrientationResolver.contentOrientation(
                presentationSize: CGSize(width: 1080, height: 1080),
                sourceSizeHint: nil
            ),
            .portrait
        )
    }

    func testUnknownContentDefaultsToLandscape() {
        XCTAssertEqual(
            PlayerFullscreenOrientationResolver.contentOrientation(
                presentationSize: CGSize(width: CGFloat.nan, height: 1080),
                sourceSizeHint: nil
            ),
            .landscape
        )
    }

    func testLandscapeInitiallyUsesRightOrientation() {
        XCTAssertEqual(
            PlayerFullscreenOrientationResolver.targetMask(for: .landscape),
            .landscapeRight
        )
        XCTAssertEqual(
            PlayerFullscreenOrientationResolver.targetInterfaceOrientation(for: .landscape),
            .landscapeRight
        )
    }

    func testInterfaceOrientationMasksAreExact() {
        XCTAssertEqual(PlayerFullscreenOrientationResolver.mask(for: .portrait), .portrait)
        XCTAssertEqual(PlayerFullscreenOrientationResolver.mask(for: .landscapeLeft), .landscapeLeft)
        XCTAssertEqual(PlayerFullscreenOrientationResolver.mask(for: .landscapeRight), .landscapeRight)
        XCTAssertNil(PlayerFullscreenOrientationResolver.mask(for: .unknown))
    }

    func testDeviceLandscapeOrientationMapsToOppositeInterfaceOrientation() {
        XCTAssertEqual(
            PlayerFullscreenOrientationResolver.interfaceOrientation(for: .landscapeLeft),
            .landscapeRight
        )
        XCTAssertEqual(
            PlayerFullscreenOrientationResolver.interfaceOrientation(for: .landscapeRight),
            .landscapeLeft
        )
        XCTAssertNil(PlayerFullscreenOrientationResolver.interfaceOrientation(for: .faceUp))
    }

    func testPortraitEntryAlwaysRestoresPortrait() {
        XCTAssertEqual(
            PlayerFullscreenOrientationResolver.exitOrientation(
                entryOrientation: .portrait,
                fullscreenOrientation: .landscapeLeft
            ),
            .portrait
        )
    }

    func testLandscapeEntryKeepsLastFullscreenOrientationOnExit() {
        XCTAssertEqual(
            PlayerFullscreenOrientationResolver.exitOrientation(
                entryOrientation: .landscapeRight,
                fullscreenOrientation: .landscapeLeft
            ),
            .landscapeLeft
        )
        XCTAssertEqual(
            PlayerFullscreenOrientationResolver.exitOrientation(
                entryOrientation: .landscapeLeft,
                fullscreenOrientation: .portrait
            ),
            .portrait
        )
    }

    func testInteractiveLeaseAllowsAllNormalOrientations() {
        let token = NSObject()
        let owner = PlayerFullscreenOrientationOwner(
            sessionID: UUID(),
            controllerID: ObjectIdentifier(token),
            sceneID: ObjectIdentifier(token)
        )
        let lease = PlayerFullscreenOrientationLeaseState(
            owner: owner,
            target: .landscapeRight,
            phase: .interactive,
            revision: 1
        )

        XCTAssertEqual(lease.supportedMask, .allButUpsideDown)
    }

    func testEnteringAndRestoringLeasesUseExactTargetMask() {
        let token = NSObject()
        let owner = PlayerFullscreenOrientationOwner(
            sessionID: UUID(),
            controllerID: ObjectIdentifier(token),
            sceneID: ObjectIdentifier(token)
        )

        XCTAssertEqual(
            PlayerFullscreenOrientationLeaseState(
                owner: owner,
                target: .landscapeRight,
                phase: .entering,
                revision: 1
            ).supportedMask,
            .landscapeRight
        )
        XCTAssertEqual(
            PlayerFullscreenOrientationLeaseState(
                owner: owner,
                target: .portrait,
                phase: .restoring,
                revision: 2
            ).supportedMask,
            .portrait
        )
    }
}

final class PlayerFullscreenOrientationLeaseStoreTests: XCTestCase {
    private final class Token {}

    func testStaleOwnerCannotReleaseReplacementLease() {
        let scene = Token()
        let firstController = Token()
        let secondController = Token()
        let first = owner(scene: scene, controller: firstController)
        let second = owner(scene: scene, controller: secondController)
        var store = PlayerFullscreenOrientationLeaseStore()

        store.acquire(owner: first, target: .landscapeRight)
        store.acquire(owner: second, target: .portrait)

        XCTAssertFalse(store.release(owner: first))
        XCTAssertEqual(store.lease(for: second)?.target, .portrait)
    }

    func testDifferentScenesKeepIndependentLeases() {
        let firstScene = Token()
        let secondScene = Token()
        let first = owner(scene: firstScene, controller: Token())
        let second = owner(scene: secondScene, controller: Token())
        var store = PlayerFullscreenOrientationLeaseStore()

        store.acquire(owner: first, target: .landscapeRight)
        store.acquire(owner: second, target: .portrait)

        XCTAssertEqual(store.lease(for: first)?.target, .landscapeRight)
        XCTAssertEqual(store.lease(for: second)?.target, .portrait)
        XCTAssertNil(store.soleLease)
    }

    func testSoleLeaseIsAvailableForWindowlessApplicationQuery() {
        let owner = owner(scene: Token(), controller: Token())
        var store = PlayerFullscreenOrientationLeaseStore()

        store.acquire(owner: owner, target: .landscapeRight)

        XCTAssertEqual(store.soleLease?.owner, owner)
        XCTAssertEqual(store.soleLease?.target, .landscapeRight)
    }

    func testTargetChangeCreatesNewLeaseRevision() {
        let owner = owner(scene: Token(), controller: Token())
        var store = PlayerFullscreenOrientationLeaseStore()

        store.acquire(owner: owner, target: .landscapeRight)
        let landscapeRevision = store.lease(for: owner)?.revision

        store.acquire(owner: owner, target: .portrait)
        XCTAssertNotEqual(store.lease(for: owner)?.revision, landscapeRevision)
    }

    func testPhaseChangeCreatesNewLeaseRevisionWithoutChangingTarget() {
        let owner = owner(scene: Token(), controller: Token())
        var store = PlayerFullscreenOrientationLeaseStore()

        store.acquire(owner: owner, target: .landscapeRight, phase: .entering)
        let enteringRevision = store.lease(for: owner)?.revision

        XCTAssertTrue(
            store.acquire(owner: owner, target: .landscapeRight, phase: .interactive)
        )
        XCTAssertEqual(store.lease(for: owner)?.phase, .interactive)
        XCTAssertNotEqual(store.lease(for: owner)?.revision, enteringRevision)
    }

    func testExitRestoreAndCancelledExitUseFreshExactOrientations() {
        let owner = owner(scene: Token(), controller: Token())
        var store = PlayerFullscreenOrientationLeaseStore()

        store.acquire(owner: owner, target: .landscapeRight)
        let fullscreenRevision = store.lease(for: owner)?.revision
        store.acquire(owner: owner, target: .portrait, phase: .restoring, renew: true)
        let restorationRevision = store.lease(for: owner)?.revision

        XCTAssertEqual(store.lease(for: owner)?.target, .portrait)
        XCTAssertNotEqual(restorationRevision, fullscreenRevision)

        store.acquire(owner: owner, target: .landscapeRight, phase: .interactive, renew: true)
        XCTAssertEqual(store.lease(for: owner)?.target, .landscapeRight)
        XCTAssertEqual(store.lease(for: owner)?.phase, .interactive)
        XCTAssertNotEqual(store.lease(for: owner)?.revision, restorationRevision)
    }

    func testOnlyCurrentOwnerCanMarkLeaseForReleaseAfterRestoration() {
        let scene = Token()
        let staleOwner = owner(scene: scene, controller: Token())
        let currentOwner = owner(scene: scene, controller: Token())
        var store = PlayerFullscreenOrientationLeaseStore()

        store.acquire(owner: staleOwner, target: .landscapeRight)
        store.acquire(owner: currentOwner, target: .portrait)

        XCTAssertFalse(store.markForReleaseWhenTargetIsReached(owner: staleOwner))
        XCTAssertTrue(store.markForReleaseWhenTargetIsReached(owner: currentOwner))
        XCTAssertTrue(store.lease(for: currentOwner)?.releasesWhenTargetIsReached == true)
    }

    func testStaleOwnerCannotUpdateReplacementLease() {
        let scene = Token()
        let first = owner(scene: scene, controller: Token())
        let second = owner(scene: scene, controller: Token())
        var store = PlayerFullscreenOrientationLeaseStore()

        store.acquire(owner: first, target: .landscapeRight)
        store.acquire(owner: second, target: .portrait)

        XCTAssertNil(store.lease(for: first))
        XCTAssertEqual(store.lease(for: second)?.target, .portrait)
    }

    func testReleaseIsIdempotent() {
        let owner = owner(scene: Token(), controller: Token())
        var store = PlayerFullscreenOrientationLeaseStore()
        store.acquire(owner: owner, target: .landscapeRight)

        XCTAssertTrue(store.release(owner: owner))
        XCTAssertFalse(store.release(owner: owner))
        XCTAssertNil(store.lease(for: owner))
    }

    func testCancelledTransitionCanReacquireFreshLease() {
        let owner = owner(scene: Token(), controller: Token())
        var store = PlayerFullscreenOrientationLeaseStore()
        store.acquire(owner: owner, target: .landscapeRight)
        let oldRevision = store.lease(for: owner)?.revision

        XCTAssertTrue(store.release(owner: owner))
        XCTAssertTrue(store.acquire(owner: owner, target: .landscapeRight, renew: true))
        XCTAssertNotEqual(store.lease(for: owner)?.revision, oldRevision)
    }

    private func owner(scene: Token, controller: Token) -> PlayerFullscreenOrientationOwner {
        PlayerFullscreenOrientationOwner(
            sessionID: UUID(),
            controllerID: ObjectIdentifier(controller),
            sceneID: ObjectIdentifier(scene)
        )
    }
}

final class PlayerFullscreenTransitionStateTests: XCTestCase {
    func testSuccessfulEntryAndExit() {
        var state = PlayerFullscreenTransitionState()

        let entry = state.beginEntry()
        XCTAssertTrue(state.finishEntry(revision: entry, cancelled: false))
        XCTAssertTrue(state.isFullscreen)

        let exit = state.beginExit()
        XCTAssertTrue(state.finishExit(revision: exit, cancelled: false))
        XCTAssertEqual(state.phase, .inline)
    }

    func testCancelledEntryReturnsInline() {
        var state = PlayerFullscreenTransitionState()
        let entry = state.beginEntry()

        XCTAssertTrue(state.finishEntry(revision: entry, cancelled: true))
        XCTAssertEqual(state.phase, .inline)
    }

    func testCancelledExitKeepsFullscreenState() {
        var state = PlayerFullscreenTransitionState()
        let entry = state.beginEntry()
        XCTAssertTrue(state.finishEntry(revision: entry, cancelled: false))
        let exit = state.beginExit()

        XCTAssertTrue(state.finishExit(revision: exit, cancelled: true))
        XCTAssertTrue(state.isFullscreen)
    }

    func testStaleEntryCompletionCannotOverrideExit() {
        var state = PlayerFullscreenTransitionState()
        let entry = state.beginEntry()
        let exit = state.beginExit()

        XCTAssertFalse(state.finishEntry(revision: entry, cancelled: false))
        XCTAssertTrue(state.finishExit(revision: exit, cancelled: false))
        XCTAssertEqual(state.phase, .inline)
    }

    func testResetInvalidatesPendingCompletion() {
        var state = PlayerFullscreenTransitionState()
        let entry = state.beginEntry()

        state.reset()

        XCTAssertFalse(state.finishEntry(revision: entry, cancelled: false))
        XCTAssertEqual(state.phase, .inline)
    }
}
