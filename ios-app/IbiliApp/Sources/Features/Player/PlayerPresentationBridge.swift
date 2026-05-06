import SwiftUI
import AVKit
import AVFoundation
import UIKit

@MainActor
protocol PlayerSwapOverlay: AnyObject {
    func beginCrossfade()
}

typealias PlayerPresentationRestoreCompletion = (Bool) -> Void

enum PlayerPresentationEvent {
    case pictureInPictureChanged(Bool)
    case pictureInPictureRestoreRequested(PlayerPresentationRestoreCompletion)
}

@MainActor
protocol PlayerPictureInPictureControlling: AnyObject {
    var isPictureInPicturePossible: Bool { get }
    var isPictureInPictureActive: Bool { get }
    func startPictureInPicture()
    func stopPictureInPicture()
}

final class PlayerSurfaceContainerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
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

struct PlayerContainer: UIViewRepresentable {
    let sessionID: PlayerSessionID
    let player: AVPlayer
    let title: String
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
    let onPictureInPictureControllerReady: (any PlayerPictureInPictureControlling) -> Void
    let onPresentationEvent: (PlayerPresentationEvent) -> Void
    let onSwapOverlayReady: (PlayerSwapOverlay) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PlayerSurfaceContainerView {
        let surfaceView = PlayerSurfaceContainerView()
        surfaceView.backgroundColor = .black
        surfaceView.accessibilityLabel = title
        surfaceView.playerLayer.player = player
        surfaceView.playerLayer.videoGravity = .resizeAspect
        context.coordinator.surfaceView = surfaceView
        context.coordinator.assignedPlayerID = ObjectIdentifier(player)

        let canvas = danmaku.prepareCanvas()
        canvas.blockLevel = danmakuBlockLevel
        canvas.preferredFrameRate = danmakuFrameRate
        canvas.normalStrokeWidth = CGFloat(danmakuStrokeWidth)
        canvas.normalFontWeight = danmakuFontWeight
        canvas.normalFontScale = CGFloat(danmakuFontScale)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.alpha = CGFloat(danmakuEnabled ? danmakuOpacity : 0)
        surfaceView.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: surfaceView.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor),
        ])
        context.coordinator.danmakuCanvas = canvas

        let gestureMask = PlayerHoldSpeedGestureMaskView()
        gestureMask.translatesAutoresizingMaskIntoConstraints = false
        gestureMask.backgroundColor = .clear
        gestureMask.hitTestingEnabledProvider = { [weak coordinator = context.coordinator] in
            coordinator?.shouldAllowHoldSpeedGestureHitTesting ?? false
        }
        surfaceView.addSubview(gestureMask)
        NSLayoutConstraint.activate([
            gestureMask.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
            gestureMask.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
            gestureMask.topAnchor.constraint(equalTo: surfaceView.topAnchor),
            gestureMask.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor),
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
        surfaceView.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: surfaceView.safeAreaLayoutGuide.centerXAnchor),
            badge.topAnchor.constraint(equalTo: surfaceView.safeAreaLayoutGuide.topAnchor, constant: 14),
        ])
        context.coordinator.holdSpeedBadgeView = badge
        context.coordinator.setHoldSpeedBadgeVisible(isTemporarySpeedBoostActive(), animated: false)
        context.coordinator.configurePictureInPictureController(using: surfaceView.playerLayer)

        DispatchQueue.main.async {
            if context.coordinator.pictureInPictureController != nil {
                onPictureInPictureControllerReady(context.coordinator)
            }
            onSwapOverlayReady(context.coordinator)
        }
        return surfaceView
    }

    func updateUIView(_ surfaceView: PlayerSurfaceContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.surfaceView = surfaceView
        surfaceView.accessibilityLabel = title
        let incomingPlayerID = ObjectIdentifier(player)
        if context.coordinator.assignedPlayerID != incomingPlayerID {
            surfaceView.playerLayer.player = player
            context.coordinator.assignedPlayerID = incomingPlayerID
        }
        surfaceView.playerLayer.videoGravity = .resizeAspect
        context.coordinator.danmakuCanvas?.blockLevel = danmakuBlockLevel
        context.coordinator.danmakuCanvas?.preferredFrameRate = danmakuFrameRate
        context.coordinator.danmakuCanvas?.normalStrokeWidth = CGFloat(danmakuStrokeWidth)
        context.coordinator.danmakuCanvas?.normalFontWeight = danmakuFontWeight
        context.coordinator.danmakuCanvas?.normalFontScale = CGFloat(danmakuFontScale)
        context.coordinator.danmakuCanvas?.alpha = CGFloat(danmakuEnabled ? danmakuOpacity : 0)
        context.coordinator.setHoldSpeedBadgeVisible(isTemporarySpeedBoostActive(), animated: true)
        context.coordinator.configurePictureInPictureController(using: surfaceView.playerLayer)
    }

    static func dismantleUIView(_ surfaceView: PlayerSurfaceContainerView, coordinator: Coordinator) {
        coordinator.teardown()
        surfaceView.playerLayer.player = nil
    }

    final class Coordinator: NSObject, PlayerSwapOverlay, PlayerPictureInPictureControlling, AVPictureInPictureControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PlayerContainer
        weak var surfaceView: PlayerSurfaceContainerView?
        weak var danmakuCanvas: DanmakuCanvasView?
        fileprivate weak var holdSpeedBadgeView: PlayerHoldSpeedBadgeView?
        var assignedPlayerID: ObjectIdentifier?
        weak var activeCrossfade: UIView?
        fileprivate var pictureInPictureController: AVPictureInPictureController?
        private var holdSpeedBadgeIsVisible = false

        init(parent: PlayerContainer) {
            self.parent = parent
        }

        var shouldAllowHoldSpeedGestureHitTesting: Bool {
            parent.isTemporarySpeedBoostActive() || parent.canBeginTemporarySpeedBoost()
        }

        var isPictureInPicturePossible: Bool {
            pictureInPictureController?.isPictureInPicturePossible ?? false
        }

        var isPictureInPictureActive: Bool {
            pictureInPictureController?.isPictureInPictureActive ?? false
        }

        func startPictureInPicture() {
            guard let controller = pictureInPictureController else { return }
            AppLog.info("player", "请求启动 app-owned PiP", metadata: [
                "sessionID": parent.sessionID.uuidString,
                "possible": String(controller.isPictureInPicturePossible),
            ])
            controller.startPictureInPicture()
        }

        func stopPictureInPicture() {
            guard let controller = pictureInPictureController,
                  controller.isPictureInPictureActive else { return }
            AppLog.info("player", "请求停止 app-owned PiP", metadata: [
                "sessionID": parent.sessionID.uuidString,
            ])
            controller.stopPictureInPicture()
        }

        func configurePictureInPictureController(using playerLayer: AVPlayerLayer) {
            guard AVPictureInPictureController.isPictureInPictureSupported() else {
                pictureInPictureController?.delegate = nil
                pictureInPictureController = nil
                return
            }
            if let existing = pictureInPictureController,
               existing.playerLayer === playerLayer {
                return
            }
            pictureInPictureController?.delegate = nil
            guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
                pictureInPictureController = nil
                return
            }
            controller.delegate = self
            pictureInPictureController = controller
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.onPictureInPictureControllerReady(self)
            }
        }

        func teardown() {
            pictureInPictureController?.delegate = nil
            pictureInPictureController = nil
            activeCrossfade?.removeFromSuperview()
        }

        func beginCrossfade() {
            guard let surfaceView else { return }
            activeCrossfade?.removeFromSuperview()
            guard let snapshot = surfaceView.snapshotView(afterScreenUpdates: false) else {
                return
            }
            snapshot.frame = surfaceView.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshot.isUserInteractionEnabled = false
            surfaceView.addSubview(snapshot)
            activeCrossfade = snapshot
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

        func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            AppLog.info("player", "app-owned PiP 即将开始", metadata: [
                "sessionID": parent.sessionID.uuidString,
            ])
        }

        func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            AppLog.info("player", "app-owned PiP 已开始", metadata: [
                "sessionID": parent.sessionID.uuidString,
            ])
            parent.onPresentationEvent(.pictureInPictureChanged(true))
        }

        func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                        failedToStartPictureInPictureWithError error: Error) {
            AppLog.warning("player", "app-owned PiP 启动失败", metadata: [
                "sessionID": parent.sessionID.uuidString,
                "error": error.localizedDescription,
            ])
            parent.onPresentationEvent(.pictureInPictureChanged(false))
        }

        func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            AppLog.info("player", "app-owned PiP 即将停止", metadata: [
                "sessionID": parent.sessionID.uuidString,
            ])
        }

        func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            AppLog.info("player", "app-owned PiP 已停止", metadata: [
                "sessionID": parent.sessionID.uuidString,
            ])
            parent.onPresentationEvent(.pictureInPictureChanged(false))
        }

        func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            AppLog.info("player", "app-owned PiP 请求恢复原播放器界面", metadata: [
                "sessionID": parent.sessionID.uuidString,
            ])
            parent.onPresentationEvent(.pictureInPictureRestoreRequested(completionHandler))
        }
    }
}