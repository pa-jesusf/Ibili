import SwiftUI
import UIKit

@MainActor
final class IbiliAppDelegate: NSObject, UIApplicationDelegate {
    private var lastSupportedOrientationLogSignature: String?

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        let supportedMask = Orientation.supportedMask(for: window)
        var metadata = sceneOrientationDebugMetadata(for: window?.windowScene,
                                                     rootViewController: window?.rootViewController)
        metadata["returnedMask"] = interfaceOrientationMaskDescription(supportedMask)
        metadata["windowFound"] = String(window != nil)
        let signature = [
            metadata["returnedMask"] ?? "nil",
            metadata["scenePersistentID"] ?? "nil",
            metadata["sceneInterfaceOrientation"] ?? "nil",
            metadata["topViewController"] ?? "nil",
            metadata["topSupportedMask"] ?? "nil",
        ].joined(separator: "|")
        if signature != lastSupportedOrientationLogSignature {
            lastSupportedOrientationLogSignature = signature
            AppLog.debug("player", "AppDelegate 查询支持方向", metadata: metadata)
        }
        return supportedMask
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
