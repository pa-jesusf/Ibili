import SwiftUI
import AVKit
import AVFoundation
import UIKit

typealias PlayerPresentationRestoreCompletion = (Bool) -> Void

enum PlayerTransientPauseSuppressionContext: String {
    case playbackLoopRestart
    case nativeFullscreenExit

    var window: TimeInterval {
        switch self {
        case .playbackLoopRestart:
            return 0.75
        case .nativeFullscreenExit:
            return 1.25
        }
    }
}

enum PlayerPresentationEvent {
    case pictureInPictureWillStop(PlayerPresentationIdentity)
    case pictureInPictureTransition(PlayerPictureInPictureTransition, PlayerPresentationIdentity)
    case pictureInPictureRestoreRequested(PlayerPresentationIdentity, PlayerPresentationRestoreCompletion)
    case nativeFullscreenWillBegin(PlayerPresentationIdentity)
    case nativeFullscreenDidBegin(PlayerPresentationIdentity)
    case nativeFullscreenEntryWasCancelled(PlayerPresentationIdentity)
    case nativeFullscreenExitWillBegin(PlayerPresentationIdentity, shouldResumePlayback: Bool)
    case nativeFullscreenExitDidEnd(PlayerPresentationIdentity, shouldResumePlayback: Bool)
    case nativeFullscreenExitWasCancelled(PlayerPresentationIdentity, shouldResumePlayback: Bool)
}

private final class PlayerHoldSpeedGestureMaskView: UIView {
    var hitTestingEnabledProvider: () -> Bool = { true }
    var hasTimecodeAtPoint: (CGPoint) -> Bool = { _ in false }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard hitTestingEnabledProvider() || hasTimecodeAtPoint(point) else { return false }
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

struct PlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let sessionID: PlayerSessionID
    let title: String
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
    var sourceVideoSizeHint: CGSize? = nil
    let isTemporarySpeedBoostActive: () -> Bool
    let canBeginTemporarySpeedBoost: () -> Bool
    let beginTemporarySpeedBoost: () -> Bool
    let endTemporarySpeedBoost: () -> Void
    var shouldResumePlaybackAfterNativeFullscreenExit: () -> Bool = { false }
    var isPlayerRouteForeground: () -> Bool = { false }
    let onCreated: (AVPlayerViewController) -> Void
    let onPresentationEvent: (PlayerPresentationEvent) -> Void
    var onSeekToTime: ((Int64) -> Void)? = nil
    var sponsorBlock: SponsorBlockPlaybackCoordinator? = nil
    var interactiveVideo: InteractiveVideoCoordinator? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.loadViewIfNeeded()
        vc.player = player
        vc.title = title
        vc.updatesNowPlayingInfoCenter = false
        context.coordinator.assignedPlayerID = ObjectIdentifier(player)
        context.coordinator.observePresentationSize(of: player)
        vc.delegate = context.coordinator
        DispatchQueue.main.async {
            onCreated(vc)
        }
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.videoGravity = .resizeAspect

        let canvas = danmaku.prepareCanvas()
        canvas.renderingEnabled = danmakuEnabled && danmakuOpacity > 0
        canvas.blockLevel = danmakuBlockLevel
        canvas.preferredFrameRate = danmakuFrameRate
        canvas.normalStrokeWidth = CGFloat(danmakuStrokeWidth)
        canvas.normalFontWeight = danmakuFontWeight
        canvas.normalFontScale = CGFloat(danmakuFontScale)
        if let overlay = vc.contentOverlayView {
            canvas.alpha = CGFloat(danmakuEnabled ? danmakuOpacity : 0)
            let danmakuOverlay = PlayerDanmakuOverlayView(canvas: canvas)
            overlay.addSubview(danmakuOverlay)
            NSLayoutConstraint.activate([
                danmakuOverlay.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                danmakuOverlay.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                danmakuOverlay.topAnchor.constraint(equalTo: overlay.topAnchor),
                danmakuOverlay.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
            context.coordinator.danmakuCanvas = canvas
            context.coordinator.danmakuOverlay = danmakuOverlay

            let gestureMask = PlayerHoldSpeedGestureMaskView()
            gestureMask.translatesAutoresizingMaskIntoConstraints = false
            gestureMask.backgroundColor = .clear
            gestureMask.hitTestingEnabledProvider = { [weak coordinator = context.coordinator] in
                coordinator?.shouldAllowHoldSpeedGestureHitTesting ?? false
            }
            gestureMask.hasTimecodeAtPoint = { [weak canvas, weak gestureMask] point in
                guard let canvas, let gestureMask else { return false }
                return canvas.seekTarget(at: canvas.convert(point, from: gestureMask)) != nil
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
            let timecodeTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDanmakuTimecode(_:)))
            timecodeTap.delegate = context.coordinator
            timecodeTap.require(toFail: holdGesture)
            gestureMask.addGestureRecognizer(timecodeTap)
            context.coordinator.timecodeTap = timecodeTap

            let badge = PlayerHoldSpeedBadgeView()
            overlay.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.centerXAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.centerXAnchor),
                badge.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 12),
            ])
            context.coordinator.holdSpeedBadgeView = badge
            context.coordinator.setHoldSpeedBadgeVisible(isTemporarySpeedBoostActive(), animated: false)

            if let sponsorBlock {
                let badge = SponsorBlockBadgeView(coordinator: sponsorBlock)
                overlay.addSubview(badge)
                NSLayoutConstraint.activate([
                    badge.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                    badge.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -12),
                    badge.widthAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.widthAnchor, constant: -24),
                ])
                context.coordinator.sponsorBadge = badge
            }

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
            if let interactiveVideo {
                let anchor = InteractiveVideoWindowAnchor(coordinator: interactiveVideo)
                overlay.addSubview(anchor)
                context.coordinator.interactiveWindowAnchor = anchor
            }
        }
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        vc.delegate = context.coordinator
        let incomingPlayerID = ObjectIdentifier(player)
        if vc.title != title {
            vc.title = title
        }
        if context.coordinator.assignedPlayerID != incomingPlayerID {
            vc.player = player
            context.coordinator.assignedPlayerID = incomingPlayerID
            context.coordinator.observePresentationSize(of: player)
        }
        context.coordinator.refreshFullscreenOrientationIfNeeded(controller: vc)
        context.coordinator.danmakuCanvas?.blockLevel = danmakuBlockLevel
        context.coordinator.danmakuCanvas?.preferredFrameRate = danmakuFrameRate
        context.coordinator.danmakuCanvas?.normalStrokeWidth = CGFloat(danmakuStrokeWidth)
        context.coordinator.danmakuCanvas?.normalFontWeight = danmakuFontWeight
        context.coordinator.danmakuCanvas?.normalFontScale = CGFloat(danmakuFontScale)
        context.coordinator.danmakuCanvas?.alpha = CGFloat(danmakuEnabled ? danmakuOpacity : 0)
        context.coordinator.danmakuCanvas?.renderingEnabled = danmakuEnabled && danmakuOpacity > 0
        context.coordinator.subtitleOverlay?.setVisible(subtitleEnabled)
        context.coordinator.setHoldSpeedBadgeVisible(isTemporarySpeedBoostActive(), animated: true)
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.prepareForDismantle(controller: vc)
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PlayerContainer
        weak var danmakuCanvas: DanmakuCanvasView?
        weak var danmakuOverlay: PlayerDanmakuOverlayView?
        weak var subtitleOverlay: SubtitleOverlayView?
        weak var sponsorBadge: SponsorBlockBadgeView?
        weak var interactiveWindowAnchor: InteractiveVideoWindowAnchor?
        fileprivate weak var holdSpeedBadgeView: PlayerHoldSpeedBadgeView?
        var assignedPlayerID: ObjectIdentifier?
        private var holdSpeedBadgeIsVisible = false
        private var isDismantled = false
        fileprivate weak var timecodeTap: UITapGestureRecognizer?
        private var pendingDanmakuSeek: (seconds: Int64, player: AVPlayer, item: AVPlayerItem)?
        private var pictureInPictureRestoreSucceeded = false
        private var pictureInPictureSceneReturnedFromBackground = false
        private var currentItemObservation: NSKeyValueObservation?
        private var presentationSizeObservation: NSKeyValueObservation?
        private var fullscreenOrientationOwner: PlayerFullscreenOrientationOwner?
        private var fullscreenTransitionState = PlayerFullscreenTransitionState()
        private var entryInterfaceOrientation: UIInterfaceOrientation?

        init(parent: PlayerContainer) {
            self.parent = parent
        }

        var shouldAllowHoldSpeedGestureHitTesting: Bool {
            !isDismantled && (parent.isTemporarySpeedBoostActive() || parent.canBeginTemporarySpeedBoost())
        }

        func prepareForDismantle(controller vc: AVPlayerViewController) {
            isDismantled = true
            resetPictureInPictureRestoration()
            pendingDanmakuSeek = nil
            fullscreenTransitionState.reset()
            entryInterfaceOrientation = nil
            releaseFullscreenOrientationLease()
            currentItemObservation?.invalidate()
            currentItemObservation = nil
            presentationSizeObservation?.invalidate()
            presentationSizeObservation = nil
            let playerWasAttached = vc.player != nil
            setHoldSpeedBadgeVisible(false, animated: false)
            holdSpeedBadgeView?.removeFromSuperview()
            holdSpeedBadgeView = nil
            subtitleOverlay?.removeFromSuperview()
            subtitleOverlay = nil
            sponsorBadge?.removeFromSuperview()
            sponsorBadge = nil
            interactiveWindowAnchor?.invalidate()
            interactiveWindowAnchor?.removeFromSuperview()
            interactiveWindowAnchor = nil
            danmakuCanvas?.removeFromSuperview()
            danmakuCanvas = nil
            danmakuOverlay?.removeFromSuperview()
            danmakuOverlay = nil
            vc.delegate = nil
            if playerWasAttached {
                vc.player = nil
                assignedPlayerID = nil
                AppLog.debug("player", "AVKit 容器拆除时断开 player 绑定", metadata: [
                    "sessionID": parent.sessionID.uuidString,
                ])
            }
        }

        func observePresentationSize(of player: AVPlayer) {
            currentItemObservation?.invalidate()
            presentationSizeObservation?.invalidate()
            observePresentationSize(of: player.currentItem)
            currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async {
                    guard let self,
                          !self.isDismantled,
                          self.assignedPlayerID == ObjectIdentifier(player) else { return }
                    self.observePresentationSize(of: player.currentItem)
                    self.refreshFullscreenOrientationIfNeeded()
                }
            }
        }

        private func observePresentationSize(of item: AVPlayerItem?) {
            presentationSizeObservation?.invalidate()
            presentationSizeObservation = nil
            guard let item else { return }
            presentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.refreshFullscreenOrientationIfNeeded()
                }
            }
        }

        func refreshFullscreenOrientationIfNeeded(controller: AVPlayerViewController? = nil) {
            guard !isDismantled,
                  fullscreenTransitionState.isFullscreen,
                  let owner = fullscreenOrientationOwner,
                  let controller = controller ?? PlayerFullscreenOrientationPolicy.shared.controller(for: owner) else {
                return
            }
            PlayerFullscreenOrientationPolicy.shared.update(
                owner: owner,
                ownerController: controller,
                target: resolvedFullscreenOrientation(for: controller)
            )
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
            guard !isDismantled else { return }
            switch gesture.state {
            case .began:
                guard parent.beginTemporarySpeedBoost() else { return }
                setHoldSpeedBadgeVisible(true, animated: true)
            case .ended, .cancelled, .failed:
                parent.endTemporarySpeedBoost()
                setHoldSpeedBadgeVisible(false, animated: true)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === timecodeTap { return !isDismantled && pendingDanmakuSeek != nil }
            return !isDismantled && parent.canBeginTemporarySpeedBoost()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard gestureRecognizer === timecodeTap else { return true }
            pendingDanmakuSeek = nil
            guard !isDismantled, parent.danmakuEnabled,
                  let canvas = danmakuCanvas, let seconds = canvas.seekTarget(at: touch.location(in: canvas)),
                  let item = parent.player.currentItem, parent.onSeekToTime != nil else { return false }
            pendingDanmakuSeek = (seconds, parent.player, item)
            return true
        }

        @objc func handleDanmakuTimecode(_ gesture: UITapGestureRecognizer) {
            defer { pendingDanmakuSeek = nil }
            guard gesture.state == .ended, !isDismantled, let target = pendingDanmakuSeek,
                  parent.player === target.player, parent.player.currentItem === target.item else { return }
            parent.onSeekToTime?(target.seconds)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            danmakuCanvas?.presentationAllowsRendering = false
            guard !isDismantled else { return }
            resetPictureInPictureRestoration()
            if let scene = playerViewController.viewIfLoaded?.window?.windowScene {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(pictureInPictureSceneWillEnterForeground),
                    name: UIScene.willEnterForegroundNotification, object: scene
                )
            }
            AppLog.info("player", "PiP 即将开始")
            parent.onPresentationEvent(.pictureInPictureTransition(.started, presentationIdentity(for: playerViewController)))
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  failedToStartPictureInPictureWithError error: Error) {
            danmakuCanvas?.presentationAllowsRendering = true
            guard !isDismantled else { return }
            resetPictureInPictureRestoration()
            AppLog.warning("player", "PiP 启动失败", metadata: [
                "error": error.localizedDescription,
            ])
            parent.onPresentationEvent(.pictureInPictureTransition(
                .stopped(.failedToStart),
                presentationIdentity(for: playerViewController)
            ))
        }

        func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            guard !isDismantled else { return }
            parent.onPresentationEvent(.pictureInPictureWillStop(presentationIdentity(for: playerViewController)))
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            danmakuCanvas?.presentationAllowsRendering = true
            guard !isDismantled else { return }
            let sceneState = playerViewController.viewIfLoaded?.window?.windowScene?.activationState
            let inlinePlayerIsForeground = parent.isPlayerRouteForeground()
                && (sceneState == .foregroundActive || sceneState == .foregroundInactive)
            let reason = PlayerPictureInPictureStopReason.resolve(
                restorationSucceeded: pictureInPictureRestoreSucceeded,
                sceneReturnedFromBackground: pictureInPictureSceneReturnedFromBackground,
                inlinePlayerIsForeground: inlinePlayerIsForeground
            )
            resetPictureInPictureRestoration()
            AppLog.info("player", "PiP 已停止", metadata: ["reason": reason.rawValue])
            parent.onPresentationEvent(.pictureInPictureTransition(
                .stopped(reason),
                presentationIdentity(for: playerViewController)
            ))
        }

        @objc private func pictureInPictureSceneWillEnterForeground(_ notification: Notification) {
            guard !isDismantled else { return }
            pictureInPictureSceneReturnedFromBackground = true
        }

        private func resetPictureInPictureRestoration() {
            NotificationCenter.default.removeObserver(self, name: UIScene.willEnterForegroundNotification, object: nil)
            pictureInPictureRestoreSucceeded = false
            pictureInPictureSceneReturnedFromBackground = false
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            guard !isDismantled else {
                completionHandler(false)
                return
            }
            AppLog.info("player", "PiP 请求恢复原播放器界面")
            parent.onPresentationEvent(.pictureInPictureRestoreRequested(
                presentationIdentity(for: playerViewController),
                { [weak self] restored in
                    self?.pictureInPictureRestoreSucceeded = restored
                    completionHandler(restored)
                }
            ))
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            guard !isDismantled else { return }
            let identity = presentationIdentity(for: playerViewController)
            let transitionRevision = fullscreenTransitionState.beginEntry()
            entryInterfaceOrientation = PlayerFullscreenOrientationPolicy.shared.currentInterfaceOrientation(
                for: playerViewController
            )
            releaseFullscreenOrientationLease()
            let fullscreenController = coordinator.viewController(forKey: .to) ?? playerViewController
            fullscreenOrientationOwner = PlayerFullscreenOrientationPolicy.shared.acquire(
                sessionID: identity.sessionID,
                ownerController: playerViewController,
                orientationController: fullscreenController,
                target: resolvedFullscreenOrientation(for: playerViewController),
                entryOrientation: entryInterfaceOrientation ?? .portrait
            )
            if fullscreenOrientationOwner == nil,
               UIDevice.current.userInterfaceIdiom == .phone {
                AppLog.warning("player", "原生全屏开始时未找到所属 windowScene", metadata: [
                    "sessionID": identity.sessionID.uuidString,
                ])
            }
            AppLog.debug("player", "AVKit 原生全屏即将进入", metadata: [
                "sessionID": identity.sessionID.uuidString,
            ])
            parent.onPresentationEvent(.nativeFullscreenWillBegin(identity))
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self, !self.isDismantled else { return }
                guard self.fullscreenTransitionState.finishEntry(
                    revision: transitionRevision,
                    cancelled: context.isCancelled
                ) else { return }
                guard !context.isCancelled else {
                    self.releaseFullscreenOrientationLease()
                    self.entryInterfaceOrientation = nil
                    self.parent.onPresentationEvent(.nativeFullscreenEntryWasCancelled(identity))
                    return
                }
                if let owner = self.fullscreenOrientationOwner {
                    PlayerFullscreenOrientationPolicy.shared.beginInteractiveRotation(owner: owner)
                } else {
                    let fullscreenController = context.viewController(forKey: .to) ?? playerViewController
                    self.fullscreenOrientationOwner = PlayerFullscreenOrientationPolicy.shared.acquire(
                        sessionID: identity.sessionID,
                        ownerController: playerViewController,
                        orientationController: fullscreenController,
                        target: self.resolvedFullscreenOrientation(for: playerViewController),
                        entryOrientation: self.entryInterfaceOrientation ?? .portrait
                    )
                    if let owner = self.fullscreenOrientationOwner {
                        PlayerFullscreenOrientationPolicy.shared.beginInteractiveRotation(owner: owner)
                    }
                }
                if self.fullscreenOrientationOwner == nil,
                   UIDevice.current.userInterfaceIdiom == .phone {
                    AppLog.warning("player", "原生全屏完成后仍未找到所属 windowScene", metadata: [
                        "sessionID": identity.sessionID.uuidString,
                    ])
                }
                self.parent.onPresentationEvent(.nativeFullscreenDidBegin(identity))
            }
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            guard !isDismantled else { return }
            let identity = presentationIdentity(for: playerViewController)
            let transitionRevision = fullscreenTransitionState.beginExit()
            let shouldResumePlayback = parent.shouldResumePlaybackAfterNativeFullscreenExit()
            let fullscreenController = fullscreenOrientationOwner.flatMap {
                PlayerFullscreenOrientationPolicy.shared.orientationController(for: $0)
            } ?? coordinator.viewController(forKey: .from) ?? playerViewController
            if let owner = fullscreenOrientationOwner {
                PlayerFullscreenOrientationPolicy.shared.beginRestoringExitOrientation(owner: owner)
            }
            AppLog.debug("player", "AVKit 原生全屏即将退出", metadata: [
                "sessionID": identity.sessionID.uuidString,
                "shouldResumePlayback": String(shouldResumePlayback),
            ])
            parent.onPresentationEvent(.nativeFullscreenExitWillBegin(identity, shouldResumePlayback: shouldResumePlayback))
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self, !self.isDismantled else { return }
                guard self.fullscreenTransitionState.finishExit(
                    revision: transitionRevision,
                    cancelled: context.isCancelled
                ) else { return }
                if context.isCancelled {
                    if let owner = self.fullscreenOrientationOwner {
                        PlayerFullscreenOrientationPolicy.shared.resumeInteractiveRotation(owner: owner)
                    } else {
                        let currentOrientation = PlayerFullscreenOrientationPolicy.shared.currentInterfaceOrientation(
                            for: playerViewController
                        ) ?? self.entryInterfaceOrientation ?? .portrait
                        self.fullscreenOrientationOwner = PlayerFullscreenOrientationPolicy.shared.acquire(
                            sessionID: identity.sessionID,
                            ownerController: playerViewController,
                            orientationController: fullscreenController,
                            target: currentOrientation.isPortrait ? .portrait : .landscape,
                            entryOrientation: self.entryInterfaceOrientation ?? .portrait,
                            preferredLandscapeOrientation: currentOrientation
                        )
                        if let owner = self.fullscreenOrientationOwner {
                            PlayerFullscreenOrientationPolicy.shared.beginInteractiveRotation(owner: owner)
                        }
                    }
                    self.parent.onPresentationEvent(.nativeFullscreenExitWasCancelled(
                        identity,
                        shouldResumePlayback: shouldResumePlayback
                    ))
                    return
                }
                if let owner = self.fullscreenOrientationOwner {
                    PlayerFullscreenOrientationPolicy.shared.finishRestoringExitOrientation(owner: owner)
                }
                self.entryInterfaceOrientation = nil
                self.parent.onPresentationEvent(.nativeFullscreenExitDidEnd(identity, shouldResumePlayback: shouldResumePlayback))
            }
        }

        private func resolvedFullscreenOrientation(
            for controller: AVPlayerViewController
        ) -> PlayerFullscreenContentOrientation {
            PlayerFullscreenOrientationResolver.contentOrientation(
                presentationSize: controller.player?.currentItem?.presentationSize ?? .zero,
                sourceSizeHint: parent.sourceVideoSizeHint,
                unknownFallback: .landscape
            )
        }

        private func releaseFullscreenOrientationLease() {
            guard let owner = fullscreenOrientationOwner else { return }
            PlayerFullscreenOrientationPolicy.shared.release(owner: owner)
            fullscreenOrientationOwner = nil
        }

        private func presentationIdentity(for vc: AVPlayerViewController) -> PlayerPresentationIdentity {
            PlayerPresentationIdentity(
                sessionID: parent.sessionID,
                playerID: vc.player.map(ObjectIdentifier.init) ?? assignedPlayerID
            )
        }
    }
}
