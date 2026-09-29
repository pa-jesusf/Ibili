import AVFoundation
import AVKit
import SwiftUI

func timeControlStatusDescription(_ status: AVPlayer.TimeControlStatus) -> String {
    switch status {
    case .paused:
        return "paused"
    case .waitingToPlayAtSpecifiedRate:
        return "waiting"
    case .playing:
        return "playing"
    @unknown default:
        return "future(\(status.rawValue))"
    }
}

@MainActor
enum PlayerViewLifecycleController {
    static func handleScenePhaseChange(_ phase: ScenePhase,
                                       didBootstrap: Bool,
                                       viewModel: PlayerViewModel,
                                       playerBox: PlayerVCBox) {
        guard didBootstrap else { return }

        if phase == .inactive {
            viewModel.beginSystemTransition()
            return
        }

        if phase == .background {
            playerBox.backgroundStartedAt = playerBox.backgroundStartedAt ?? Date()
            viewModel.beginSystemTransition()
            return
        }

        guard phase == .active else { return }
        viewModel.completeSystemTransition()
        // System panels do not suspend the app. Neither rebinding AVKit nor
        // probing/rebuilding the HLS source is needed after those overlays.
        guard let backgroundStartedAt = playerBox.backgroundStartedAt else { return }
        playerBox.backgroundStartedAt = nil
        let inactiveDuration = Date().timeIntervalSince(backgroundStartedAt)

        viewModel.requestSystemTransitionRecovery(
            inactiveDuration: inactiveDuration,
            presentationNeedsRecovery: playerBox.vc?.isReadyForDisplay == false
        )
        viewModel.refreshSystemMediaSession()
    }

    static func handleAppear(didBootstrap: Bool,
                             viewModel: PlayerViewModel,
                             danmaku: DanmakuController,
                             baseAudioGainDb: Double,
                             loudnessNormalizationEnabled: Bool) {
        viewModel.setAudioConfiguration(
            baseGainDb: baseAudioGainDb,
            normalizationEnabled: loudnessNormalizationEnabled,
            animated: false
        )
        guard didBootstrap else { return }
        viewModel.activateInterfaceIfForeground()
        if let player = viewModel.player {
            danmaku.attach(player)
        }
        viewModel.refreshSystemMediaSession()
    }

    static func handleDisappear(viewModel: PlayerViewModel) {
        viewModel.refreshSystemMediaSession()
    }
}

@MainActor
final class PlayerVCBox {
    weak var vc: AVPlayerViewController?
    var backgroundStartedAt: Date?
}
