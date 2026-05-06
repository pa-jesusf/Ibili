import AVFoundation
import Foundation

typealias PlayerSessionID = UUID

enum PlayerIntent: String {
    case play
    case pause
}

enum PlayerDesiredPlaybackCommand: Equatable {
    case play(rate: Float)
    case pause
}

enum PlayerSessionEvent: Equatable {
    case interfaceActivated
    case interfaceDeactivated
    case pictureInPictureChanged(Bool)
    case playbackIntentChanged(PlayerIntent)
    case prepareAutoplayForMediaReplacement
    case suppressNextObservedIntent(PlayerIntent)
    case observedTimeControlStatus(AVPlayer.TimeControlStatus)
}

struct PlayerSessionBehaviorState: Equatable {
    private(set) var intent: PlayerIntent = .play
    private(set) var hasPlaybackFocus = false
    private(set) var interfaceIsActive = false
    private(set) var pictureInPictureIsActive = false
    private var suppressedObservedIntent: PlayerIntent?

    var isInterfacePresentingPlayer: Bool {
        interfaceIsActive || pictureInPictureIsActive
    }

    var shouldHoldAudioSession: Bool {
        intent == .play && hasPlaybackFocus && (interfaceIsActive || pictureInPictureIsActive)
    }

    var debugMetadata: [String: String] {
        [
            "intent": intent.rawValue,
            "hasPlaybackFocus": String(hasPlaybackFocus),
            "interfaceIsActive": String(interfaceIsActive),
            "pictureInPictureIsActive": String(pictureInPictureIsActive),
            "suppressedObservedIntent": suppressedObservedIntent?.rawValue ?? "nil",
            "shouldHoldAudioSession": String(shouldHoldAudioSession),
        ]
    }

    @discardableResult
    mutating func apply(_ event: PlayerSessionEvent) -> Bool {
        switch event {
        case .interfaceActivated:
            activateInterface()
            return true
        case .interfaceDeactivated:
            deactivateInterface()
            return true
        case .pictureInPictureChanged(let isActive):
            setPictureInPictureActive(isActive)
            return true
        case .playbackIntentChanged(let intent):
            setIntent(intent)
            return true
        case .prepareAutoplayForMediaReplacement:
            markMediaReplacementAutoplayIntent()
            return true
        case .suppressNextObservedIntent(let intent):
            suppressNextObservedIntent(intent)
            return true
        case .observedTimeControlStatus(let status):
            return applyObservedTimeControlStatus(status)
        }
    }

    mutating func markMediaReplacementAutoplayIntent() {
        intent = .play
        suppressedObservedIntent = nil
    }

    mutating func activateInterface() {
        hasPlaybackFocus = true
        interfaceIsActive = true
    }

    mutating func deactivateInterface() {
        interfaceIsActive = false
        if !pictureInPictureIsActive {
            hasPlaybackFocus = false
        }
    }

    mutating func setPictureInPictureActive(_ isActive: Bool) {
        pictureInPictureIsActive = isActive
        if isActive {
            hasPlaybackFocus = true
        } else if !interfaceIsActive {
            hasPlaybackFocus = false
        }
    }

    mutating func setIntent(_ intent: PlayerIntent) {
        self.intent = intent
        suppressedObservedIntent = nil
    }

    mutating func suppressNextObservedIntent(_ intent: PlayerIntent) {
        suppressedObservedIntent = intent
    }

    mutating func applyObservedTimeControlStatus(_ status: AVPlayer.TimeControlStatus) -> Bool {
        guard let observedIntent = PlayerIntent(status) else { return false }
        if let suppressedObservedIntent, suppressedObservedIntent == observedIntent {
            self.suppressedObservedIntent = nil
            return false
        }
        guard hasPlaybackFocus, interfaceIsActive || pictureInPictureIsActive else { return false }
        intent = observedIntent
        return true
    }

    func desiredPlaybackCommand(rate: Float) -> PlayerDesiredPlaybackCommand {
        if shouldHoldAudioSession {
            return .play(rate: rate > 0 ? rate : 1.0)
        }
        return .pause
    }

    func backgroundContinuationRate(currentRate: Float, desiredRate: Float) -> Float? {
        guard shouldHoldAudioSession else { return nil }
        let activeRate = currentRate > 0 ? currentRate : desiredRate
        return activeRate > 0 ? activeRate : 1.0
    }
}

extension PlayerIntent {
    init?(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .paused:
            self = .pause
        case .playing, .waitingToPlayAtSpecifiedRate:
            self = .play
        @unknown default:
            return nil
        }
    }
}

struct PlayerFullscreenTransitionSnapshot: Equatable {
    let playerID: ObjectIdentifier
    let wasPlaying: Bool
    let playbackRate: Float

    static func capture(from player: AVPlayer?) -> PlayerFullscreenTransitionSnapshot? {
        guard let player else { return nil }
        let activeRate = player.rate
        let defaultRate = player.defaultRate
        let resolvedRate = activeRate > 0 ? activeRate : (defaultRate > 0 ? defaultRate : 1.0)
        return PlayerFullscreenTransitionSnapshot(
            playerID: ObjectIdentifier(player),
            wasPlaying: player.timeControlStatus == .playing || player.rate > 0,
            playbackRate: resolvedRate
        )
    }

    func desiredPlaybackCommand(for player: AVPlayer?) -> PlayerDesiredPlaybackCommand? {
        guard let player, ObjectIdentifier(player) == playerID, wasPlaying else { return nil }
        return .play(rate: playbackRate)
    }
}

struct PlayerPresentationIdentity: Equatable {
    let sessionID: PlayerSessionID
    let playerID: ObjectIdentifier?
}

private enum PlayerFullscreenPresentationPhase: Equatable {
    case active(PlayerPresentationIdentity)
    case dismissing(PlayerPresentationIdentity)

    var identity: PlayerPresentationIdentity {
        switch self {
        case .active(let identity), .dismissing(let identity):
            return identity
        }
    }
}

struct PlayerPresentationState: Equatable {
    private var fullscreenPhase: PlayerFullscreenPresentationPhase?

    var isFullscreenPresentationActive: Bool {
        fullscreenPhase != nil
    }

    var isAwaitingInlineFullscreenReturn: Bool {
        if case .dismissing = fullscreenPhase {
            return true
        }
        return false
    }

    mutating func beginFullscreen(_ identity: PlayerPresentationIdentity) -> Bool {
        guard fullscreenPhase != .active(identity) else { return false }
        fullscreenPhase = .active(identity)
        return true
    }

    mutating func endFullscreen(_ identity: PlayerPresentationIdentity) -> Bool {
        guard accepts(identity) else { return false }
        let trackedIdentity = fullscreenPhase?.identity ?? identity
        guard fullscreenPhase != .dismissing(trackedIdentity) else { return false }
        fullscreenPhase = .dismissing(trackedIdentity)
        return true
    }

    mutating func finishFullscreenReturn(_ identity: PlayerPresentationIdentity? = nil) -> Bool {
        guard isAwaitingInlineFullscreenReturn else { return false }
        if let identity {
            guard accepts(identity) else { return false }
        }
        fullscreenPhase = nil
        return true
    }

    func accepts(_ identity: PlayerPresentationIdentity) -> Bool {
        guard fullscreenPhase?.identity.sessionID == identity.sessionID else { return false }
        guard let activePlayerID = fullscreenPhase?.identity.playerID,
              let incomingPlayerID = identity.playerID else { return true }
        return activePlayerID == incomingPlayerID
    }
}