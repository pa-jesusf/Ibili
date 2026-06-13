import AVFoundation
import AVKit
import SwiftUI
import UIKit

@MainActor
enum Orientation {
    /// App-level orientation gate for iPhone. Normal pages stay portrait;
    /// once the native AVKit fullscreen flow starts we temporarily tighten
    /// the mask so the fullscreen controller stays landscape.
    private static var phoneSupportedMask: UIInterfaceOrientationMask = .portrait
    /// Stronger than `phoneSupportedMask`: while AVKit is presenting a
    /// landscape fullscreen controller, this lock prevents unrelated
    /// SwiftUI lifecycle callbacks from restoring portrait and lets the
    /// app-level orientation mask continue rejecting portrait auto-rotation.
    private static var activePhoneFullscreenLandscapeLock: PlayerSessionID?
    private static var activePlayerFullscreenPreference: (sessionID: PlayerSessionID, prefersLandscape: Bool)?
    private static var activePlayerPresentationRoute: PlayerSessionID?

    private static func activeForegroundWindowScene() -> UIWindowScene? {
        let foregroundScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        return foregroundScenes.first(where: { scene in
            scene.windows.contains(where: { window in
                window.isKeyWindow
                    && window.rootViewController != nil
                    && String(describing: type(of: window.rootViewController!)).contains("UIHostingController")
            })
        })
        ?? foregroundScenes.first(where: { scene in
            scene.windows.contains(where: { $0.isKeyWindow && $0.rootViewController != nil })
        })
        ?? foregroundScenes.first
    }

    static func supportedMask(for window: UIWindow? = nil) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .landscape
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        let topViewController = topPresentedViewController(from: window?.rootViewController)
        if activePhoneFullscreenLandscapeLock != nil
            || shouldForceLandscapeForExplicitFullscreen(topViewController: topViewController) {
            return .landscape
        }
        return phoneSupportedMask
    }

    static func setActivePlayerFullscreenPreference(_ prefersLandscape: Bool,
                                                    for sessionID: PlayerSessionID) {
        activePlayerFullscreenPreference = (sessionID, prefersLandscape)
    }

    static func clearActivePlayerFullscreenPreference(for sessionID: PlayerSessionID) {
        guard activePlayerFullscreenPreference?.sessionID == sessionID else { return }
        activePlayerFullscreenPreference = nil
    }

    static func activatePlayerPresentationRoute(_ sessionID: PlayerSessionID) {
        activePlayerPresentationRoute = sessionID
    }

    static func deactivatePlayerPresentationRoute(_ sessionID: PlayerSessionID) {
        guard activePlayerPresentationRoute == sessionID else { return }
        activePlayerPresentationRoute = nil
    }

    static func isActivePlayerPresentationRoute(_ sessionID: PlayerSessionID) -> Bool {
        activePlayerPresentationRoute == sessionID
    }

    static func isAVKitFullscreenVisible() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { containsAVKitFullscreenController($0.rootViewController) }
    }

    @discardableResult
    static func dismissAVKitFullscreen(animated: Bool) -> Bool {
        guard let fullscreenController = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .compactMap({ findAVKitFullscreenController($0.rootViewController) })
            .first else {
            return false
        }
        fullscreenController.dismiss(animated: animated)
        return true
    }

    private static func shouldForceLandscapeForExplicitFullscreen(topViewController: UIViewController?) -> Bool {
        guard activePlayerFullscreenPreference?.prefersLandscape == true,
              let topViewController else {
            return false
        }
        return containsAVKitFullscreenController(topViewController)
    }

    private static func containsAVKitFullscreenController(_ rootViewController: UIViewController?) -> Bool {
        findAVKitFullscreenController(rootViewController) != nil
    }

    private static func findAVKitFullscreenController(_ rootViewController: UIViewController?) -> UIViewController? {
        guard let rootViewController else { return nil }
        if isAVKitFullscreenController(rootViewController) {
            return rootViewController
        }
        if let presentedFullscreen = findAVKitFullscreenController(rootViewController.presentedViewController) {
            return presentedFullscreen
        }
        for child in rootViewController.children {
            if let childFullscreen = findAVKitFullscreenController(child) {
                return childFullscreen
            }
        }
        return nil
    }

    private static func isAVKitFullscreenController(_ viewController: UIViewController) -> Bool {
        let className = String(describing: type(of: viewController))
        return className.contains("AVFullScreen")
            || className.contains("AVFullscreen")
            || (className.contains("AVPlayer") && className.contains("FullScreen"))
    }

    /// Tighten the phone orientation mask to *only* landscape so iOS
    /// is forced to rotate the entire interface, regardless of which
    /// physical orientation the device is currently held in. iOS 16's
    /// `requestGeometryUpdate` will reject any orientation outside
    /// the supported mask, so widening the mask to `.allButUpsideDown`
    /// is what previously caused portrait-held devices to silently
    /// stay upright when the user tapped the fullscreen button. The
    /// mask is restored to `.portrait` by `request(.portrait)` on
    /// fullscreen exit.
    static func preparePhoneFullscreenLandscape() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let previousMask = phoneSupportedMask
        phoneSupportedMask = .landscape
        guard let scene = activeForegroundWindowScene() else {
            AppLog.debug("player", "收紧手机方向掩码到 landscape，强制系统横屏", metadata: [
                "maskBefore": interfaceOrientationMaskDescription(previousMask),
                "maskAfter": interfaceOrientationMaskDescription(phoneSupportedMask),
                "sceneFound": "false",
            ])
            return
        }
        let primaryWindow = scene.windows.first(where: \ .isKeyWindow) ?? scene.windows.first
        primaryWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        var metadata = sceneOrientationDebugMetadata(for: scene, rootViewController: primaryWindow?.rootViewController)
        metadata["maskBefore"] = interfaceOrientationMaskDescription(previousMask)
        metadata["maskAfter"] = interfaceOrientationMaskDescription(phoneSupportedMask)
        AppLog.debug("player", "收紧手机方向掩码到 landscape，强制系统横屏", metadata: metadata)
    }

    static func beginPhoneFullscreenLandscapeLock(for sessionID: PlayerSessionID) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let previousLock = activePhoneFullscreenLandscapeLock
        activePhoneFullscreenLandscapeLock = sessionID
        preparePhoneFullscreenLandscape()
        AppLog.debug("player", "启用手机全屏横屏锁", metadata: [
            "sessionID": sessionID.uuidString,
            "previousSessionID": previousLock?.uuidString ?? "nil",
            "supportedMask": interfaceOrientationMaskDescription(supportedMask()),
        ])
    }

    static func endPhoneFullscreenLandscapeLock(for sessionID: PlayerSessionID) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        guard activePhoneFullscreenLandscapeLock == nil
                || activePhoneFullscreenLandscapeLock == sessionID else {
            return
        }
        let previousMask = phoneSupportedMask
        activePhoneFullscreenLandscapeLock = nil
        phoneSupportedMask = .portrait
        refreshSupportedInterfaceOrientations()
        AppLog.debug("player", "解除手机全屏横屏锁", metadata: [
            "sessionID": sessionID.uuidString,
            "maskBefore": interfaceOrientationMaskDescription(previousMask),
            "maskAfter": interfaceOrientationMaskDescription(phoneSupportedMask),
        ])
    }

    static func isPhoneFullscreenLandscapeLocked(for sessionID: PlayerSessionID? = nil) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let lock = activePhoneFullscreenLandscapeLock else { return false }
        guard let sessionID else { return true }
        return lock == sessionID
    }

    private static func refreshSupportedInterfaceOrientations() {
        guard let scene = activeForegroundWindowScene() else { return }
        let primaryWindow = scene.windows.first(where: \ .isKeyWindow) ?? scene.windows.first
        primaryWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// Request a specific interface-orientation set from the active scene.
    /// On iOS 16+ this is the public API; pre-16 falls back to the legacy
    /// `UIDevice.orientation` setter.
    static func request(_ mask: UIInterfaceOrientationMask) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            requestWithoutMaskChange(.landscape)
            return
        }
        if UIDevice.current.userInterfaceIdiom == .phone {
            if activePhoneFullscreenLandscapeLock != nil, !mask.isLandscapeOnly {
                AppLog.debug("player", "忽略全屏横屏锁期间的非横屏请求", metadata: [
                    "requestedMask": interfaceOrientationMaskDescription(mask),
                    "lockedMask": interfaceOrientationMaskDescription(.landscape),
                ])
                requestWithoutMaskChange(.landscape)
                return
            }
            // Mirror the requested orientation in the mask so the
            // system actually performs the rotation: only landscape
            // when we want landscape, only portrait when we want to
            // come back. `.allButUpsideDown` was permissive enough to
            // make the geometry request a no-op on a portrait-held
            // device.
            switch mask {
            case .portrait:
                phoneSupportedMask = .portrait
            case .landscape, .landscapeLeft, .landscapeRight:
                phoneSupportedMask = .landscape
            default:
                phoneSupportedMask = mask
            }
        }
        requestWithoutMaskChange(mask)
    }

    /// Request a geometry update without changing the supported mask.
    /// Used when the mask has already been widened (e.g. by
    /// `preparePhoneFullscreenLandscape`) and we just need to
    /// trigger the rotation.
    static func requestWithoutMaskChange(_ mask: UIInterfaceOrientationMask) {
        let requestMask: UIInterfaceOrientationMask
        if UIDevice.current.userInterfaceIdiom == .pad {
            requestMask = .landscape
        } else if UIDevice.current.userInterfaceIdiom == .phone,
                  activePhoneFullscreenLandscapeLock != nil,
                  !mask.isLandscapeOnly {
            requestMask = .landscape
        } else {
            requestMask = mask
        }
        let effectiveMask: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .landscape : supportedMask()
        guard let scene = activeForegroundWindowScene() else {
            AppLog.debug("player", "请求界面方向更新", metadata: [
                "requestedMask": interfaceOrientationMaskDescription(requestMask),
                "effectiveMask": interfaceOrientationMaskDescription(effectiveMask),
                "sceneFound": "false",
            ])
            return
        }
        let primaryWindow = scene.windows.first(where: \ .isKeyWindow) ?? scene.windows.first
        if #available(iOS 16, *) {
            primaryWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            let requestedMaskDescription = interfaceOrientationMaskDescription(requestMask)
            var metadata = sceneOrientationDebugMetadata(for: scene, rootViewController: primaryWindow?.rootViewController)
            metadata["requestedMask"] = requestedMaskDescription
            metadata["effectiveMask"] = interfaceOrientationMaskDescription(effectiveMask)
            AppLog.debug("player", "请求界面方向更新", metadata: metadata)
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: requestMask)) { error in
                AppLog.warning("player", "界面方向更新被系统拒绝", metadata: [
                    "requestedMask": requestedMaskDescription,
                    "error": error.localizedDescription,
                ])
            }
            let sceneID = scene.session.persistentIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                Task { @MainActor in
                    guard let observedScene = UIApplication.shared.connectedScenes
                        .compactMap({ $0 as? UIWindowScene })
                        .first(where: { $0.session.persistentIdentifier == sceneID }) else {
                        AppLog.debug("player", "界面方向更新后观察失败", metadata: [
                            "requestedMask": requestedMaskDescription,
                            "reason": "scene-missing",
                            "scenePersistentID": sceneID,
                        ])
                        return
                    }
                    let observedWindow = observedScene.windows.first(where: \ .isKeyWindow) ?? observedScene.windows.first
                    var followUpMetadata = sceneOrientationDebugMetadata(for: observedScene, rootViewController: observedWindow?.rootViewController)
                    followUpMetadata["requestedMask"] = requestedMaskDescription
                    followUpMetadata["effectiveMask"] = interfaceOrientationMaskDescription(effectiveMask)
                    AppLog.debug("player", "界面方向更新后观察", metadata: followUpMetadata)
                }
            }
        } else {
            let value: UIDeviceOrientation
            switch requestMask {
            case .portrait:        value = .portrait
            case .landscapeLeft:   value = .landscapeRight
            case .landscapeRight:  value = .landscapeLeft
            case .landscape:       value = .landscapeLeft
            default:               value = .portrait
            }
            AppLog.debug("player", "使用旧版方式请求设备方向", metadata: [
                "requestedMask": interfaceOrientationMaskDescription(requestMask),
                "deviceOrientation": deviceOrientationDescription(value),
            ])
            UIDevice.current.setValue(value.rawValue, forKey: "orientation")
        }
    }
}

func deviceOrientationDescription(_ orientation: UIDeviceOrientation) -> String {
    switch orientation {
    case .unknown: return "unknown"
    case .portrait: return "portrait"
    case .portraitUpsideDown: return "portraitUpsideDown"
    case .landscapeLeft: return "landscapeLeft"
    case .landscapeRight: return "landscapeRight"
    case .faceUp: return "faceUp"
    case .faceDown: return "faceDown"
    @unknown default: return "future(\(orientation.rawValue))"
    }
}

func interfaceOrientationDescription(_ orientation: UIInterfaceOrientation) -> String {
    switch orientation {
    case .unknown: return "unknown"
    case .portrait: return "portrait"
    case .portraitUpsideDown: return "portraitUpsideDown"
    case .landscapeLeft: return "landscapeLeft"
    case .landscapeRight: return "landscapeRight"
    @unknown default: return "future(\(orientation.rawValue))"
    }
}

func sceneActivationStateDescription(_ state: UIScene.ActivationState) -> String {
    switch state {
    case .unattached: return "unattached"
    case .foregroundActive: return "foregroundActive"
    case .foregroundInactive: return "foregroundInactive"
    case .background: return "background"
    @unknown default: return "future"
    }
}

private func topPresentedViewController(from rootViewController: UIViewController?) -> UIViewController? {
    var current = rootViewController
    while let presented = current?.presentedViewController {
        current = presented
    }
    return current
}

func sceneOrientationDebugMetadata(for scene: UIWindowScene?,
                                   rootViewController: UIViewController? = nil) -> [String: String] {
    let primaryWindow = scene?.windows.first(where: \ .isKeyWindow) ?? scene?.windows.first
    let rootViewController = rootViewController ?? primaryWindow?.rootViewController
    let topViewController = topPresentedViewController(from: rootViewController)
    return [
        "scenePersistentID": scene?.session.persistentIdentifier ?? "nil",
        "sceneActivationState": scene.map { sceneActivationStateDescription($0.activationState) } ?? "nil",
        "sceneInterfaceOrientation": scene.map { interfaceOrientationDescription($0.interfaceOrientation) } ?? "nil",
        "sceneWindowCount": scene.map { String($0.windows.count) } ?? "0",
        "sceneKeyWindowCount": scene.map { String($0.windows.filter(\.isKeyWindow).count) } ?? "0",
        "rootViewController": rootViewController.map { String(describing: type(of: $0)) } ?? "nil",
        "rootSupportedMask": rootViewController.map { interfaceOrientationMaskDescription($0.supportedInterfaceOrientations) } ?? "nil",
        "topViewController": topViewController.map { String(describing: type(of: $0)) } ?? "nil",
        "topSupportedMask": topViewController.map { interfaceOrientationMaskDescription($0.supportedInterfaceOrientations) } ?? "nil",
    ]
}

func interfaceOrientationMaskDescription(_ mask: UIInterfaceOrientationMask) -> String {
    if mask == .portrait { return "portrait" }
    if mask == .landscape { return "landscape" }
    if mask == .allButUpsideDown { return "allButUpsideDown" }
    if mask == .all { return "all" }
    if mask == .portraitUpsideDown { return "portraitUpsideDown" }
    if mask == .landscapeLeft { return "landscapeLeft" }
    if mask == .landscapeRight { return "landscapeRight" }
    return "raw(\(mask.rawValue))"
}

@MainActor
enum PlayerFullscreenTransitionShield {
    private static weak var shieldView: UIView?
    private static var pendingHideWork: DispatchWorkItem?
    private static let fallbackDuration: TimeInterval = 1.4

    static func show(reason: String,
                     sessionID: PlayerSessionID,
                     player: AVPlayer?,
                     sourceView: UIView,
                     sourceRect: CGRect? = nil) {
        pendingHideWork?.cancel()
        pendingHideWork = nil
        guard let window = activeKeyWindow() else {
            AppLog.debug("player", "跳过全屏转场遮罩：未找到窗口", metadata: [
                "reason": reason,
                "sessionID": sessionID.uuidString,
            ])
            return
        }
        let snapshotRect = clippedSnapshotRect(in: sourceView, rect: sourceRect)
        let videoFrameImage = videoFrameImage(from: player)
        let snapshotView = videoFrameImage == nil ? snapshotView(from: sourceView, rect: snapshotRect) : nil
        let snapshotImage = videoFrameImage ?? (snapshotView == nil ? snapshotImage(from: sourceView, rect: snapshotRect) : nil)
        guard snapshotView != nil || snapshotImage != nil else {
            AppLog.debug("player", "跳过全屏转场遮罩：播放器快照不可用", metadata: [
                "reason": reason,
                "sessionID": sessionID.uuidString,
            ])
            return
        }
        let shield: PlayerFullscreenTransitionShieldView
        if let existing = shieldView as? PlayerFullscreenTransitionShieldView, existing.window === window {
            shield = existing
        } else {
            shieldView?.removeFromSuperview()
            let view = PlayerFullscreenTransitionShieldView(frame: window.bounds)
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            view.accessibilityIdentifier = "IbiliPlayerFullscreenTransitionShield"
            view.layer.zPosition = CGFloat(Float.greatestFiniteMagnitude)
            window.addSubview(view)
            shieldView = view
            shield = view
        }
        shield.update(snapshotView: snapshotView, fallbackImage: snapshotImage, aspectSize: snapshotRect.size)
        shield.alpha = 1
        window.bringSubviewToFront(shield)
        AppLog.debug("player", "显示全屏转场遮罩", metadata: [
            "hasVideoFrameImage": String(videoFrameImage != nil),
            "hasSnapshotView": String(snapshotView != nil),
            "hasFallbackImage": String(snapshotImage != nil),
            "reason": reason,
            "sessionID": sessionID.uuidString,
        ])
        scheduleFallbackHide(sessionID: sessionID)
    }

    static func hide(animated: Bool, delay: TimeInterval = 0, reason: String, sessionID: PlayerSessionID) {
        pendingHideWork?.cancel()
        let work = DispatchWorkItem {
            guard let shield = shieldView else { return }
            let remove = {
                shield.removeFromSuperview()
                if shieldView === shield {
                    shieldView = nil
                }
            }
            AppLog.debug("player", "隐藏全屏转场遮罩", metadata: [
                "animated": String(animated),
                "reason": reason,
                "sessionID": sessionID.uuidString,
            ])
            if animated {
                UIView.animate(
                    withDuration: 0.16,
                    delay: 0,
                    options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                    animations: { shield.alpha = 0 },
                    completion: { _ in remove() }
                )
            } else {
                remove()
            }
        }
        pendingHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func scheduleFallbackHide(sessionID: PlayerSessionID) {
        pendingHideWork?.cancel()
        let work = DispatchWorkItem {
            pendingHideWork = nil
            hide(animated: true, reason: "fallback", sessionID: sessionID)
        }
        pendingHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDuration, execute: work)
    }

    private static func activeKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private static func clippedSnapshotRect(in sourceView: UIView, rect sourceRect: CGRect?) -> CGRect {
        let bounds = sourceView.bounds
        let rect = sourceRect?.intersection(bounds) ?? bounds
        guard rect.width > 0, rect.height > 0, !rect.isNull else { return bounds }
        return rect
    }

    private static func snapshotView(from sourceView: UIView, rect: CGRect) -> UIView? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return sourceView.resizableSnapshotView(
            from: rect,
            afterScreenUpdates: false,
            withCapInsets: .zero
        )
    }

    private static func videoFrameImage(from player: AVPlayer?) -> UIImage? {
        guard let item = player?.currentItem else { return nil }
        let asset = item.asset
        let time = item.currentTime()
        guard time.isValid, !time.isIndefinite else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        let maxSide = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func snapshotImage(from sourceView: UIView, rect: CGRect) -> UIImage? {
        let bounds = sourceView.bounds
        guard bounds.width > 0, bounds.height > 0, rect.width > 0, rect.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: rect.size))
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            sourceView.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }
}

private final class PlayerFullscreenTransitionShieldView: UIView {
    private let imageView = UIImageView()
    private weak var currentSnapshotView: UIView?
    private var aspectSize: CGSize = CGSize(width: 16, height: 9)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clipsToBounds = true
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
    }

    func update(snapshotView: UIView?, fallbackImage: UIImage?, aspectSize: CGSize) {
        currentSnapshotView?.removeFromSuperview()
        imageView.removeFromSuperview()
        self.aspectSize = aspectSize.width > 0 && aspectSize.height > 0 ? aspectSize : CGSize(width: 16, height: 9)
        if let snapshotView {
            snapshotView.clipsToBounds = true
            addSubview(snapshotView)
            currentSnapshotView = snapshotView
        } else {
            imageView.image = fallbackImage
            addSubview(imageView)
            currentSnapshotView = imageView
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        currentSnapshotView?.frame = aspectFillRect(aspectRatio: aspectSize, insideRect: bounds)
    }

    private func aspectFillRect(aspectRatio: CGSize, insideRect rect: CGRect) -> CGRect {
        guard aspectRatio.width > 0,
              aspectRatio.height > 0,
              rect.width > 0,
              rect.height > 0 else {
            return rect
        }
        let scale = max(rect.width / aspectRatio.width, rect.height / aspectRatio.height)
        let size = CGSize(width: aspectRatio.width * scale, height: aspectRatio.height * scale)
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private extension UIInterfaceOrientationMask {
    var isLandscapeOnly: Bool {
        self == .landscape || self == .landscapeLeft || self == .landscapeRight
    }
}

extension UIDeviceOrientation {
    var isLandscapeForFullscreen: Bool {
        self == .landscapeLeft || self == .landscapeRight
    }

    var isPortraitForFullscreen: Bool {
        self == .portrait || self == .portraitUpsideDown
    }
}

func timeControlStatusDescription(_ status: AVPlayer.TimeControlStatus) -> String {
    switch status {
    case .paused:
        return "paused"
    case .waitingToPlayAtSpecifiedRate:
        return "waiting"
    case .playing:
        return "playing"
    @unknown default:
        return "future(\(status.rawValue))"
    }
}

@MainActor
enum PlayerViewLifecycleController {
    static func handleScenePhaseChange(_ phase: ScenePhase,
                                       didBootstrap: Bool,
                                       viewModel: PlayerViewModel,
                                       playerBox: PlayerVCBox,
                                       reloadPlayer: @escaping @MainActor () async -> Void) {
        // ---- Background path: keep audio rolling under lock ----
        //
        // AVPlayerViewController is wired up to auto-pause its
        // bound AVPlayer the moment iOS locks the screen, no matter
        // how the audio session is configured. The workaround is to
        // detach the AVPlayer from the VC for the duration of the
        // background phase: the player stays alive in
        // `playerBox.detachedPlayer`, the audio session (already
        // `.playback` + `.moviePlayback`) continues to route audio,
        // and only the *video* surface is torn down. We restore the
        // binding on `.active` so the user unlocking the screen sees
        // the same frame they left.
        if phase == .background,
           didBootstrap,
           !viewModel.isPictureInPictureActive,
           let vc = playerBox.vc,
           let player = vc.player,
           playerBox.detachedPlayer == nil {
            viewModel.endTemporarySpeedBoost(on: player)
            let continuationRate = viewModel.backgroundContinuationRate(for: player)
            AppLog.info("player", "锁屏后台分离 AVPlayerViewController 绑定", metadata: [
                "aid": String(viewModel.currentAid),
                "cid": String(viewModel.currentCid),
                "continuationRate": continuationRate.map { String($0) } ?? "nil",
            ])
            playerBox.detachedPlayer = player
            vc.player = nil
            // Re-issue play on the now-headless player so the OS
            // doesn't immediately stall the queue. `playImmediately`
            // is required because the player's rate is reset to 0 by
            // the OS-driven pause that races with our detach.
            if let continuationRate {
                player.playImmediately(atRate: continuationRate)
            } else {
                player.pause()
            }
            viewModel.refreshSystemMediaSession()
        }

        guard phase == .active, didBootstrap else { return }
        // Reattach any player we detached in `.background` so the
        // visible AVPlayerLayer picks back up where the audio session
        // left off.
        if let detachedPlayer = playerBox.detachedPlayer,
           let vc = playerBox.vc {
            AppLog.info("player", "前台恢复 AVPlayerViewController 绑定", metadata: [
                "aid": String(viewModel.currentAid),
                "cid": String(viewModel.currentCid),
            ])
            if vc.player !== detachedPlayer {
                vc.player = detachedPlayer
            }
            viewModel.reapplyPlaybackBehavior(to: detachedPlayer)
            playerBox.detachedPlayer = nil
            viewModel.refreshSystemMediaSession()
        }
        guard viewModel.player != nil else { return }
        // When the app returns to the foreground after a long lock the
        // local proxy may have been killed by iOS (Network framework
        // cancels listeners on suspended apps). Rebuild the
        // AVPlayerItem against a freshly-bound port so playback does
        // not silently fail with "could not load resource".
        if !viewModel.isEngineAlive {
            Task { await reloadPlayer() }
        }
        // If this session owns the active PiP window, the user
        // returning to the page should collapse PiP back into the
        // inline player instead of leaving the floating window
        // hovering on top. AVPlayerViewController has no direct stop
        // API, but flipping `allowsPictureInPicturePlayback` off and
        // back on tears the active session down cleanly. The
        // `isPictureInPictureActive` guard ensures only the
        // originating PlayerView reacts.
        if viewModel.isPictureInPictureActive,
           let vc = playerBox.vc {
            vc.allowsPictureInPicturePlayback = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                vc.allowsPictureInPicturePlayback = true
            }
        }
        viewModel.refreshSystemMediaSession()
    }

    static func handleAppear(didBootstrap: Bool,
                             viewModel: PlayerViewModel,
                             danmaku: DanmakuController,
                             resolvedAudioVolumeLinear: Float) {
        viewModel.setAudioVolumeLinear(resolvedAudioVolumeLinear)
        guard didBootstrap else { return }
        viewModel.handle(.interfaceActivated)
        if let player = viewModel.player {
            danmaku.attach(player)
        }
        viewModel.refreshSystemMediaSession()
    }

    static func handleDisappear(isPlayerPresentationActive: Bool,
                                viewModel: PlayerViewModel,
                                danmaku: DanmakuController) {
        // Only tear the danmaku pipeline down when we're truly
        // leaving the player page. AVKit's native fullscreen
        // presentation covers the SwiftUI host with its own window,
        // which fires `.onDisappear` on this view even though the
        // player (and its danmaku canvas inside `contentOverlayView`)
        // keeps running. Detaching here would invalidate the
        // CADisplayLink + periodic time observer and clear `active`,
        // leaving the canvas blank for the entire duration of
        // fullscreen — `.onAppear` doesn't fire while we're still
        // covered, so nothing would re-attach until the user exits
        // fullscreen.
        if !isPlayerPresentationActive {
            danmaku.detach()
            viewModel.handle(.interfaceDeactivated)
            Orientation.request(.portrait)
        }
        viewModel.refreshSystemMediaSession()
    }
}

final class PlayerVCBox {
    weak var vc: AVPlayerViewController?
    /// Strong reference to the AVPlayer that was temporarily
    /// detached from `vc` while the app is backgrounded / the screen
    /// is locked. iOS auto-pauses any AVPlayer that's bound to an
    /// `AVPlayerViewController` when the screen locks, even with a
    /// `.playback` audio category. Detaching the player from the VC
    /// (and holding it here so it isn't deallocated) sidesteps that
    /// behaviour so audio continues uninterrupted; we re-bind on
    /// `.active` to restore video.
    var detachedPlayer: AVPlayer?
}
