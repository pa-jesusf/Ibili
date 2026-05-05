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

    private var activeOwners: Set<ObjectIdentifier> = []
    private var playerHandoffDepth = 0
    private var sessionIsActive = false
    private let sessionQueue = DispatchQueue(label: "ibili.player.audio-session", qos: .userInitiated)
    private var pendingHandoffEndWorkItem: DispatchWorkItem?

    func beginPlayerHandoff() {
        pendingHandoffEndWorkItem?.cancel()
        pendingHandoffEndWorkItem = nil
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
        guard shouldKeepSessionActive != sessionIsActive else { return }
        sessionIsActive = shouldKeepSessionActive
        if shouldKeepSessionActive {
            activateAudioSession()
        } else {
            deactivateAudioSession()
        }
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

struct PlayerNowPlayingMetadata: Equatable {
    let title: String
    let artist: String
    let artworkURL: String?
    let duration: TimeInterval?
}

@MainActor
final class PlayerNowPlayingCoordinator {
    static let shared = PlayerNowPlayingCoordinator()

    private weak var preferredOwner: PlayerViewModel?
    private weak var activeOwner: PlayerViewModel?
    private var remoteCommandsConfigured = false
    private var artworkLoadID = UUID()
    private var currentArtworkURL: String?

    func activate(_ viewModel: PlayerViewModel) {
        configureRemoteCommandsIfNeeded()
        preferredOwner = viewModel
        AppLog.debug("player", "系统媒体会话候选激活", metadata: [
            "aid": String(viewModel.currentAid),
            "cid": String(viewModel.currentCid),
            "hasPlayer": String(viewModel.player != nil),
        ])
        refresh(for: viewModel)
    }

    func unregister(_ viewModel: PlayerViewModel) {
        if preferredOwner === viewModel {
            preferredOwner = nil
        }
        guard activeOwner === viewModel else { return }
        AppLog.info("player", "系统媒体会话已清理", metadata: [
            "aid": String(viewModel.currentAid),
            "cid": String(viewModel.currentCid),
        ])
        activeOwner = nil
        currentArtworkURL = nil
        artworkLoadID = UUID()
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }

    func refresh(for viewModel: PlayerViewModel) {
        configureRemoteCommandsIfNeeded()
        guard preferredOwner === viewModel || activeOwner === viewModel else { return }
        guard let metadata = viewModel.nowPlayingMetadata else { return }
        if preferredOwner === viewModel, viewModel.player != nil, activeOwner !== viewModel {
            activeOwner = viewModel
            AppLog.info("player", "系统媒体会话切换到当前播放器", metadata: [
                "aid": String(viewModel.currentAid),
                "cid": String(viewModel.currentCid),
                "title": metadata.title,
            ])
        } else if preferredOwner === viewModel, viewModel.player != nil {
            activeOwner = viewModel
        }
        guard activeOwner === viewModel else { return }

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = metadata.title
        if metadata.artist.isEmpty {
            info.removeValue(forKey: MPMediaItemPropertyArtist)
        } else {
            info[MPMediaItemPropertyArtist] = metadata.artist
        }
        if let duration = metadata.duration, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }
        if let elapsed = viewModel.currentElapsedPlaybackTime {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = viewModel.systemMediaPlaybackRate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = viewModel.systemMediaDefaultRate
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue

        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = viewModel.systemMediaPlaybackRate > 0 ? .playing : .paused
        updateArtworkIfNeeded(from: metadata.artworkURL, owner: viewModel)
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false

        center.playCommand.addTarget { [weak self] _ in
            self?.handleRemoteIntent(.play) ?? .noSuchContent
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.handleRemoteIntent(.pause) ?? .noSuchContent
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleToggleRemoteCommand() ?? .noSuchContent
        }
    }

    private func handleRemoteIntent(_ intent: PlayerIntent) -> MPRemoteCommandHandlerStatus {
        guard let owner = activeOwner ?? preferredOwner else { return .noSuchContent }
        guard owner.player != nil else { return .commandFailed }
        AppLog.info("player", "收到系统媒体播放命令", metadata: [
            "intent": intent.rawValue,
            "aid": String(owner.currentAid),
            "cid": String(owner.currentCid),
        ])
        owner.handleRemotePlaybackIntent(intent)
        return .success
    }

    private func handleToggleRemoteCommand() -> MPRemoteCommandHandlerStatus {
        guard let owner = activeOwner ?? preferredOwner,
              let player = owner.player else {
            return .noSuchContent
        }
        let isPlaying = player.timeControlStatus == .playing || player.rate > 0
        AppLog.info("player", "收到系统媒体切换播放命令", metadata: [
            "currentState": isPlaying ? "playing" : "paused",
            "aid": String(owner.currentAid),
            "cid": String(owner.currentCid),
        ])
        owner.handleRemotePlaybackIntent(isPlaying ? .pause : .play)
        return .success
    }

    private func updateArtworkIfNeeded(from artworkURL: String?, owner: PlayerViewModel) {
        guard let artworkURL, !artworkURL.isEmpty else {
            currentArtworkURL = nil
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            return
        }
        guard currentArtworkURL != artworkURL ||
              MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil else {
            return
        }

        currentArtworkURL = artworkURL
        let loadID = UUID()
        artworkLoadID = loadID

        Task { [weak self, weak owner] in
            guard let self,
                  let owner,
                  let data = await PlayerArtworkStore.shared.load(from: artworkURL),
                  let image = UIImage(data: data) else {
                return
            }
            await MainActor.run {
                guard self.artworkLoadID == loadID,
                      self.activeOwner === owner else {
                    return
                }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}