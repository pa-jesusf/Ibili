import AVKit
import SwiftUI
import XCTest
@testable import Ibili

@MainActor
final class PlayerLifecycleTests: XCTestCase {
    func testRetiredItemEndNotificationDoesNotCompleteReplacementItem() {
        let original = AVPlayerItem(asset: AVMutableComposition())
        let player = LifecyclePlayer(playerItem: original)
        let model = PlayerViewModel(initialPlayer: player)
        defer { model.teardown() }
        player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: original)
        XCTAssertEqual(model.playbackCompletionSignal, 0)
    }

    func testInteractiveArchiveIdentitySurvivesDetailArrivingBeforePlayer() {
        let model = PlayerViewModel()
        defer { model.teardown() }
        model.requireInteractiveVideo()
        XCTAssertTrue(model.isInteractiveVideo)
        XCTAssertNil(model.player)
    }

    func testPauseDuringSlowReplayRemainsAuthoritativeForPlayingAndCompletedPlayers() async {
        for initialIntent in [PlayerIntent.play, .pause] {
            let player = LifecyclePlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
            let viewModel = PlayerViewModel(initialPlayer: player)
            defer { viewModel.teardown() }
            viewModel.handle(.interfaceActivated)
            viewModel.handle(.interfaceDidAppear)
            viewModel.handle(.playbackIntentChanged(initialIntent))
            let submitted = expectation(description: "Replay seek submitted")
            player.seekSubmitted = { submitted.fulfill() }
            viewModel.restartCurrentItem()
            await fulfillment(of: [submitted], timeout: 2)
            viewModel.handle(.playbackIntentChanged(.pause))
            player.finishSeek()
            for _ in 0..<40 { await Task.yield() }
            XCTAssertEqual(player.rate, 0)
        }
    }

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
    var seekSubmitted: (() -> Void)?
    private var seekCompletion: ((Bool) -> Void)?
    private var storedRate: Float = 0
    private var storedStatus: AVPlayer.TimeControlStatus = .paused
    override var rate: Float {
        get { storedRate }
        set { setPlaybackRate(newValue) }
    }
    override var timeControlStatus: AVPlayer.TimeControlStatus { storedStatus }
    override func playImmediately(atRate rate: Float) { setPlaybackRate(rate) }
    override func pause() { setPlaybackRate(0) }
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                       completionHandler: @escaping (Bool) -> Void) {
        seekCompletion = completionHandler
        seekSubmitted?()
    }

    func finishSeek() {
        let completion = seekCompletion
        seekCompletion = nil
        completion?(true)
    }

    private func setPlaybackRate(_ rate: Float) {
        willChangeValue(forKey: "timeControlStatus")
        storedRate = rate
        storedStatus = rate > 0 ? .playing : .paused
        didChangeValue(forKey: "timeControlStatus")
    }
}
