import SwiftUI
import UIKit

@MainActor
final class IbiliAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = IbiliSceneDelegate.self
        }
        return configuration
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        PlayerFullscreenOrientationPolicy.shared.supportedInterfaceOrientations(for: window)
    }
}

@MainActor
final class IbiliSceneDelegate: NSObject, UIWindowSceneDelegate {
    // iOS 27 asks the scene delegate for its orientation mask. Keep the explicit
    // Objective-C selector so this also builds with the iOS 26 SDK.
    @objc(supportedInterfaceOrientationsForWindowScene:)
    func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask {
        PlayerFullscreenOrientationPolicy.shared.supportedInterfaceOrientations(for: windowScene)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        didUpdate coordinateSpace: any UICoordinateSpace,
        interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
        traitCollection previousTraitCollection: UITraitCollection
    ) {
        guard #unavailable(iOS 26.0) else { return }
        PlayerFullscreenOrientationPolicy.shared.enforceActiveOrientationIfNeeded(in: windowScene)
    }

    @available(iOS 26.0, *)
    func windowScene(
        _ windowScene: UIWindowScene,
        didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry
    ) {
        PlayerFullscreenOrientationPolicy.shared.enforceActiveOrientationIfNeeded(in: windowScene)
    }
}

@main
struct IbiliApp: App {
    @UIApplicationDelegateAdaptor(IbiliAppDelegate.self) private var appDelegate
    @StateObject private var logStore = AppLogStore.shared
    @StateObject private var session = AppSession()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(logStore)
                .environmentObject(session)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}
