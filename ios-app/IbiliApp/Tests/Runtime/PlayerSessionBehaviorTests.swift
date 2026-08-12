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
        state.apply(.pictureInPictureTransition(.started))
        state.apply(.interfaceDeactivated)

        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .play(rate: 1.0))

        state.apply(.pictureInPictureTransition(.stopped(.restored)))

        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .pause)
    }

    func testClosingPictureInPicturePausesEvenWhenPlayerInterfaceIsStillActive() {
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)
        state.apply(.pictureInPictureTransition(.started))

        state.apply(.pictureInPictureTransition(.stopped(.closed)))

        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .pause)
        XCTAssertFalse(state.pictureInPictureIsActive)
    }

    func testRestoringPictureInPicturePreservesPlayingIntent() {
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)
        state.apply(.pictureInPictureTransition(.started))

        state.apply(.pictureInPictureTransition(.stopped(.restored)))

        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .play(rate: 1.0))
        XCTAssertFalse(state.pictureInPictureIsActive)
    }

    func testFailedPictureInPictureStartDoesNotPauseInlinePlayback() {
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)

        state.apply(.pictureInPictureTransition(.stopped(.failedToStart)))

        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .play(rate: 1.0))
    }

    func testLongSuspensionRebuildsPausedRemoteSource() {
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)
        state.apply(.playbackIntentChanged(.pause))

        XCTAssertEqual(
            state.systemTransitionRecoveryAction(
                inactiveDuration: 31,
                engineIsAlive: true,
                sourceIsOffline: false
            ),
            .rebuildSource
        )
    }

    func testBriefSuspensionKeepsPausedRemoteSource() {
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)
        state.apply(.playbackIntentChanged(.pause))

        XCTAssertEqual(
            state.systemTransitionRecoveryAction(
                inactiveDuration: 29,
                engineIsAlive: true,
                sourceIsOffline: false
            ),
            .none
        )
    }

    func testPlayingSourceUsesProgressProbeAfterSuspension() {
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)

        XCTAssertEqual(
            state.systemTransitionRecoveryAction(
                inactiveDuration: 6,
                engineIsAlive: true,
                sourceIsOffline: false
            ),
            .verifyPlaybackProgress
        )
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

    func testSystemPauseDoesNotOverwritePlayingIntentWhileAppIsInactive() {
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)
        state.apply(.systemTransitionChanged(true))

        XCTAssertFalse(state.apply(.observedTimeControlStatus(.paused)))
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .play(rate: 1.0))

        state.apply(.systemTransitionChanged(false))
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .play(rate: 1.0))
    }

    func testExplicitPauseDuringSystemTransitionRemainsPausedOnReturn() {
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)
        state.apply(.systemTransitionChanged(true))
        state.apply(.playbackIntentChanged(.pause))
        state.apply(.systemTransitionChanged(false))

        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .pause)
    }
}
