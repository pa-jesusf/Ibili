import AVFoundation
import AVKit
import SwiftUI
import UIKit

@MainActor
enum Orientation {
    /// App-level orientation gate for iPhone. Normal pages stay portrait;
    /// once the native AVKit fullscreen flow starts we temporarily widen
    /// the mask so the fullscreen controller can rotate to landscape.
    private static var phoneSupportedMask: UIInterfaceOrientationMask = .portrait
    private static var activePlayerFullscreenPreference: (sessionID: PlayerSessionID, prefersLandscape: Bool)?

    private static func activeForegroundWindowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
    }

    static func supportedMask(for window: UIWindow? = nil) -> UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        let topViewController = topPresentedViewController(from: window?.rootViewController)
        if shouldForceLandscapeForExplicitFullscreen(topViewController: topViewController) {
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

    private static func shouldForceLandscapeForExplicitFullscreen(topViewController: UIViewController?) -> Bool {
        guard activePlayerFullscreenPreference?.prefersLandscape == true,
              let topViewController else {
            return false
        }
        return String(describing: type(of: topViewController)) == "AVFullScreenViewController"
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

    /// Request a specific interface-orientation set from the active scene.
    /// On iOS 16+ this is the public API; pre-16 falls back to the legacy
    /// `UIDevice.orientation` setter.
    static func request(_ mask: UIInterfaceOrientationMask) {
        if UIDevice.current.userInterfaceIdiom == .phone {
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
        guard let scene = activeForegroundWindowScene() else {
            AppLog.debug("player", "请求界面方向更新", metadata: [
                "requestedMask": interfaceOrientationMaskDescription(mask),
                "effectiveMask": interfaceOrientationMaskDescription(phoneSupportedMask),
                "sceneFound": "false",
            ])
            return
        }
        let primaryWindow = scene.windows.first(where: \ .isKeyWindow) ?? scene.windows.first
        if #available(iOS 16, *) {
            primaryWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            let requestedMaskDescription = interfaceOrientationMaskDescription(mask)
            var metadata = sceneOrientationDebugMetadata(for: scene, rootViewController: primaryWindow?.rootViewController)
            metadata["requestedMask"] = requestedMaskDescription
            metadata["effectiveMask"] = interfaceOrientationMaskDescription(phoneSupportedMask)
            AppLog.debug("player", "请求界面方向更新", metadata: metadata)
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
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
                    followUpMetadata["effectiveMask"] = interfaceOrientationMaskDescription(phoneSupportedMask)
                    AppLog.debug("player", "界面方向更新后观察", metadata: followUpMetadata)
                }
            }
        } else {
            let value: UIDeviceOrientation
            switch mask {
            case .portrait:        value = .portrait
            case .landscapeLeft:   value = .landscapeRight
            case .landscapeRight:  value = .landscapeLeft
            case .landscape:       value = .landscapeLeft
            default:               value = .portrait
            }
            AppLog.debug("player", "使用旧版方式请求设备方向", metadata: [
                "requestedMask": interfaceOrientationMaskDescription(mask),
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