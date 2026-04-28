import SwiftUI
import UIKit

@MainActor
final class IbiliAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.supportedMask()
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
