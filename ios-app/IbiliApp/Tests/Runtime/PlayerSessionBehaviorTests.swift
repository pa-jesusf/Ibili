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
}