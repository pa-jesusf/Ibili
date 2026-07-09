import Foundation

enum AppDiagnostics {
    static var detailedNavigationTracingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ibili.diagnostics.navigation.detailed")
    }

    static var prefetchLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ibili.diagnostics.prefetch")
    }

    static var verbosePlayerStateLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ibili.diagnostics.player.state")
    }

    static func shouldRecordDebug(category rawCategory: String, message: String) -> Bool {
        let category = AppLogCategoryCatalog.normalizedKey(rawCategory)
        switch category {
        case "prefetch":
            return prefetchLoggingEnabled
        case "player":
            if message == "观察到 AVPlayer.timeControlStatus 变化" {
                return verbosePlayerStateLoggingEnabled
            }
            return true
        default:
            return true
        }
    }
}
