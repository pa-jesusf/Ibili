import AVFoundation
import XCTest
@testable import IbiliPlayerRuntime

final class PlayerSessionBehaviorTests: XCTestCase {

    func testManualPauseDoesNotResumeDuringBackgroundContinuation() {
        var state = PlayerSessionBehaviorState()
        state.activateInterface()

        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .play(rate: 1.0))

        XCTAssertTrue(state.applyObservedTimeControlStatus(.paused))
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .pause)
        XCTAssertNil(state.backgroundContinuationRate(currentRate: 1.0, desiredRate: 1.0))
    }

    func testSuppressedObservedPausePreservesAutoplayIntent() {
        var state = PlayerSessionBehaviorState()
        state.activateInterface()
        state.markMediaReplacementAutoplayIntent()
        state.suppressNextObservedIntent(.pause)

        XCTAssertFalse(state.applyObservedTimeControlStatus(.paused))
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .play(rate: 1.0))
    }

    func testPictureInPictureEventRetainsPlaybackAcrossInterfaceDeactivation() {
        var state = PlayerSessionBehaviorState()

        state.apply(.interfaceActivated)
        state.apply(.pictureInPictureChanged(true))
        state.apply(.interfaceDeactivated)

        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .play(rate: 1.0))

        state.apply(.pictureInPictureChanged(false))

        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .pause)
    }

    func testExplicitPlaybackIntentChangeUpdatesDesiredCommand() {
        var state = PlayerSessionBehaviorState()

        state.apply(.interfaceActivated)
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .play(rate: 1.0))

        state.apply(.playbackIntentChanged(.pause))
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .pause)

        state.apply(.playbackIntentChanged(.play))
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .play(rate: 1.0))
    }

    func testFullscreenTransitionSnapshotDoesNotRestoreAcrossPlayerIdentity() {
        let sourcePlayer = AVPlayer()
        let otherPlayer = AVPlayer()
        let snapshot = PlayerFullscreenTransitionSnapshot(
            playerID: ObjectIdentifier(sourcePlayer),
            wasPlaying: true,
            playbackRate: 1.25
        )

        XCTAssertNil(snapshot.desiredPlaybackCommand(for: otherPlayer))
    }

    func testFullscreenTransitionSnapshotRestoresForOriginalPlayerIdentity() {
        let player = AVPlayer()
        let snapshot = PlayerFullscreenTransitionSnapshot(
            playerID: ObjectIdentifier(player),
            wasPlaying: true,
            playbackRate: 1.5
        )

        XCTAssertEqual(snapshot.desiredPlaybackCommand(for: player), .play(rate: 1.5))
    }

    func testFullscreenPresentationStateTracksActiveSession() {
        let sessionID = PlayerSessionID()
        let player = AVPlayer()
        let identity = PlayerPresentationIdentity(sessionID: sessionID, playerID: ObjectIdentifier(player))
        var state = PlayerPresentationState()

        XCTAssertTrue(state.beginFullscreen(identity))
        XCTAssertTrue(state.isFullscreenPresentationActive)
        XCTAssertFalse(state.isAwaitingInlineFullscreenReturn)
        XCTAssertTrue(state.accepts(identity))

        XCTAssertTrue(state.endFullscreen(identity))
        XCTAssertTrue(state.isFullscreenPresentationActive)
        XCTAssertTrue(state.isAwaitingInlineFullscreenReturn)

        XCTAssertTrue(state.finishFullscreenReturn(identity))
        XCTAssertFalse(state.isFullscreenPresentationActive)
    }

    func testFullscreenPresentationStateRejectsStaleSessionEnd() {
        let activePlayer = AVPlayer()
        let stalePlayer = AVPlayer()
        let activeIdentity = PlayerPresentationIdentity(
            sessionID: PlayerSessionID(),
            playerID: ObjectIdentifier(activePlayer)
        )
        let staleIdentity = PlayerPresentationIdentity(
            sessionID: PlayerSessionID(),
            playerID: ObjectIdentifier(stalePlayer)
        )
        var state = PlayerPresentationState()

        XCTAssertTrue(state.beginFullscreen(activeIdentity))
        XCTAssertFalse(state.endFullscreen(staleIdentity))
        XCTAssertTrue(state.isFullscreenPresentationActive)
        XCTAssertFalse(state.isAwaitingInlineFullscreenReturn)
        XCTAssertFalse(state.accepts(staleIdentity))
    }

    func testFullscreenPresentationStateAllowsNilIncomingPlayerForSameSession() {
        let sessionID = PlayerSessionID()
        let player = AVPlayer()
        let activeIdentity = PlayerPresentationIdentity(sessionID: sessionID, playerID: ObjectIdentifier(player))
        let delegateIdentityDuringDetach = PlayerPresentationIdentity(sessionID: sessionID, playerID: nil)
        var state = PlayerPresentationState()

        XCTAssertTrue(state.beginFullscreen(activeIdentity))

        XCTAssertTrue(state.accepts(delegateIdentityDuringDetach))
        XCTAssertTrue(state.endFullscreen(delegateIdentityDuringDetach))
        XCTAssertTrue(state.isAwaitingInlineFullscreenReturn)
        XCTAssertTrue(state.finishFullscreenReturn(delegateIdentityDuringDetach))
        XCTAssertFalse(state.isFullscreenPresentationActive)
    }
}