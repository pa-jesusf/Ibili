import AVFoundation
import Foundation
import MediaPlayer
import UIKit

@MainActor
final class PlayerPlaybackCoordinator {
    static let shared = PlayerPlaybackCoordinator()

    private static let handoffGraceSeconds: TimeInterval = 2.0

    private weak var active: PlayerViewModel?

    func activate(_ viewModel: PlayerViewModel) {
        if active !== viewModel {
            let priorActive = active
            if priorActive != nil {
                PlayerAudioSessionCoordinator.shared.beginPlayerHandoff()
            }
            priorActive?.handle(.interfaceDeactivated)
            active = viewModel
            if priorActive != nil {
                PlayerAudioSessionCoordinator.shared.schedulePlayerHandoffEnd(
                    after: Self.handoffGraceSeconds
                )
            }
        }
    }

    func unregister(_ viewModel: PlayerViewModel) {
        if active === viewModel {
            active = nil
        }
    }
}

@MainActor
final class PlayerAudioSessionCoordinator {
    static let shared = PlayerAudioSessionCoordinator()

    private static let releaseGraceSeconds: TimeInterval = 0.75

    private var activeOwners: Set<ObjectIdentifier> = []
    private var playerHandoffDepth = 0
    private var sessionIsActive = false
    private let sessionQueue = DispatchQueue(label: "ibili.player.audio-session", qos: .userInitiated)
    private var pendingHandoffEndWorkItem: DispatchWorkItem?
    private var pendingDeactivationWorkItem: DispatchWorkItem?

    func beginPlayerHandoff() {
        pendingHandoffEndWorkItem?.cancel()
        pendingHandoffEndWorkItem = nil
        cancelPendingDeactivation()
        playerHandoffDepth += 1
        reconcileSessionState()
    }

    func schedulePlayerHandoffEnd(after delay: TimeInterval) {
        pendingHandoffEndWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingHandoffEndWorkItem = nil
            self.endPlayerHandoff()
        }
        pendingHandoffEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func endPlayerHandoff() {
        playerHandoffDepth = max(0, playerHandoffDepth - 1)
        reconcileSessionState()
    }

    func setSessionNeeded(_ needed: Bool, by owner: AnyObject) {
        let ownerID = ObjectIdentifier(owner)
        if needed {
            cancelPendingDeactivation()
            _ = activeOwners.insert(ownerID).inserted
            if playerHandoffDepth > 0 {
                pendingHandoffEndWorkItem?.cancel()
                pendingHandoffEndWorkItem = nil
                playerHandoffDepth = 0
            }
        } else {
            _ = activeOwners.remove(ownerID)
        }
        reconcileSessionState()
    }

    private func reconcileSessionState() {
        let shouldKeepSessionActive = !activeOwners.isEmpty || playerHandoffDepth > 0
        if shouldKeepSessionActive {
            cancelPendingDeactivation()
            guard !sessionIsActive else { return }
            sessionIsActive = true
            activateAudioSession()
        } else {
            guard sessionIsActive else {
                cancelPendingDeactivation()
                return
            }
            scheduleAudioSessionDeactivation()
        }
    }

    private func scheduleAudioSessionDeactivation() {
        guard pendingDeactivationWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDeactivationWorkItem = nil
            guard self.activeOwners.isEmpty,
                  self.playerHandoffDepth == 0,
                  self.sessionIsActive else {
                self.reconcileSessionState()
                return
            }
            self.sessionIsActive = false
            self.deactivateAudioSession()
        }
        pendingDeactivationWorkItem = workItem
        AppLog.debug("player", "延迟释放音频会话", metadata: [
            "delayMs": String(Int(Self.releaseGraceSeconds * 1000)),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseGraceSeconds, execute: workItem)
    }

    private func cancelPendingDeactivation() {
        pendingDeactivationWorkItem?.cancel()
        pendingDeactivationWorkItem = nil
    }

    private func activateAudioSession() {
        sessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback, options: [])
                try session.setActive(true, options: [])
            } catch {
                AppLog.warning("player", "音频会话配置失败", metadata: [
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    private func deactivateAudioSession() {
        sessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
            } catch {
                AppLog.warning("player", "音频会话释放失败", metadata: [
                    "error": error.localizedDescription,
                ])
            }
        }
    }
}
