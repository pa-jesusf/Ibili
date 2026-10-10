import Foundation
import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
typealias PlayerNowPlayingImage = UIImage
#else
import AppKit
typealias PlayerNowPlayingImage = NSImage
#endif

@MainActor
protocol PlayerSystemMediaSessionOwner: AnyObject {
    var player: AVPlayer? { get }
    var currentAid: Int64 { get }
    var currentCid: Int64 { get }
    var shouldExposeSystemMediaSession: Bool { get }
    var nowPlayingMetadata: PlayerNowPlayingMetadata? { get }
    var systemMediaSessionDebugMetadata: [String: String] { get }
    var currentElapsedPlaybackTime: TimeInterval? { get }
    var systemMediaPlaybackRate: Float { get }
    var systemMediaDefaultRate: Float { get }
    func handleRemotePlaybackIntent(_ intent: PlayerIntent)
}

@MainActor
protocol PlayerNowPlayingInfoStore: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

@MainActor
private final class SystemPlayerNowPlayingInfoStore: PlayerNowPlayingInfoStore {
    private let center = MPNowPlayingInfoCenter.default()
    var nowPlayingInfo: [String: Any]? {
        get { center.nowPlayingInfo }
        set { center.nowPlayingInfo = newValue }
    }
    var playbackState: MPNowPlayingPlaybackState {
        get { center.playbackState }
        set { center.playbackState = newValue }
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
    #if canImport(UIKit)
    static let shared = PlayerNowPlayingCoordinator(artworkLoader: { url in
        guard let data = await PlayerArtworkStore.shared.load(from: url) else { return nil }
        return UIImage(data: data)
    })
    #endif

    private weak var preferredOwner: any PlayerSystemMediaSessionOwner?
    private weak var activeOwner: any PlayerSystemMediaSessionOwner?
    private var remoteCommandsConfigured = false
    private var artworkLoadID = UUID()
    private var currentArtworkURL: String?
    private var artworkTask: Task<Void, Never>?
    private let infoStore: any PlayerNowPlayingInfoStore
    private let artworkLoader: (String) async -> PlayerNowPlayingImage?
    private let registersRemoteCommands: Bool

    init(infoStore: (any PlayerNowPlayingInfoStore)? = nil,
         registersRemoteCommands: Bool = true,
         artworkLoader: @escaping (String) async -> PlayerNowPlayingImage?) {
        self.infoStore = infoStore ?? SystemPlayerNowPlayingInfoStore()
        self.registersRemoteCommands = registersRemoteCommands
        self.artworkLoader = artworkLoader
    }

    func activate(_ viewModel: any PlayerSystemMediaSessionOwner) {
        configureRemoteCommandsIfNeeded()
        preferredOwner = viewModel
        AppLog.debug("player", "系统媒体会话候选激活", metadata: [
            "aid": String(viewModel.currentAid),
            "cid": String(viewModel.currentCid),
            "hasPlayer": String(viewModel.player != nil),
        ])
        refresh(for: viewModel)
    }

    func unregister(_ viewModel: any PlayerSystemMediaSessionOwner) {
        if preferredOwner === viewModel {
            preferredOwner = nil
        }
        guard activeOwner === viewModel else { return }
        AppLog.info("player", "系统媒体会话已清理", metadata: [
            "aid": String(viewModel.currentAid),
            "cid": String(viewModel.currentCid),
        ])
        activeOwner = nil
        invalidateArtwork()
        let infoCenter = infoStore
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }

    func refresh(for viewModel: any PlayerSystemMediaSessionOwner) {
        configureRemoteCommandsIfNeeded()
        guard preferredOwner === viewModel || activeOwner === viewModel else { return }
        guard viewModel.shouldExposeSystemMediaSession,
              let metadata = viewModel.nowPlayingMetadata else {
            // A foreground route is activated before its item finishes loading.
            // Retain that candidate so setPlayer/readiness can publish metadata.
            if activeOwner === viewModel {
                AppLog.info("player", "系统媒体会话已自动隐藏", metadata: viewModel.systemMediaSessionDebugMetadata)
                activeOwner = nil
                invalidateArtwork()
                let infoCenter = infoStore
                infoCenter.nowPlayingInfo = nil
                infoCenter.playbackState = .stopped
            }
            return
        }
        if preferredOwner === viewModel, viewModel.player != nil, activeOwner !== viewModel {
            invalidateArtwork()
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

        var info = infoStore.nowPlayingInfo ?? [:]
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

        let infoCenter = infoStore
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = viewModel.systemMediaPlaybackRate > 0 ? .playing : .paused
        updateArtworkIfNeeded(from: metadata.artworkURL, owner: viewModel)
    }

    private func configureRemoteCommandsIfNeeded() {
        guard registersRemoteCommands, !remoteCommandsConfigured else { return }
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

    private func invalidateArtwork() {
        artworkTask?.cancel(); artworkTask = nil
        currentArtworkURL = nil
        artworkLoadID = UUID()
        var info = infoStore.nowPlayingInfo ?? [:]
        info.removeValue(forKey: MPMediaItemPropertyArtwork)
        infoStore.nowPlayingInfo = info
    }

    private func updateArtworkIfNeeded(from artworkURL: String?, owner: any PlayerSystemMediaSessionOwner) {
        guard let artworkURL, !artworkURL.isEmpty else {
            if currentArtworkURL != nil || artworkTask != nil { invalidateArtwork() }
            return
        }
        if currentArtworkURL == artworkURL,
           artworkTask != nil || infoStore.nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil { return }
        invalidateArtwork()
        currentArtworkURL = artworkURL
        let loadID = UUID()
        artworkLoadID = loadID
        artworkTask = Task { [weak self, weak owner] in
            guard let self, let owner else { return }
            let image = await artworkLoader(artworkURL)
            guard !Task.isCancelled, artworkLoadID == loadID, activeOwner === owner else { return }
            artworkTask = nil
            guard let image else { return }
            var info = infoStore.nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            infoStore.nowPlayingInfo = info
        }
    }
}
