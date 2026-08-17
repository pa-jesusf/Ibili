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
            playerBox.foregroundRecoveryTask?.cancel()
            playerBox.foregroundRecoveryTask = nil
            if playerBox.systemTransitionStartedAt == nil {
                playerBox.systemTransitionStartedAt = Date()
                viewModel.beginSystemTransition()
            }
            return
        }

        if phase == .background,
           !viewModel.isPictureInPictureActive,
           let vc = playerBox.vc,
           let player = vc.player,
           playerBox.detachedPlayer == nil {
            if playerBox.systemTransitionStartedAt == nil {
                playerBox.systemTransitionStartedAt = Date()
                viewModel.beginSystemTransition()
            }
            viewModel.endTemporarySpeedBoost(on: player)
            let continuationRate = viewModel.backgroundContinuationRate(for: player)
            AppLog.info("player", "锁屏后台分离 AVPlayerViewController 绑定", metadata: [
                "aid": String(viewModel.currentAid),
                "cid": String(viewModel.currentCid),
                "continuationRate": continuationRate.map { String($0) } ?? "nil",
            ])
            playerBox.detachedPlayer = player
            vc.player = nil
            if let continuationRate {
                player.playImmediately(atRate: continuationRate)
            } else {
                player.pause()
            }
            viewModel.refreshSystemMediaSession()
        }

        guard phase == .active else { return }
        let inactiveDuration = playerBox.systemTransitionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let didLeaveActiveState = playerBox.systemTransitionStartedAt != nil
        playerBox.systemTransitionStartedAt = nil

        if didLeaveActiveState,
           !viewModel.isPictureInPictureActive,
           let targetPlayer = playerBox.detachedPlayer ?? viewModel.player,
           let vc = playerBox.vc {
            AppLog.info("player", "前台恢复 AVPlayerViewController 绑定", metadata: [
                "aid": String(viewModel.currentAid),
                "cid": String(viewModel.currentCid),
                "inactiveMs": String(Int(inactiveDuration * 1000)),
            ])
            // Recreate AVPlayerViewController's display-layer binding even
            // when SwiftUI reattached the same player before scenePhase
            // reached `.active`; otherwise AVKit can retain a black layer.
            if vc.player === targetPlayer {
                vc.player = nil
            }
            vc.player = targetPlayer
        }
        playerBox.detachedPlayer = nil
        viewModel.completeSystemTransition()

        guard viewModel.player != nil else { return }
        playerBox.foregroundRecoveryTask?.cancel()
        playerBox.foregroundRecoveryTask = Task { @MainActor [weak viewModel, weak playerBox] in
            guard let viewModel else { return }
            await viewModel.recoverAfterSystemTransitionIfNeeded(
                trigger: "foreground-active",
                inactiveDuration: inactiveDuration
            )
            playerBox?.foregroundRecoveryTask = nil
        }
        if viewModel.isPictureInPictureActive,
           let vc = playerBox.vc {
            vc.allowsPictureInPicturePlayback = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                vc.allowsPictureInPicturePlayback = true
            }
        }
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
        viewModel.handle(.interfaceActivated)
        if let player = viewModel.player {
            danmaku.attach(player)
        }
        viewModel.refreshSystemMediaSession()
    }

    static func handleDisappear(viewModel: PlayerViewModel) {
        viewModel.refreshSystemMediaSession()
    }
}

final class PlayerVCBox {
    weak var vc: AVPlayerViewController?
    /// Strong reference to the AVPlayer that was temporarily detached from
    /// `vc` while the app is backgrounded or the screen is locked.
    var detachedPlayer: AVPlayer?
    var systemTransitionStartedAt: Date?
    var foregroundRecoveryTask: Task<Void, Never>?

    deinit {
        foregroundRecoveryTask?.cancel()
    }
}
