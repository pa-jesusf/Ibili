import SwiftUI

@main
struct IbiliApp: App {
    @StateObject private var session = AppSession()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}
