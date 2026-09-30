import AVKit
import SwiftUI
import XCTest
@testable import Ibili

@MainActor
final class PlayerLifecycleTests: XCTestCase {
    func testNativePageAppearanceResumesPlayingButNotManuallyPausedPlayer() {
        for wasPlaying in [true, false] {
            let player = LifecyclePlayer()
            let viewModel = PlayerViewModel(initialPlayer: player)
            defer { viewModel.teardown() }
            viewModel.handle(.interfaceActivated)
            let appearance = PlayerPageAppearanceObserver.Controller()
            appearance.didAppear = { viewModel.handle(.interfaceDidAppear) }
            appearance.viewDidAppear(false)
            if !wasPlaying { player.pause() }
            viewModel.prepareForStackBackground()
            XCTAssertEqual(player.rate, 0)
            viewModel.handle(.interfaceActivated)
            // Simulate AVKit pausing during the pop transition, after path
            // reconciliation but before the native page finishes appearing.
            player.pause()
            appearance.viewDidAppear(false)
            XCTAssertEqual(player.rate > 0, wasPlaying)
            // A subsequent manual pause is not swallowed by restoration.
            player.pause()
            viewModel.prepareForStackBackground()
            viewModel.handle(.interfaceActivated)
            appearance.viewDidAppear(false)
            XCTAssertEqual(player.rate, 0)
        }
    }

    func testPiPAutomaticInlineReturnReappliesIntentAfterNativeTransitionPause() {
        let player = LifecyclePlayer()
        let viewModel = PlayerViewModel(initialPlayer: player)
        defer { viewModel.teardown() }
        viewModel.handle(.interfaceActivated)
        viewModel.handle(.interfaceDidAppear)
        viewModel.handle(.pictureInPictureTransition(.started))
        viewModel.beginSystemTransition()
        viewModel.handle(.pictureInPictureWillStop)
        player.pause()
        viewModel.completeSystemTransition()
        let reason = PlayerPictureInPictureStopReason.resolve(
            restorationSucceeded: false, sceneReturnedFromBackground: true, inlinePlayerIsForeground: true
        )
        viewModel.handle(.pictureInPictureTransition(.stopped(reason)))
        XCTAssertGreaterThan(player.rate, 0)
    }

    func testSystemPanelDoesNotDetachAVKitOrScheduleSourceRecovery() {
        let viewModel = PlayerViewModel()
        let box = PlayerVCBox()
        let controller = AVPlayerViewController()
        let player = AVPlayer()
        controller.player = player
        box.vc = controller
        PlayerViewLifecycleController.handleScenePhaseChange(
            .inactive, didBootstrap: true, viewModel: viewModel, playerBox: box
        )
        PlayerViewLifecycleController.handleScenePhaseChange(
            .active, didBootstrap: true, viewModel: viewModel, playerBox: box
        )
        XCTAssertTrue(controller.player === player)
        XCTAssertNil(box.backgroundStartedAt)
    }

    func testLockAndUnlockDoNotDetachPausedPlayer() {
        let viewModel = PlayerViewModel()
        viewModel.handle(.playbackIntentChanged(.pause))
        let box = PlayerVCBox()
        let controller = AVPlayerViewController()
        let player = AVPlayer()
        controller.player = player
        box.vc = controller
        for phase in [SwiftUI.ScenePhase.inactive, .background, .inactive, .active] {
            PlayerViewLifecycleController.handleScenePhaseChange(
                phase, didBootstrap: true, viewModel: viewModel, playerBox: box
            )
            XCTAssertTrue(controller.player === player)
            XCTAssertEqual(player.rate, 0)
        }
    }

    func testRoutePopReactivatesRetainedPlayerWithoutDependingOnAppear() {
        let coordinator = PlayerRuntimeCoordinator.shared
        let a = DeepLinkRouter.PlayerRoute(item: DeepLinkRouter.makeShell(aid: 1, bvid: "BV1"))
        let b = DeepLinkRouter.PlayerRoute(item: DeepLinkRouter.makeShell(aid: 2, bvid: "BV2"))
        let modelA = coordinator.viewModel(for: a.id)
        let modelB = coordinator.viewModel(for: b.id)
        defer {
            modelA.teardown()
            modelB.teardown()
            coordinator.retainSessions(root: nil, stack: [], foregroundRouteID: nil)
        }
        for foreground in [a.id, b.id, nil, b.id, a.id] {
            coordinator.retainSessions(root: nil, stack: [a, b], foregroundRouteID: foreground)
            XCTAssertEqual(modelA.isOverlayPresentationActive, foreground == a.id)
            XCTAssertEqual(modelB.isOverlayPresentationActive, foreground == b.id)
        }
    }
}

private final class LifecyclePlayer: AVPlayer {
    private var storedRate: Float = 0
    private var storedStatus: AVPlayer.TimeControlStatus = .paused
    override var rate: Float {
        get { storedRate }
        set { setPlaybackRate(newValue) }
    }
    override var timeControlStatus: AVPlayer.TimeControlStatus { storedStatus }
    override func playImmediately(atRate rate: Float) { setPlaybackRate(rate) }
    override func pause() { setPlaybackRate(0) }

    private func setPlaybackRate(_ rate: Float) {
        willChangeValue(forKey: "timeControlStatus")
        storedRate = rate
        storedStatus = rate > 0 ? .playing : .paused
        didChangeValue(forKey: "timeControlStatus")
    }
}
