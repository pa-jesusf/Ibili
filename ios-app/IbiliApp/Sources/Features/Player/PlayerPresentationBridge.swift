import SwiftUI
import AVKit
import AVFoundation
import UIKit

/// Drives the brief snapshot crossfade we run when the visible AVPlayer
/// instance is swapped (fast-load upgrade). Declared as a protocol so
/// the view-model can call into UIKit code without importing it as a
/// concrete type.
@MainActor
protocol PlayerSwapOverlay: AnyObject {
    /// Snapshot the current AVPlayerLayer contents, overlay them on the
    /// AVPlayerViewController, and schedule a fade-out. Idempotent: if
    /// a previous overlay is still fading we replace it.
    func beginCrossfade()
}

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

private final class PlayerHoldSpeedGestureMaskView: UIView {
    var hitTestingEnabledProvider: () -> Bool = { true }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard hitTestingEnabledProvider() else { return false }
        return super.point(inside: point, with: event)
    }
}

fileprivate final class PlayerHoldSpeedBadgeView: UIView {
    static let hiddenTransform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        .translatedBy(x: 0, y: -8)

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
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 8)

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
        HStack(spacing: 10) {
            Image(systemName: "forward.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IbiliTheme.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(IbiliTheme.accent.opacity(0.16))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("2x")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("按住加速")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .modifier(PlayerHoldSpeedBadgeBackgroundModifier())
    }
}

private struct PlayerHoldSpeedBadgeBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Liquid glass: highly translucent, picks up the video's
            // colours behind it instead of painting a solid dark slab.
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            content.background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 0.5)
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
    let danmaku: DanmakuController
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
    /// Called once, with the just-created AVPlayerViewController, so the
    /// SwiftUI parent can retain the native controller for lifecycle work.
    let onCreated: (AVPlayerViewController) -> Void
    /// Called when the bridge receives a fullscreen/PiP related callback
    /// from AVKit and needs to hand it back to SwiftUI.
    let onPresentationEvent: (PlayerPresentationEvent) -> Void
    /// Called once, after the AVPlayerViewController exists, with a
    /// handle the view-model uses to drive the swap crossfade.
    let onSwapOverlayReady: (PlayerSwapOverlay) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.loadViewIfNeeded()
        vc.player = player
        vc.title = title
        Orientation.setActivePlayerFullscreenPreference(prefersLandscapeFullscreen, for: sessionID)
        // Lock-screen metadata/control is maintained explicitly via
        // PlayerNowPlayingCoordinator. Leaving AVKit auto-sync on here
        // races with our background detach path (`vc.player = nil`) and
        // causes the system media card to briefly reappear, then get
        // cleared again by AVPlayerViewController.
        vc.updatesNowPlayingInfoCenter = false
        context.coordinator.assignedPlayerID = ObjectIdentifier(player)
        vc.delegate = context.coordinator
        DispatchQueue.main.async {
            onCreated(vc)
            onSwapOverlayReady(context.coordinator)
        }
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.videoGravity = .resizeAspect

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
            holdGesture.allowableMovement = 26
            holdGesture.cancelsTouchesInView = false
            holdGesture.delaysTouchesBegan = false
            holdGesture.delaysTouchesEnded = false
            holdGesture.delegate = context.coordinator
            gestureMask.addGestureRecognizer(holdGesture)

            let badge = PlayerHoldSpeedBadgeView()
            overlay.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.centerXAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.centerXAnchor),
                badge.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 14),
            ])
            context.coordinator.holdSpeedBadgeView = badge
            context.coordinator.setHoldSpeedBadgeVisible(isTemporarySpeedBoostActive(), animated: false)
        }
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        Orientation.setActivePlayerFullscreenPreference(prefersLandscapeFullscreen, for: sessionID)
        let incomingPlayerID = ObjectIdentifier(player)
        if vc.title != title {
            vc.title = title
        }
        // Reassign only when SwiftUI handed us a genuinely different
        // AVPlayer instance. During fullscreen transitions AVKit may
        // transiently nil out `vc.player`; we deliberately ignore that
        // path so the controller can restore its own player without us
        // restarting playback from zero. Fast-load promotion, however,
        // does intentionally swap to a new player identity.
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
        context.coordinator.setHoldSpeedBadgeVisible(isTemporarySpeedBoostActive(), animated: true)
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        Orientation.clearActivePlayerFullscreenPreference(for: coordinator.parent.sessionID)
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, PlayerSwapOverlay, UIGestureRecognizerDelegate {
        var parent: PlayerContainer
        weak var danmakuCanvas: DanmakuCanvasView?
        fileprivate weak var holdSpeedBadgeView: PlayerHoldSpeedBadgeView?
        var assignedPlayerID: ObjectIdentifier?
        /// Most recent in-flight crossfade overlay. Held weakly so we
        /// don't extend its life past `removeFromSuperview`.
        weak var activeCrossfade: UIView?
        private var transitionSnapshot: PlayerFullscreenTransitionSnapshot?
        private var holdSpeedBadgeIsVisible = false
        init(parent: PlayerContainer) { self.parent = parent }

        var shouldAllowHoldSpeedGestureHitTesting: Bool {
            parent.isTemporarySpeedBoostActive() || parent.canBeginTemporarySpeedBoost()
        }

        // MARK: PlayerSwapOverlay

        func beginCrossfade() {
            // The AVPlayerViewController itself isn't reachable from
            // here, but its `contentOverlayView` lives on the
            // hosting controller's superview chain. We snapshot via
            // `view.snapshotView(afterScreenUpdates:)` which captures
            // AVPlayerLayer contents on iOS 16+.
            guard let canvas = danmakuCanvas,
                  let containerView = canvas.superview?.superview ?? canvas.superview
            else { return }
            // Drop any stale crossfade still on screen.
            activeCrossfade?.removeFromSuperview()
            guard let snapshot = containerView.snapshotView(afterScreenUpdates: false) else {
                return
            }
            snapshot.frame = containerView.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshot.isUserInteractionEnabled = false
            containerView.addSubview(snapshot)
            activeCrossfade = snapshot
            // Hold the snapshot opaque for one runloop tick so AVKit's
            // black-frame transition is fully covered, then fade.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak snapshot] in
                guard let snapshot, snapshot.superview != nil else { return }
                UIView.animate(withDuration: 0.22,
                               delay: 0,
                               options: [.curveEaseOut, .allowUserInteraction],
                               animations: { snapshot.alpha = 0 },
                               completion: { _ in snapshot.removeFromSuperview() })
            }
        }

        func setHoldSpeedBadgeVisible(_ visible: Bool, animated: Bool) {
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
            parent.canBeginTemporarySpeedBoost()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: AVPlayerViewControllerDelegate

        func playerViewController(_ vc: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
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
            parent.onPresentationEvent(.fullscreenChanged(true, identity))
            if let requestedFullscreenMask {
                Orientation.preparePhoneFullscreenLandscape()
                Orientation.requestWithoutMaskChange(requestedFullscreenMask)
            }
            coordinator.animate(alongsideTransition: nil) { [weak self, weak vc] _ in
                guard let self, let vc else { return }
                self.restorePlaybackState(on: vc, source: "enter-completion")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak vc] in
                    guard let self, let vc else { return }
                    self.restorePlaybackState(on: vc, source: "enter-delayed")
                }
            }
        }

        func playerViewController(_ vc: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            capturePlaybackState(from: vc)
            let identity = presentationIdentity(for: vc)
            if transitionSnapshot?.wasPlaying == true {
                parent.onPresentationEvent(.suppressTransientPauseObservation(identity, .fullscreenExit))
            }
            let shouldRestorePortraitOnExit = UIDevice.current.userInterfaceIdiom == .phone
                && Orientation.supportedMask() != .portrait
            AppLog.info("player", "AVKit 即将退出全屏", metadata: [
                "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
                "supportedMask": interfaceOrientationMaskDescription(Orientation.supportedMask()),
                "rate": String(transitionSnapshot?.playbackRate ?? 1.0),
                "playing": String(transitionSnapshot?.wasPlaying ?? false),
                "requestedMask": shouldRestorePortraitOnExit ? interfaceOrientationMaskDescription(.portrait) : "none",
            ])
            coordinator.animate(alongsideTransition: nil) { [weak self, weak vc] _ in
                guard let self, let vc else { return }
                self.parent.onPresentationEvent(.fullscreenChanged(false, identity))
                if shouldRestorePortraitOnExit {
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
            AppLog.info("player", "PiP 即将开始")
            parent.onPresentationEvent(.pictureInPictureChanged(true, presentationIdentity(for: playerViewController)))
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  failedToStartPictureInPictureWithError error: Error) {
            AppLog.warning("player", "PiP 启动失败", metadata: [
                "error": error.localizedDescription,
            ])
            parent.onPresentationEvent(.pictureInPictureChanged(false, presentationIdentity(for: playerViewController)))
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            AppLog.info("player", "PiP 已停止")
            parent.onPresentationEvent(.pictureInPictureChanged(false, presentationIdentity(for: playerViewController)))
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
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
                  parent.prefersLandscapeFullscreen else { return nil }
            switch deviceOrientation {
            case .landscapeLeft:
                return .landscapeRight
            case .landscapeRight:
                return .landscapeLeft
            default:
                return .landscapeRight
            }
        }

        private func capturePlaybackState(from vc: AVPlayerViewController) {
            transitionSnapshot = PlayerFullscreenTransitionSnapshot.capture(from: vc.player)
        }

        private func restorePlaybackState(on vc: AVPlayerViewController, source: String) {
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