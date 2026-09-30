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

enum PlayerPictureInPictureStopReason: String, Equatable {
    case closed
    case restored
    case failedToStart

    static func resolve(restorationSucceeded: Bool, sceneReturnedFromBackground: Bool,
                        inlinePlayerIsForeground: Bool) -> Self {
        // Returning through the app icon can restore the existing inline
        // player without requesting that its navigation stack be rebuilt.
        restorationSucceeded || (sceneReturnedFromBackground && inlinePlayerIsForeground) ? .restored : .closed
    }
}

enum PlayerPictureInPictureTransition: Equatable {
    case started
    case stopped(PlayerPictureInPictureStopReason)

    var isActive: Bool {
        if case .started = self { return true }
        return false
    }
}

enum PlayerSystemTransitionRecoveryAction: Equatable {
    case none
    case rebuildSource
    case verifyPlaybackProgress
}

enum PlayerSessionEvent: Equatable {
    case interfaceActivated
    case interfaceDeactivated
    case interfaceDidAppear
    case pictureInPictureWillStop
    case pictureInPictureTransition(PlayerPictureInPictureTransition)
    case systemTransitionChanged(Bool)
    case playbackIntentChanged(PlayerIntent)
    case prepareAutoplayForMediaReplacement
    case suppressNextObservedIntent(PlayerIntent)
    case observedTimeControlStatus(AVPlayer.TimeControlStatus)

    var isPictureInPictureStop: Bool {
        if case .pictureInPictureTransition(.stopped) = self { return true }
        return false
    }
}

struct PlayerSessionBehaviorState: Equatable {
    private static let playingRecoveryProbeDelay: TimeInterval = 2
    private static let pausedSourceRebuildDelay: TimeInterval = 30

    private(set) var intent: PlayerIntent = .play
    private(set) var hasPlaybackFocus = false
    private(set) var interfaceIsActive = false
    private(set) var interfaceHasAppeared = false
    private(set) var pictureInPictureIsActive = false
    private(set) var pictureInPictureIsStopping = false
    private(set) var systemTransitionIsActive = false
    private var suppressedObservedIntent: PlayerIntent?
    private var suppressedObservedIntentExpiresAt: Date?

    var isInterfacePresentingPlayer: Bool {
        interfaceIsActive || pictureInPictureIsActive
    }

    var isSystemTransitionActive: Bool {
        systemTransitionIsActive
    }

    var shouldHoldAudioSession: Bool {
        intent == .play && hasPlaybackFocus && (interfaceIsActive || pictureInPictureIsActive)
    }

    var debugMetadata: [String: String] {
        [
            "intent": intent.rawValue,
            "hasPlaybackFocus": String(hasPlaybackFocus),
            "interfaceIsActive": String(interfaceIsActive),
            "interfaceHasAppeared": String(interfaceHasAppeared),
            "pictureInPictureIsActive": String(pictureInPictureIsActive),
            "pictureInPictureIsStopping": String(pictureInPictureIsStopping),
            "systemTransitionIsActive": String(systemTransitionIsActive),
            "suppressedObservedIntent": suppressedObservedIntent?.rawValue ?? "nil",
            "suppressedObservedIntentExpired": String(isSuppressedObservedIntentExpired),
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
        case .interfaceDidAppear:
            interfaceHasAppeared = true
            return true
        case .pictureInPictureWillStop:
            pictureInPictureIsStopping = pictureInPictureIsActive
            return true
        case .pictureInPictureTransition(let transition):
            applyPictureInPictureTransition(transition)
            return true
        case .systemTransitionChanged(let isActive):
            systemTransitionIsActive = isActive
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
        suppressedObservedIntentExpiresAt = nil
    }

    mutating func activateInterface() {
        hasPlaybackFocus = true
        interfaceIsActive = true
    }

    mutating func deactivateInterface() {
        if interfaceIsActive { interfaceHasAppeared = false }
        interfaceIsActive = false
        if !pictureInPictureIsActive {
            hasPlaybackFocus = false
        }
    }

    mutating func applyPictureInPictureTransition(_ transition: PlayerPictureInPictureTransition) {
        pictureInPictureIsStopping = false
        pictureInPictureIsActive = transition.isActive
        if transition.isActive {
            hasPlaybackFocus = true
            return
        }

        if !interfaceIsActive {
            hasPlaybackFocus = false
        }
        if case .stopped(.closed) = transition {
            intent = .pause
            suppressedObservedIntent = nil
            suppressedObservedIntentExpiresAt = nil
        }
    }

    func systemTransitionRecoveryAction(
        inactiveDuration: TimeInterval,
        engineIsAlive: Bool,
        sourceIsOffline: Bool,
        itemHasFailed: Bool = false,
        presentationNeedsRecovery: Bool = false
    ) -> PlayerSystemTransitionRecoveryAction {
        guard isInterfacePresentingPlayer else { return .none }
        if !engineIsAlive || itemHasFailed { return .rebuildSource }

        // A reachable proxy does not prove that a suspended AVPlayerItem can
        // still decode/display frames. This also applies to offline files:
        // they use the same local HLS proxy and AVKit pipeline.
        if intent == .pause, !pictureInPictureIsActive,
           presentationNeedsRecovery || inactiveDuration >= Self.pausedSourceRebuildDelay {
            return .rebuildSource
        }
        guard !sourceIsOffline else { return .none }

        if intent == .play, inactiveDuration >= Self.playingRecoveryProbeDelay {
            return .verifyPlaybackProgress
        }
        return .none
    }

    mutating func setIntent(_ intent: PlayerIntent) {
        self.intent = intent
        suppressedObservedIntent = nil
        suppressedObservedIntentExpiresAt = nil
    }

    mutating func suppressNextObservedIntent(_ intent: PlayerIntent) {
        suppressedObservedIntent = intent
        suppressedObservedIntentExpiresAt = Date().addingTimeInterval(1.25)
    }

    mutating func applyObservedTimeControlStatus(_ status: AVPlayer.TimeControlStatus) -> Bool {
        guard let observedIntent = PlayerIntent(status) else { return false }
        if isSuppressedObservedIntentExpired {
            suppressedObservedIntent = nil
            suppressedObservedIntentExpiresAt = nil
        }
        if let suppressedObservedIntent {
            self.suppressedObservedIntent = nil
            suppressedObservedIntentExpiresAt = nil
            if suppressedObservedIntent == observedIntent {
                return false
            }
        }
        // PiP remains interactive while the scene is inactive/backgrounded.
        // Its native pause/play controls are authoritative, just like inline
        // controls; only non-PiP system transition observations are ignored.
        guard (!systemTransitionIsActive || pictureInPictureIsActive),
              !pictureInPictureIsStopping,
              hasPlaybackFocus,
              (interfaceIsActive && interfaceHasAppeared) || pictureInPictureIsActive else { return false }
        intent = observedIntent
        return true
    }

    func desiredPlaybackCommand(rate: Float) -> PlayerDesiredPlaybackCommand {
        if shouldHoldAudioSession {
            return .play(rate: rate > 0 ? rate : 1.0)
        }
        return .pause
    }

    private var isSuppressedObservedIntentExpired: Bool {
        guard let suppressedObservedIntentExpiresAt else { return false }
        return Date() >= suppressedObservedIntentExpiresAt
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

struct PlayerPresentationIdentity: Equatable {
    let sessionID: PlayerSessionID
    let playerID: ObjectIdentifier?
}
