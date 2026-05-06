import AVFoundation
import SwiftUI
import UIKit

@MainActor
enum Orientation {
    private static var phoneSupportedMask: UIInterfaceOrientationMask = .portrait

    static func supportedMask() -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? phoneSupportedMask : .all
    }

    static func preparePhoneFullscreenLandscape() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        phoneSupportedMask = .landscape
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        AppLog.debug("player", "收紧手机方向掩码到 landscape，强制系统横屏", metadata: [
            "mask": interfaceOrientationMaskDescription(phoneSupportedMask),
        ])
    }

    static func request(_ mask: UIInterfaceOrientationMask) {
        if UIDevice.current.userInterfaceIdiom == .phone {
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

    static func requestWithoutMaskChange(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        if #available(iOS 16, *) {
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            AppLog.debug("player", "请求界面方向更新", metadata: [
                "requestedMask": interfaceOrientationMaskDescription(mask),
                "effectiveMask": interfaceOrientationMaskDescription(phoneSupportedMask),
            ])
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                AppLog.warning("player", "界面方向更新被系统拒绝", metadata: [
                    "requestedMask": interfaceOrientationMaskDescription(mask),
                    "error": error.localizedDescription,
                ])
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

enum PlayerFullscreenTransitionDirection {
    case enter
    case exit
}

struct PlayerFullscreenTransitionContext {
    let aid: Int64
    let cid: Int64
    let isFullscreen: Bool
    let lastDeviceOrientation: UIDeviceOrientation
    let prefersLandscapeFullscreen: Bool
}

struct PlayerAutoFullscreenContext {
    let currentOrientation: UIDeviceOrientation
    let lastDeviceOrientation: UIDeviceOrientation
    let isFullscreen: Bool
    let prefersLandscapeFullscreen: Bool
    let autoRotateFullscreen: Bool
    let isPhone: Bool
}

@MainActor
enum PlayerFullscreenController {
    static func requestTransition(_ direction: PlayerFullscreenTransitionDirection,
                                  context: PlayerFullscreenTransitionContext,
                                  playerBox _: PlayerPresentationBox,
                                  player _: AVPlayer?,
                                  updateFullscreenState: (Bool) -> Void) {
        switch direction {
        case .enter:
            enterFullscreen(context: context, updateFullscreenState: updateFullscreenState)
        case .exit:
            exitFullscreen(context: context, updateFullscreenState: updateFullscreenState)
        }
    }

    static func handleDeviceOrientationChange(_ context: PlayerAutoFullscreenContext,
                                              onEnterFullscreen: () -> Void,
                                              onExitFullscreen: () -> Void,
                                              rememberOrientation: (UIDeviceOrientation) -> Void) {
        let orientation = context.currentOrientation
        AppLog.debug("player", "收到设备方向变化", metadata: [
            "deviceOrientation": deviceOrientationDescription(orientation),
            "lastDeviceOrientation": deviceOrientationDescription(context.lastDeviceOrientation),
            "isFullscreen": String(context.isFullscreen),
            "autoRotateFullscreen": String(context.autoRotateFullscreen),
            "idiom": context.isPhone ? "phone" : "pad",
        ])
        guard context.autoRotateFullscreen else {
            AppLog.debug("player", "忽略设备方向变化：自动全屏已关闭")
            return
        }
        guard context.isPhone else {
            AppLog.debug("player", "忽略设备方向变化：当前设备不是手机")
            return
        }
        guard orientation != context.lastDeviceOrientation else {
            AppLog.debug("player", "忽略设备方向变化：与上次方向相同", metadata: [
                "deviceOrientation": deviceOrientationDescription(orientation),
            ])
            return
        }
        defer { rememberOrientation(orientation) }
        if orientation.isLandscape, context.prefersLandscapeFullscreen, !context.isFullscreen {
            onEnterFullscreen()
        } else if orientation == .portrait, context.prefersLandscapeFullscreen, context.isFullscreen {
            onExitFullscreen()
        } else {
            AppLog.debug("player", "设备方向变化未触发全屏切换", metadata: [
                "deviceOrientation": deviceOrientationDescription(orientation),
                "isLandscape": String(orientation.isLandscape),
                "prefersLandscapeFullscreen": String(context.prefersLandscapeFullscreen),
                "isFullscreen": String(context.isFullscreen),
            ])
        }
    }

    private static func enterFullscreen(context: PlayerFullscreenTransitionContext,
                                        updateFullscreenState: (Bool) -> Void) {
        guard !context.isFullscreen else {
            AppLog.debug("player", "忽略自动进全屏：已经处于全屏状态", metadata: [
                "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
            ])
            return
        }
        if context.prefersLandscapeFullscreen {
            Orientation.preparePhoneFullscreenLandscape()
        } else {
            Orientation.request(.portrait)
        }
        updateFullscreenState(true)
        let deviceOrientation = UIDevice.current.orientation
        let targetMask: UIInterfaceOrientationMask
        if context.prefersLandscapeFullscreen {
            targetMask = deviceOrientation == .landscapeRight ? .landscapeLeft : .landscapeRight
        } else {
            targetMask = .portrait
        }
        Orientation.requestWithoutMaskChange(targetMask)
        AppLog.info("player", "请求进入 app-owned 全屏", metadata: [
            "aid": String(context.aid),
            "cid": String(context.cid),
            "prefersLandscapeFullscreen": String(context.prefersLandscapeFullscreen),
            "deviceOrientation": deviceOrientationDescription(deviceOrientation),
            "lastDeviceOrientation": deviceOrientationDescription(context.lastDeviceOrientation),
            "supportedMask": interfaceOrientationMaskDescription(Orientation.supportedMask()),
        ])
    }

    private static func exitFullscreen(context: PlayerFullscreenTransitionContext,
                                       updateFullscreenState: (Bool) -> Void) {
        guard context.isFullscreen else {
            AppLog.debug("player", "忽略自动退全屏：当前不在全屏", metadata: [
                "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
            ])
            return
        }
        updateFullscreenState(false)
        Orientation.request(.portrait)
        AppLog.info("player", "请求退出 app-owned 全屏", metadata: [
            "aid": String(context.aid),
            "cid": String(context.cid),
            "deviceOrientation": deviceOrientationDescription(UIDevice.current.orientation),
            "supportedMask": interfaceOrientationMaskDescription(Orientation.supportedMask()),
        ])
    }
}

@MainActor
enum PlayerViewLifecycleController {
    static func handleScenePhaseChange(_ phase: ScenePhase,
                                       didBootstrap: Bool,
                                       viewModel: PlayerViewModel,
                                       playerBox: PlayerPresentationBox,
                                       reloadPlayer: @escaping @MainActor () async -> Void) {
        if phase == .background,
           didBootstrap,
           !viewModel.isPictureInPictureActive,
           let player = viewModel.player {
            viewModel.endTemporarySpeedBoost(on: player)
            let continuationRate = viewModel.backgroundContinuationRate(for: player)
            AppLog.info("player", "app-owned surface 进入后台，保持播放器会话", metadata: [
                "aid": String(viewModel.currentAid),
                "cid": String(viewModel.currentCid),
                "continuationRate": continuationRate.map { String($0) } ?? "nil",
            ])
            if let continuationRate {
                player.playImmediately(atRate: continuationRate)
            }
            viewModel.refreshSystemMediaSession()
        }

        guard phase == .active, didBootstrap else { return }
        guard viewModel.player != nil else { return }
        if !viewModel.isEngineAlive {
            Task { await reloadPlayer() }
        }
        if viewModel.isPictureInPictureActive {
            playerBox.pictureInPictureController?.stopPictureInPicture()
        }
        viewModel.refreshSystemMediaSession()
    }

    static func handleAppear(didBootstrap: Bool,
                             viewModel: PlayerViewModel,
                             danmaku: DanmakuController,
                             resolvedAudioVolumeLinear: Float) {
        viewModel.setAudioVolumeLinear(resolvedAudioVolumeLinear)
        guard didBootstrap else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        viewModel.handle(.interfaceActivated)
        if let player = viewModel.player {
            danmaku.attach(player)
        }
        viewModel.refreshSystemMediaSession()
    }

    static func handleDisappear(isFullscreen _: Bool,
                                viewModel: PlayerViewModel,
                                danmaku: DanmakuController) {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        danmaku.detach()
        viewModel.handle(.interfaceDeactivated)
        if !viewModel.isPictureInPictureActive {
            Orientation.request(.portrait)
        }
        viewModel.refreshSystemMediaSession()
    }
}

final class PlayerPresentationBox {
    weak var pictureInPictureController: (any PlayerPictureInPictureControlling)?
}