import SwiftUI
import AVKit
import AVFoundation
import UIKit

typealias PlayerPresentationRestoreCompletion = (Bool) -> Void

enum PlayerTransientPauseSuppressionContext: String {
    case playbackLoopRestart

    var window: TimeInterval {
        switch self {
        case .playbackLoopRestart:
            return 0.75
        }
    }
}

enum PlayerPresentationEvent {
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
    let isTemporarySpeedBoostActive: () -> Bool
    let canBeginTemporarySpeedBoost: () -> Bool
    let beginTemporarySpeedBoost: () -> Bool
    let endTemporarySpeedBoost: () -> Void
    let onCreated: (AVPlayerViewController) -> Void
    let onPresentationEvent: (PlayerPresentationEvent) -> Void

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
        vc.delegate = context.coordinator
        let incomingPlayerID = ObjectIdentifier(player)
        if vc.title != title {
            vc.title = title
        }
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
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.prepareForDismantle(controller: vc)
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PlayerContainer
        weak var danmakuCanvas: DanmakuCanvasView?
        weak var subtitleOverlay: SubtitleOverlayView?
        fileprivate weak var holdSpeedBadgeView: PlayerHoldSpeedBadgeView?
        var assignedPlayerID: ObjectIdentifier?
        private var holdSpeedBadgeIsVisible = false
        private var isDismantled = false

        init(parent: PlayerContainer) {
            self.parent = parent
        }

        var shouldAllowHoldSpeedGestureHitTesting: Bool {
            !isDismantled && (parent.isTemporarySpeedBoostActive() || parent.canBeginTemporarySpeedBoost())
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
            !isDismantled && parent.canBeginTemporarySpeedBoost()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
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
    }
}
