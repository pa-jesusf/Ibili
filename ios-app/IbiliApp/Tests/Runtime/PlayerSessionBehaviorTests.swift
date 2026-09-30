import XCTest
#if canImport(IbiliPlayerRuntime)
@testable import IbiliPlayerRuntime
#else
@testable import Ibili
#endif

final class PlayerSessionBehaviorTests: XCTestCase {

    func testBufferingRecoveryStillRequestsSystemMediaSynchronization() {
        var state = PlayerSessionBehaviorState()
        state.activateInterface()
        state.apply(.interfaceDidAppear)
        state.suppressNextObservedIntent(.play)
        XCTAssertFalse(state.apply(.observedTimeControlStatus(.playing)))
        // These observations also synchronize actual elapsed time. Equal
        // play intent must not suppress the waiting → playing transition.
        XCTAssertTrue(state.apply(.observedTimeControlStatus(.waitingToPlayAtSpecifiedRate)))
        XCTAssertTrue(state.apply(.observedTimeControlStatus(.playing)))
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 2), .play(rate: 2))
        XCTAssertTrue(state.apply(.observedTimeControlStatus(.paused)))
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 2), .pause)
    }

    func testManualPauseDoesNotResumeDuringBackgroundContinuation() {
        var state = PlayerSessionBehaviorState()
        state.activateInterface()
        state.apply(.interfaceDidAppear)

        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .play(rate: 1.0))

        XCTAssertTrue(state.applyObservedTimeControlStatus(.paused))
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1.0), .pause)
        XCTAssertFalse(state.shouldHoldAudioSession)
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

    func testPlayingSourceProbesAfterShortRecoveryWindow() {
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)

        XCTAssertEqual(
            state.systemTransitionRecoveryAction(
                inactiveDuration: 2.1,
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

    func testReturningToForegroundRestoresTheIntentCapturedBeforeNavigation() {
        var playing = PlayerSessionBehaviorState()
        playing.apply(.interfaceActivated)
        playing.apply(.interfaceDeactivated)
        XCTAssertEqual(playing.desiredPlaybackCommand(rate: 1.0), .pause)
        playing.apply(.interfaceActivated)
        XCTAssertEqual(playing.desiredPlaybackCommand(rate: 1.0), .play(rate: 1.0))

        var paused = PlayerSessionBehaviorState()
        paused.apply(.interfaceActivated)
        paused.apply(.playbackIntentChanged(.pause))
        paused.apply(.interfaceDeactivated)
        paused.apply(.interfaceActivated)
        XCTAssertEqual(paused.desiredPlaybackCommand(rate: 1.0), .pause)
    }

    func testNavigationTransitionPausesCannotOverwriteRetainedIntent() {
        for intent in [PlayerIntent.play, .pause] {
            var state = PlayerSessionBehaviorState()
            state.apply(.interfaceActivated)
            state.apply(.interfaceDidAppear)
            state.apply(.playbackIntentChanged(intent))
            state.apply(.interfaceDeactivated)
            XCTAssertFalse(state.apply(.observedTimeControlStatus(.paused)))
            state.apply(.interfaceActivated)
            // AVKit can pause again after the route is already foreground,
            // but before its native page has finished appearing.
            XCTAssertFalse(state.apply(.observedTimeControlStatus(.paused)))
            state.apply(.interfaceDidAppear)
            XCTAssertEqual(state.intent, intent)
            XCTAssertEqual(state.desiredPlaybackCommand(rate: 1), intent == .play ? .play(rate: 1) : .pause)
            // Native controls become authoritative again after appearance.
            XCTAssertTrue(state.apply(.observedTimeControlStatus(.paused)))
            XCTAssertEqual(state.intent, .pause)
        }
    }

    func testAppearanceBeforeRouteActivationDoesNotLoseReadiness() {
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)
        state.apply(.interfaceDeactivated)
        state.apply(.interfaceDidAppear)
        state.apply(.interfaceDeactivated) // a late onAppear before route sync
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1), .pause)
        state.apply(.interfaceActivated)
        XCTAssertTrue(state.interfaceHasAppeared)
        XCTAssertTrue(state.apply(.observedTimeControlStatus(.paused)))
    }

    func testPictureInPictureAppIconReturnAndRestoreButtonPreserveLatestIntent() {
        for usesRestoreButton in [false, true] {
            for intent in [PlayerIntent.play, .pause] {
                var state = PlayerSessionBehaviorState()
                state.apply(.interfaceActivated)
                state.apply(.interfaceDidAppear)
                state.apply(.pictureInPictureTransition(.started))
                state.apply(.systemTransitionChanged(true))
                // A manual pause made in PiP must also survive restoration.
                state.apply(.observedTimeControlStatus(intent == .play ? .playing : .paused))
                state.apply(.pictureInPictureWillStop)
                state.apply(.systemTransitionChanged(false))
                XCTAssertFalse(state.apply(.observedTimeControlStatus(.paused)))
                let reason = PlayerPictureInPictureStopReason.resolve(
                    restorationSucceeded: usesRestoreButton,
                    sceneReturnedFromBackground: true,
                    inlinePlayerIsForeground: !usesRestoreButton
                )
                XCTAssertEqual(reason, .restored)
                state.apply(.pictureInPictureTransition(.stopped(reason)))
                XCTAssertEqual(state.intent, intent)
                XCTAssertEqual(state.desiredPlaybackCommand(rate: 1), intent == .play ? .play(rate: 1) : .pause)
                XCTAssertFalse(state.pictureInPictureIsStopping)
            }
        }
    }

    func testClosingPictureInPictureWithoutInlineDestinationStillPauses() {
        var state = PlayerSessionBehaviorState()
        state.apply(.pictureInPictureTransition(.started))
        state.apply(.pictureInPictureWillStop)
        let reason = PlayerPictureInPictureStopReason.resolve(
            restorationSucceeded: false, sceneReturnedFromBackground: true, inlinePlayerIsForeground: false
        )
        XCTAssertEqual(reason, .closed)
        state.apply(.pictureInPictureTransition(.stopped(reason)))
        state.apply(.interfaceActivated)
        state.apply(.interfaceDidAppear)
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1), .pause)
    }

    func testClosingPiPFromAlreadyForegroundInlinePageIsNotAnAppIconReturn() {
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)
        state.apply(.interfaceDidAppear)
        state.apply(.pictureInPictureTransition(.started))
        state.apply(.pictureInPictureWillStop)
        let reason = PlayerPictureInPictureStopReason.resolve(
            restorationSucceeded: false, sceneReturnedFromBackground: false, inlinePlayerIsForeground: true
        )
        XCTAssertEqual(reason, .closed)
        state.apply(.pictureInPictureTransition(.stopped(reason)))
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1), .pause)
    }

    func testNativePictureInPicturePauseAndPlayRemainAuthoritativeInBackground() {
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)
        state.apply(.pictureInPictureTransition(.started))
        state.apply(.systemTransitionChanged(true))
        XCTAssertTrue(state.apply(.observedTimeControlStatus(.paused)))
        // An inline AVKit view without a frame is normal while PiP owns the
        // video surface. Do not replace the PiP player on foreground entry.
        XCTAssertEqual(state.systemTransitionRecoveryAction(
            inactiveDuration: 60, engineIsAlive: true, sourceIsOffline: false,
            presentationNeedsRecovery: true
        ), .none)
        state.apply(.systemTransitionChanged(false))
        state.apply(.pictureInPictureTransition(.stopped(.restored)))
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1), .pause)

        state.apply(.pictureInPictureTransition(.started))
        state.apply(.systemTransitionChanged(true))
        XCTAssertTrue(state.apply(.observedTimeControlStatus(.playing)))
        state.apply(.systemTransitionChanged(false))
        state.apply(.pictureInPictureTransition(.stopped(.restored)))
        XCTAssertEqual(state.desiredPlaybackCommand(rate: 1), .play(rate: 1))
    }

    func testPausedBlackPresentationRebuildsWithoutForcingPlaybackEvenWithHealthyProxy() {
        for offline in [false, true] {
            var state = PlayerSessionBehaviorState()
            state.apply(.interfaceActivated)
            state.apply(.playbackIntentChanged(.pause))
            XCTAssertEqual(state.systemTransitionRecoveryAction(
                inactiveDuration: 5, engineIsAlive: true, sourceIsOffline: offline,
                presentationNeedsRecovery: true
            ), .rebuildSource)
            XCTAssertEqual(state.desiredPlaybackCommand(rate: 1), .pause)
            XCTAssertEqual(state.systemTransitionRecoveryAction(
                inactiveDuration: 31, engineIsAlive: true, sourceIsOffline: offline
            ), .rebuildSource)
        }
    }

    func testFailedItemRebuildsAfterBriefBackgroundAndHiddenSessionDoesNot() {
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)
        XCTAssertEqual(state.systemTransitionRecoveryAction(
            inactiveDuration: 0.5, engineIsAlive: true, sourceIsOffline: false, itemHasFailed: true
        ), .rebuildSource)
        state.apply(.interfaceDeactivated)
        XCTAssertEqual(state.systemTransitionRecoveryAction(
            inactiveDuration: 60, engineIsAlive: false, sourceIsOffline: false,
            itemHasFailed: true, presentationNeedsRecovery: true
        ), .none)
    }

    func testTwoXRateMatrixPreservesRateAcrossPlaybackLifecycles() {
        let lifecycleMatrix: [[PlayerSessionEvent]] = [
            [
                .interfaceActivated,
                .systemTransitionChanged(true),
                .systemTransitionChanged(false),
            ],
            [
                .interfaceActivated,
                .interfaceDeactivated,
                .interfaceActivated,
            ],
            [
                .interfaceActivated,
                .pictureInPictureTransition(.started),
                .interfaceDeactivated,
                .pictureInPictureTransition(.stopped(.restored)),
                .interfaceActivated,
            ],
            [
                .interfaceActivated,
                .prepareAutoplayForMediaReplacement,
                .interfaceActivated,
            ],
        ]

        for events in lifecycleMatrix {
            var state = PlayerSessionBehaviorState()
            for event in events {
                state.apply(event)
            }
            XCTAssertEqual(
                state.desiredPlaybackCommand(rate: 2.0),
                .play(rate: 2.0),
                "lifecycle sequence lost the user's 2x playback rate: \(events)"
            )
        }
    }
}
