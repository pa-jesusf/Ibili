import AVKit
import SwiftUI
import XCTest
@testable import Ibili

@MainActor
final class PlayerLifecycleTests: XCTestCase {
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
