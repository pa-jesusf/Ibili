import SwiftUI
import Combine

/// App-wide auth state. Persists session to UserDefaults via `CoreClient`.
@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var isLoggedIn: Bool = false
    @Published private(set) var mid: Int64 = 0

    let core = CoreClient.shared

    init() {
        // Restore persisted session into Rust core, if any.
        if let restored = SessionStore.load() {
            core.restoreSession(restored)
            AppLog.info("session", "已从本地恢复登录态", metadata: [
                "mid": String(restored.mid),
            ])
        } else {
            AppLog.info("session", "本地没有可恢复的登录态")
        }
        refresh()
    }

    func refresh() {
        let snap = core.sessionSnapshot()
        self.isLoggedIn = snap.loggedIn
        self.mid = snap.mid
        AppLog.debug("session", "刷新登录状态", metadata: [
            "loggedIn": snap.loggedIn ? "true" : "false",
            "mid": String(snap.mid),
        ])
    }

    func didLogin(_ persisted: PersistedSessionDTO) {
        SessionStore.save(persisted)
        AppLog.info("session", "登录成功并持久化会话", metadata: [
            "mid": String(persisted.mid),
        ])
        refresh()
    }

    func logout() {
        AppLog.info("session", "执行退出登录", metadata: [
            "mid": String(mid),
        ])
        core.logout()
        SessionStore.clear()
        refresh()
    }
}
