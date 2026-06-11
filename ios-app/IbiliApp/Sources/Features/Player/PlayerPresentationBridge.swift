import SwiftUI
import AVKit
import AVFoundation
import UIKit

typealias PlayerPresentationRestoreCompletion = (Bool) -> Void

enum PlayerTransientPauseSuppressionContext: String {
    case fullscreenEnter
    case fullscreenExit

    var window: TimeInterval {
        switch self {
        case .fullscreenEnter:
            return 1.0
        case .fullscreenExit:
            return 2.0
        }
    }
}

enum PlayerPresentationEvent {
    case fullscreenChanged(Bool, PlayerPresentationIdentity)
    case suppressTransientPauseObservation(PlayerPresentationIdentity, PlayerTransientPauseSuppressionContext)
    case pictureInPictureChanged(Bool, PlayerPresentationIdentity)
    case pictureInPictureRestoreRequested(PlayerPresentationIdentity, PlayerPresentationRestoreCompletion)
}

private enum PlayerFullscreenOrientationPhase: Equatable {
    case inline
    case autoEnterRequested
    case entering(exitArmed: Bool)
    case fullscreen(exitArmed: Bool)
    case exiting(exitArmed: Bool)

    var exitArmed: Bool {
        switch self {
        case .inline, .autoEnterRequested:
            return false
        case .entering(let value), .fullscreen(let value), .exiting(let value):
            return value
        }
    }

    var isManagedFullscreen: Bool {
        switch self {
        case .entering, .fullscreen, .exiting:
            return true
        case .inline, .autoEnterRequested:
            return false
        }
    }
}

private final class PlayerHoldSpeedGestureMaskView: UIView {
    var hitTestingEnabledProvider: () -> Bool = { true }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard hitTestingEnabledProvider() else { return false }
        return super.point(inside: point, with: event)
    }
}

fileprivate final class PlayerHoldSpeedBadgeView: UIView {
    static let hiddenTransform = CGAffineTransform(scaleX: 0.86, y: 0.86)

    private let hostingController = UIHostingController(rootView: PlayerHoldSpeedBadgeContent())

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
        alpha = 0
        transform = Self.hiddenTransform

        // Subtle drop shadow keeps the badge legible against bright
        // video frames without competing with the glass material.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 6)

        let host = hostingController.view!
        host.backgroundColor = .clear
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// SwiftUI body of the 2x hold-speed HUD. Adopts the iOS 26 liquid
/// glass material when available so the badge occludes as little of
/// the underlying video as possible; falls back to `.ultraThinMaterial`
/// on older systems for visual parity with the rest of the app.
private struct PlayerHoldSpeedBadgeContent: View {
    var body: some View {
        Image(systemName: "forward.fill")
            .font(.system(size: 22, weight: .bold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color(uiColor: .label))
            .frame(width: 52, height: 52)
        .modifier(PlayerHoldSpeedBadgeBackgroundModifier())
    }
}

private struct PlayerHoldSpeedBadgeBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Liquid glass: highly translucent, picks up the video's
            // colours behind it instead of painting a solid dark slab.
            content.background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.18), lineWidth: 0.5)
                    )
            )
        } else {
            content.background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .stroke(Color(uiColor: .label).opacity(0.12), lineWidth: 0.5)
                    )
            )
        }
    }
}

/// Wraps `AVPlayerViewController`. Critically, the danmaku overlay is mounted
/// inside `contentOverlayView`, which travels with the player into native
/// fullscreen — so danmaku stays visible there.
struct PlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let sessionID: PlayerSessionID
    let title: String
    let prefersLandscapeFullscreen: Bool
    let isPresentationRouteActive: Bool
    let danmaku: DanmakuController
    let subtitle: SubtitleController?
    let subtitleEnabled: Bool
    let danmakuEnabled: Bool
    let danmakuOpacity: Double
    let danmakuBlockLevel: Int
    let danmakuFrameRate: Int
    let danmakuStrokeWidth: Double
    let danmakuFontWeight: Int
    let danmakuFontScale: Double
    let isTemporarySpeedBoostActive: () -> Bool
    let canBeginTemporarySpeedBoost: () -> Bool
    let beginTemporarySpeedBoost: () -> Bool
    let endTemporarySpeedBoost: () -> Void
    let canRestorePlaybackAfterPresentation: () -> Bool
    /// Called once, with the just-created AVPlayerViewController, so the
    /// SwiftUI parent can retain the native controller for lifecycle work.
    let onCreated: (AVPlayerViewController) -> Void
    /// Called when the bridge receives a fullscreen/PiP related callback
    /// from AVKit and needs to hand it back to SwiftUI.
    let onPresentationEvent: (PlayerPresentationEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.loadViewIfNeeded()
        vc.player = player
        vc.title = title
        // Lock-screen metadata/control is maintained explicitly via
        // PlayerNowPlayingCoordinator. Leaving AVKit auto-sync on here
        // races with our background detach path (`vc.player = nil`) and
        // causes the system media card to briefly reappear, then get
        // cleared again by AVPlayerViewController.
        vc.updatesNowPlayingInfoCenter = false
        context.coordinator.assignedPlayerID = ObjectIdentifier(player)
        vc.delegate = context.coordinator
        context.coordinator.syncActivePresentationPreference()
        DispatchQueue.main.async {
            onCreated(vc)
        }
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.videoGravity = .resizeAspect
        vc.isModalInPresentation = true
        context.coordinator.syncDeviceOrientationMonitoring(controller: vc)

        // Mount the danmaku canvas directly into contentOverlayView.
        // Using a raw UIView instead of UIHostingController avoids
        // SwiftUI re-render overhead and fixes the width-shrink bug
        // after fullscreen→portrait transitions.
        let canvas = danmaku.prepareCanvas()
        canvas.blockLevel = danmakuBlockLevel
        canvas.preferredFrameRate = danmakuFrameRate
        canvas.normalStrokeWidth = CGFloat(danmakuStrokeWidth)
        canvas.normalFontWeight = danmakuFontWeight
        canvas.normalFontScale = CGFloat(danmakuFontScale)
        if let overlay = vc.contentOverlayView {
            canvas.translatesAutoresizingMaskIntoConstraints = false
            canvas.alpha = CGFloat(danmakuEnabled ? danmakuOpacity : 0)
            overlay.addSubview(canvas)
            NSLayoutConstraint.activate([
                canvas.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                canvas.topAnchor.constraint(equalTo: overlay.topAnchor),
                canvas.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
            context.coordinator.danmakuCanvas = canvas

            // Keep the gesture inside `contentOverlayView` so it
            // survives AVKit's native fullscreen hand-off. When the
            // player is paused the mask removes itself from hit-
            // testing entirely, letting iOS long-press features on
            // the paused frame keep working.
            let gestureMask = PlayerHoldSpeedGestureMaskView()
            gestureMask.translatesAutoresizingMaskIntoConstraints = false
            gestureMask.backgroundColor = .clear
            gestureMask.hitTestingEnabledProvider = { [weak coordinator = context.coordinator] in
                coordinator?.shouldAllowHoldSpeedGestureHitTesting ?? false
            }
            overlay.addSubview(gestureMask)
            NSLayoutConstraint.activate([
                gestureMask.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                gestureMask.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                gestureMask.topAnchor.constraint(equalTo: overlay.topAnchor),
                gestureMask.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
            let holdGesture = UILongPressGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleHoldSpeedGesture(_:))
            )
            holdGesture.minimumPressDuration = 0.32
            holdGesture.allowableMovement = 72
            holdGesture.cancelsTouchesInView = true
            holdGesture.delaysTouchesBegan = false
            holdGesture.delaysTouchesEnded = true
            holdGesture.delegate = context.coordinator
            gestureMask.addGestureRecognizer(holdGesture)

            let badge = PlayerHoldSpeedBadgeView()
            overlay.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.centerXAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.centerXAnchor),
                badge.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 12),
            ])
            context.coordinator.holdSpeedBadgeView = badge
            context.coordinator.setHoldSpeedBadgeVisible(isTemporarySpeedBoostActive(), animated: false)

            if let subtitle {
                let subtitleOverlay = subtitle.prepareOverlay()
                subtitleOverlay.translatesAutoresizingMaskIntoConstraints = false
                subtitleOverlay.setVisible(subtitleEnabled)
                overlay.addSubview(subtitleOverlay)
                NSLayoutConstraint.activate([
                    subtitleOverlay.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                    subtitleOverlay.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                    subtitleOverlay.topAnchor.constraint(equalTo: overlay.topAnchor),
                    subtitleOverlay.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
                ])
                context.coordinator.subtitleOverlay = subtitleOverlay
            }
        }
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncActivePresentationPreference()
        vc.delegate = context.coordinator
        let incomingPlayerID = ObjectIdentifier(player)
        if vc.title != title {
            vc.title = title
        }
        // Reassign only when SwiftUI handed us a genuinely different
        // AVPlayer instance. During fullscreen transitions AVKit may
        // transiently nil out `vc.player`; we deliberately ignore that
        // path so the controller can restore its own player without us
        // restarting playback from zero.
        if context.coordinator.assignedPlayerID != incomingPlayerID {
            vc.player = player
            context.coordinator.assignedPlayerID = incomingPlayerID
        }
        context.coordinator.danmakuCanvas?.blockLevel = danmakuBlockLevel
        context.coordinator.danmakuCanvas?.preferredFrameRate = danmakuFrameRate
        context.coordinator.danmakuCanvas?.normalStrokeWidth = CGFloat(danmakuStrokeWidth)
        context.coordinator.danmakuCanvas?.normalFontWeight = danmakuFontWeight
        context.coordinator.danmakuCanvas?.normalFontScale = CGFloat(danmakuFontScale)
        context.coordinator.danmakuCanvas?.alpha = CGFloat(danmakuEnabled ? danmakuOpacity : 0)
        context.coordinator.subtitleOverlay?.setVisible(subtitleEnabled)
        context.coordinator.setHoldSpeedBadgeVisible(isTemporarySpeedBoostActive(), animated: true)
        context.coordinator.syncDeviceOrientationMonitoring(controller: vc)
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.prepareForDismantle(controller: vc)
        Orientation.endPhoneFullscreenLandscapeLock(for: coordinator.parent.sessionID)
        Orientation.clearActivePlayerFullscreenPreference(for: coordinator.parent.sessionID)
        Orientation.deactivatePlayerPresentationRoute(coordinator.parent.sessionID)
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PlayerContainer
        weak var danmakuCanvas: DanmakuCanvasView?
        weak var subtitleOverlay: SubtitleOverlayView?
        fileprivate weak var holdSpeedBadgeView: PlayerHoldSpeedBadgeView?
        var assignedPlayerID: ObjectIdentifier?
        private var transitionSnapshot: PlayerFullscreenTransitionSnapshot?
        private var holdSpeedBadgeIsVisible = false
        private var isDismantled = false
        private var deviceOrientationObserver: NSObjectProtocol?
        private weak var playerController: AVPlayerViewController?
        private var fullscreenOrientationPhase: PlayerFullscreenOrientationPhase = .inline
        private var lastPortraitAutoExitAt: Date?
        private var lastAutomaticFullscreenRequestAt: Date?
        private var automaticFullscreenFallbackWork: DispatchWorkItem?
        init(parent: PlayerContainer) { self.parent = parent }

        private var isPresentationRouteActive: Bool {
            !isDismantled
                && parent.isPresentationRouteActive
                && Orientation.isActivePlayerPresentationRoute(parent.sessionID)
        }

        var shouldAllowHoldSpeedGestureHitTesting: Bool {
            isPresentationRouteActive && (parent.isTemporarySpeedBoostActive() || parent.canBeginTemporarySpeedBoost())
        }

        func syncActivePresentationPreference() {
            if isPresentationRouteActive {
                Orientation.setActivePlayerFullscreenPreference(parent.prefersLandscapeFullscreen, for: parent.sessionID)
            } else {
                Orientation.clearActivePlayerFullscreenPreference(for: parent.sessionID)
            }
        }

        func prepareForDismantle(controller vc: AVPlayerViewController) {
            isDismantled = true
            let playerWasAttached = vc.player != nil
            setHoldSpeedBadgeVisible(false, animated: false)
            holdSpeedBadgeView?.removeFromSuperview()
            holdSpeedBadgeView = nil
            subtitleOverlay?.removeFromSuperview()
            subtitleOverlay = nil
            danmakuCanvas?.removeFromSuperview()
            danmakuCanvas = nil
            stopDeviceOrientationMonitoring()
            cancelAutomaticFullscreenFallback()
            transitionSnapshot = nil
            vc.delegate = nil
            if playerWasAttached {
                AppLog.debug("player", "AVKit 容器拆除时保留 player 绑定，等待会话延迟销毁", metadata: [
                    "sessionID": parent.sessionID.uuidString,
                ])
            }
        }

        func setHoldSpeedBadgeVisible(_ visible: Bool, animated: Bool) {
            guard !isDismantled || !visible else { return }
            guard holdSpeedBadgeIsVisible != visible || !animated else { return }
            holdSpeedBadgeIsVisible = visible
            guard let badge = holdSpeedBadgeView else { return }
            let updates = {
                badge.alpha = visible ? 1.0 : 0.0
                badge.transform = visible ? .identity : PlayerHoldSpeedBadgeView.hiddenTransform
            }
            guard animated else {
                updates()
                return
            }
            UIView.animate(withDuration: visible ? 0.18 : 0.16,
                           delay: 0,
                           options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                           animations: updates)
        }

        @objc func handleHoldSpeedGesture(_ gesture: UILongPressGestureRecognizer) {
            guard isPresentationRouteActive else { return }
            switch gesture.state {
            case .began:
                let began = parent.beginTemporarySpeedBoost()
                if began {
                    setHoldSpeedBadgeVisible(true, animated: true)
                }
            case .ended, .cancelled, .failed:
                parent.endTemporarySpeedBoost()
                setHoldSpeedBadgeVisible(false, animated: true)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isPresentationRouteActive && parent.canBeginTemporarySpeedBoost()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        // MARK: AVPlayerViewControllerDelegate

        func playerViewController(_ vc: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            guard isPresentationRouteActive else {
                AppLog.debug("player", "忽略非当前播放器 AVKit 进入全屏回调", metadata: [
                    "sessionID": parent.sessionID.uuidString,
                ])
                return
            }
            capturePlaybackState(from: vc)
            let identity = presentationIdentity(for: vc)
            if transitionSnapshot?.wasPlaying == true {
                parent.onPresentationEvent(.suppressTransientPauseObservation(identity, .fullscreenEnter))
            }
            let currentDeviceOrientation = UIDevice.current.orientation
            let requestedFullscreenMask = requestedPhoneFullscreenMask(for: currentDeviceOrientation)
            AppLog.info("player", "AVKit 即将进入全屏", metadata: [
                "deviceOrientation": deviceOrientationDescription(currentDeviceOrientation),
                "supportedMask": interfaceOrientationMaskDescription(Orientation.supportedMask()),
                "prefersLandscapeFullscreen": String(parent.prefersLandscapeFullscreen),
                "rate": String(transitionSnapshot?.playbackRate ?? 1.0),
                "playing": String(transitionSnapshot?.wasPlaying ?? false),
                "requestedMask": requestedFullscreenMask.map(interfaceOrientationMaskDescription) ?? "none",
            ])
            if let requestedFullscreenMask {
                fullscreenOrientationPhase = .entering(exitArmed: currentDeviceOrientation.isLandscapeForFullscreen)
                cancelAutomaticFullscreenFallback()
                Orientation.beginPhoneFullscreenLandscapeLock(for: parent.sessionID)
                Orientation.requestWithoutMaskChange(requestedFullscreenMask)
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.isPresentationRouteActive,
                          self.fullscreenOrientationPhase.isManagedFullscreen else { return }
                    Orientation.requestWithoutMaskChange(requestedFullscreenMask)
                }
            }
            vc.isModalInPresentation = true
            parent.onPresentationEvent(.fullscreenChanged(true, identity))
            coordinator.animate(alongsideTransition: nil) { [weak self, weak vc] context in
                guard let self, let vc else { return }
                if context.isCancelled {
                    self.parent.onPresentationEvent(.fullscreenChanged(false, identity))
                    if requestedFullscreenMask != nil {
                        self.fullscreenOrientationPhase = .inline
                    }
                    Orientation.endPhoneFullscreenLandscapeLock(for: self.parent.sessionID)
                    Orientation.request(.portrait)
                    self.restorePlaybackState(on: vc, source: "enter-cancelled")
                    return
                }
                if let requestedFullscreenMask {
                    self.fullscreenOrientationPhase = .fullscreen(exitArmed: self.fullscreenOrientationPhase.exitArmed)
                    Orientation.requestWithoutMaskChange(requestedFullscreenMask)
                }
                self.restorePlaybackState(on: vc, source: "enter-completion")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak vc] in
                    guard let self, let vc else { return }
                    if let requestedFullscreenMask,
                       self.fullscreenOrientationPhase.isManagedFullscreen {
                        Orientation.requestWithoutMaskChange(requestedFullscreenMask)
                    }
                    self.restorePlaybackState(on: vc, source: "enter-delayed")
                }
            }
        }

        func playerViewController(_ vc: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            guard !isDismantled else { return }
            capturePlaybackState(from: vc)
            let identity = presentationIdentity(for: vc)
            vc.isModalInPresentation = false
            if transitionSnapshot?.wasPlaying == true {
                parent.onPresentationEvent(.suppressTransientPauseObservation(identity, .fullscreenExit))
            }
            let shouldRestorePortraitOnExit = fullscreenOrientationPhase.isManagedFullscreen
                || (UIDevice.current.userInterfaceIdiom == .phone
                    && Orientation.isPhoneFullscreenLandscapeLocked(for: parent.sessionID))
            let previousFullscreenOrientationPhase = fullscreenOrientationPhase
            if previousFullscreenOrientationPhase.isManagedFullscreen {
                fullscreenOrientationPhase = .exiting(exitArmed: previousFullscreenOrientationPhase.exitArmed)
            }
            AppLog.info("player", "AVKit 即将退出全屏", metadata: [
                "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
                "supportedMask": interfaceOrientationMaskDescription(Orientation.supportedMask()),
                "rate": String(transitionSnapshot?.playbackRate ?? 1.0),
                "playing": String(transitionSnapshot?.wasPlaying ?? false),
                "requestedMask": shouldRestorePortraitOnExit ? interfaceOrientationMaskDescription(.portrait) : "none",
                "orientationPhase": String(describing: previousFullscreenOrientationPhase),
            ])
            coordinator.animate(alongsideTransition: nil) { [weak self, weak vc] context in
                guard let self, let vc else { return }
                if context.isCancelled {
                    if previousFullscreenOrientationPhase.isManagedFullscreen {
                        self.fullscreenOrientationPhase = .fullscreen(exitArmed: previousFullscreenOrientationPhase.exitArmed)
                    }
                    self.restorePlaybackState(on: vc, source: "exit-cancelled")
                    return
                }
                self.parent.onPresentationEvent(.fullscreenChanged(false, identity))
                self.fullscreenOrientationPhase = .inline
                if shouldRestorePortraitOnExit {
                    Orientation.endPhoneFullscreenLandscapeLock(for: self.parent.sessionID)
                    Orientation.request(.portrait)
                }
                self.restorePlaybackState(on: vc, source: "exit-completion")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak vc] in
                    guard let self, let vc else { return }
                    self.restorePlaybackState(on: vc, source: "exit-delayed")
                }
            }
        }

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            guard !isDismantled else { return }
            AppLog.info("player", "PiP 即将开始")
            parent.onPresentationEvent(.pictureInPictureChanged(true, presentationIdentity(for: playerViewController)))
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  failedToStartPictureInPictureWithError error: Error) {
            guard !isDismantled else { return }
            AppLog.warning("player", "PiP 启动失败", metadata: [
                "error": error.localizedDescription,
            ])
            parent.onPresentationEvent(.pictureInPictureChanged(false, presentationIdentity(for: playerViewController)))
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            guard !isDismantled else { return }
            AppLog.info("player", "PiP 已停止")
            parent.onPresentationEvent(.pictureInPictureChanged(false, presentationIdentity(for: playerViewController)))
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            guard !isDismantled else {
                completionHandler(false)
                return
            }
            AppLog.info("player", "PiP 请求恢复原播放器界面")
            parent.onPresentationEvent(.pictureInPictureRestoreRequested(presentationIdentity(for: playerViewController), completionHandler))
        }

        private func presentationIdentity(for vc: AVPlayerViewController) -> PlayerPresentationIdentity {
            PlayerPresentationIdentity(
                sessionID: parent.sessionID,
                playerID: vc.player.map(ObjectIdentifier.init) ?? assignedPlayerID
            )
        }

        private func requestedPhoneFullscreenMask(for deviceOrientation: UIDeviceOrientation) -> UIInterfaceOrientationMask? {
            guard UIDevice.current.userInterfaceIdiom == .phone,
                  isPresentationRouteActive,
                  parent.prefersLandscapeFullscreen else { return nil }
            switch deviceOrientation {
            case .landscapeLeft:
                return .landscapeRight
            case .landscapeRight:
                return .landscapeLeft
            default:
                return .landscape
            }
        }

        func syncDeviceOrientationMonitoring(controller: AVPlayerViewController) {
            guard isPresentationRouteActive,
                  UIDevice.current.userInterfaceIdiom == .phone,
                  parent.prefersLandscapeFullscreen else {
                stopDeviceOrientationMonitoring()
                return
            }
            playerController = controller
            guard deviceOrientationObserver == nil else { return }
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            deviceOrientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleDeviceOrientationChange()
            }
            handleDeviceOrientationChange()
        }

        private func stopDeviceOrientationMonitoring() {
            guard let observer = deviceOrientationObserver else { return }
            NotificationCenter.default.removeObserver(observer)
            deviceOrientationObserver = nil
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            playerController = nil
            fullscreenOrientationPhase = .inline
            lastPortraitAutoExitAt = nil
            cancelAutomaticFullscreenFallback()
        }

        private func handleDeviceOrientationChange() {
            guard isPresentationRouteActive,
                  UIDevice.current.userInterfaceIdiom == .phone,
                  parent.prefersLandscapeFullscreen else { return }
            let orientation = UIDevice.current.orientation
            if orientation.isLandscapeForFullscreen {
                handleLandscapeDeviceOrientation(orientation)
            } else if orientation.isPortraitForFullscreen {
                handlePortraitDeviceOrientation(orientation)
            }
        }

        private func handleLandscapeDeviceOrientation(_ orientation: UIDeviceOrientation) {
            switch fullscreenOrientationPhase {
            case .inline:
                requestAutomaticFullscreen(for: orientation)
            case .autoEnterRequested:
                requestPhoneLandscapeOrientation(for: orientation)
            case .entering(false):
                fullscreenOrientationPhase = .entering(exitArmed: true)
                AppLog.debug("player", "全屏方向状态已见到横屏，允许后续竖屏自动退出", metadata: [
                    "deviceOrientation": deviceOrientationDescription(orientation),
                    "phase": "entering",
                    "sessionID": parent.sessionID.uuidString,
                ])
            case .fullscreen(false):
                fullscreenOrientationPhase = .fullscreen(exitArmed: true)
                AppLog.debug("player", "全屏方向状态已见到横屏，允许后续竖屏自动退出", metadata: [
                    "deviceOrientation": deviceOrientationDescription(orientation),
                    "phase": "fullscreen",
                    "sessionID": parent.sessionID.uuidString,
                ])
            case .entering(true), .fullscreen(true), .exiting:
                break
            }
        }

        private func handlePortraitDeviceOrientation(_ orientation: UIDeviceOrientation) {
            switch fullscreenOrientationPhase {
            case .autoEnterRequested:
                fullscreenOrientationPhase = .inline
                cancelAutomaticFullscreenFallback()
                Orientation.request(.portrait)
            case .entering(let exitArmed), .fullscreen(let exitArmed):
                guard exitArmed else {
                    AppLog.debug("player", "忽略全屏入口前已有的竖屏姿态", metadata: [
                        "deviceOrientation": deviceOrientationDescription(orientation),
                        "phase": String(describing: fullscreenOrientationPhase),
                        "sessionID": parent.sessionID.uuidString,
                    ])
                    return
                }
                exitFullscreenForPortraitDeviceOrientation(orientation)
            case .inline, .exiting:
                break
            }
        }

        private func requestAutomaticFullscreen(for orientation: UIDeviceOrientation) {
            guard isPresentationRouteActive,
                  let controller = playerController,
                  controller.viewIfLoaded?.window != nil else { return }
            let now = Date()
            if let lastAutomaticFullscreenRequestAt,
               now.timeIntervalSince(lastAutomaticFullscreenRequestAt) < 0.9 {
                return
            }
            lastAutomaticFullscreenRequestAt = now
            fullscreenOrientationPhase = .autoEnterRequested
            requestPhoneLandscapeOrientation(for: orientation)
            AppLog.info("player", "检测到手机横屏，自动请求 AVKit 全屏", metadata: [
                "deviceOrientation": deviceOrientationDescription(orientation),
                "sessionID": parent.sessionID.uuidString,
            ])
            guard requestNativeFullscreen(controller: controller, animated: true, reason: "device-landscape") else {
                fullscreenOrientationPhase = .inline
                Orientation.request(.portrait)
                return
            }
            scheduleAutomaticFullscreenFallback()
        }

        private func requestPhoneLandscapeOrientation(for orientation: UIDeviceOrientation) {
            guard isPresentationRouteActive else { return }
            let mask = requestedPhoneFullscreenMask(for: orientation) ?? .landscapeRight
            Orientation.preparePhoneFullscreenLandscape()
            Orientation.requestWithoutMaskChange(mask)
        }

        private func requestNativeFullscreen(controller: AVPlayerViewController,
                                             animated: Bool,
                                             reason: String) -> Bool {
            guard isPresentationRouteActive,
                  controller.viewIfLoaded?.window != nil else {
                AppLog.debug("player", "跳过非当前播放器 AVKit 全屏请求", metadata: [
                    "reason": reason,
                    "sessionID": parent.sessionID.uuidString,
                ])
                return false
            }
            let selector = NSSelectorFromString("enterFullScreenAnimated:completionHandler:")
            guard controller.responds(to: selector),
                  let implementation = controller.method(for: selector) else {
                AppLog.warning("player", "当前系统不支持程序化进入 AVKit 全屏", metadata: [
                    "reason": reason,
                    "selector": "enterFullScreenAnimated:completionHandler:",
                    "sessionID": parent.sessionID.uuidString,
                ])
                return false
            }
            typealias EnterFullscreenFunction = @convention(c) (AnyObject, Selector, Bool, AnyObject?) -> Void
            let function = unsafeBitCast(implementation, to: EnterFullscreenFunction.self)
            function(controller, selector, animated, nil)
            return true
        }

        private func scheduleAutomaticFullscreenFallback() {
            cancelAutomaticFullscreenFallback()
            let requestedSessionID = parent.sessionID
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.isPresentationRouteActive,
                      self.parent.sessionID == requestedSessionID,
                      self.fullscreenOrientationPhase == .autoEnterRequested else { return }
                self.fullscreenOrientationPhase = .inline
                if !Orientation.isAVKitFullscreenVisible() {
                    Orientation.request(.portrait)
                    AppLog.warning("player", "自动进入 AVKit 全屏未完成，已恢复竖屏", metadata: [
                        "sessionID": requestedSessionID.uuidString,
                    ])
                }
            }
            automaticFullscreenFallbackWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }

        private func cancelAutomaticFullscreenFallback() {
            automaticFullscreenFallbackWork?.cancel()
            automaticFullscreenFallbackWork = nil
        }

        private func exitFullscreenForPortraitDeviceOrientation(_ orientation: UIDeviceOrientation) {
            guard isPresentationRouteActive else { return }
            let now = Date()
            if let lastPortraitAutoExitAt,
               now.timeIntervalSince(lastPortraitAutoExitAt) < 0.8 {
                return
            }
            lastPortraitAutoExitAt = now
            fullscreenOrientationPhase = .exiting(exitArmed: true)
            AppLog.info("player", "检测到手机竖屏，自动退出 AVKit 全屏", metadata: [
                "deviceOrientation": deviceOrientationDescription(orientation),
                "sessionID": parent.sessionID.uuidString,
            ])
            if !Orientation.dismissAVKitFullscreen(animated: true) {
                playerController?.dismiss(animated: true)
            }
        }

        private func capturePlaybackState(from vc: AVPlayerViewController) {
            transitionSnapshot = PlayerFullscreenTransitionSnapshot.capture(from: vc.player)
        }

        private func restorePlaybackState(on vc: AVPlayerViewController, source: String) {
            guard isPresentationRouteActive else { return }
            guard parent.canRestorePlaybackAfterPresentation() else {
                AppLog.debug("player", "跳过 AVKit fullscreen 播放恢复", metadata: [
                    "reason": "session-closing",
                    "source": source,
                    "sessionID": parent.sessionID.uuidString,
                ])
                return
            }
            guard let player = vc.player else {
                AppLog.debug("player", "跳过 AVKit fullscreen 播放恢复", metadata: [
                    "reason": "vc-player-nil",
                    "source": source,
                    "sessionID": parent.sessionID.uuidString,
                ])
                return
            }
            guard case .play(let rate)? = transitionSnapshot?.desiredPlaybackCommand(for: player) else {
                AppLog.debug("player", "跳过 AVKit fullscreen 播放恢复", metadata: [
                    "reason": "snapshot-not-playing",
                    "source": source,
                    "sessionID": parent.sessionID.uuidString,
                    "timeControlStatus": timeControlStatusDescription(player.timeControlStatus),
                    "playerRate": String(player.rate),
                ])
                return
            }
            AppLog.debug("player", "执行 AVKit fullscreen 播放恢复", metadata: [
                "source": source,
                "sessionID": parent.sessionID.uuidString,
                "timeControlStatus": timeControlStatusDescription(player.timeControlStatus),
                "playerRate": String(player.rate),
                "restoreRate": String(rate),
            ])
            player.playImmediately(atRate: rate)
        }
    }
}
