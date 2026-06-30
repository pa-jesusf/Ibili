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
                                       playerBox: PlayerVCBox,
                                       reloadPlayer: @escaping @MainActor () async -> Void) {
        if phase == .background,
           didBootstrap,
           !viewModel.isPictureInPictureActive,
           let vc = playerBox.vc,
           let player = vc.player,
           playerBox.detachedPlayer == nil {
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

        guard phase == .active, didBootstrap else { return }
        if let detachedPlayer = playerBox.detachedPlayer,
           let vc = playerBox.vc {
            AppLog.info("player", "前台恢复 AVPlayerViewController 绑定", metadata: [
                "aid": String(viewModel.currentAid),
                "cid": String(viewModel.currentCid),
            ])
            if vc.player !== detachedPlayer {
                vc.player = detachedPlayer
            }
            viewModel.reapplyPlaybackBehavior(to: detachedPlayer)
            playerBox.detachedPlayer = nil
            viewModel.refreshSystemMediaSession()
        }
        guard viewModel.player != nil else { return }
        if !viewModel.isEngineAlive {
            Task { await reloadPlayer() }
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
                             resolvedAudioVolumeLinear: Float) {
        viewModel.setAudioVolumeLinear(resolvedAudioVolumeLinear)
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
}
