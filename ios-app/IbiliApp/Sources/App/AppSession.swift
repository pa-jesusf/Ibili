import SwiftUI
import Combine

/// App-wide auth state. Persists session to UserDefaults via `CoreClient`.
@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var isLoggedIn: Bool = false
    @Published private(set) var mid: Int64 = 0
    @Published private(set) var bangumiSession: BangumiSessionDTO?

    let core = CoreClient.shared

    init() {
        NotificationCenter.default.addObserver(
            forName: .coreLoginExpired,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleLoginExpired(method: note.userInfo?["method"] as? String)
            }
        }

        // Restore persisted session into Rust core, if any.
        if let restored = SessionStore.load() {
            core.restoreSession(restored)
            AppLog.info("session", "已从本地恢复登录态", metadata: [
                "mid": String(restored.mid),
            ])
        } else {
            AppLog.info("session", "本地没有可恢复的登录态")
        }
        bangumiSession = BangumiSessionStore.load()
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

    var bangumiAccessToken: String {
        bangumiSession?.accessToken ?? ""
    }

    var bangumiUser: AnimeBangumiUserDTO? {
        bangumiSession?.user
    }

    func restoreBangumiSession() {
        bangumiSession = BangumiSessionStore.load()
    }

    func startBangumiOAuth(clientID: String, redirectURI: String) async throws -> URL {
        let start = try await Task.detached(priority: .userInitiated) {
            try CoreClient.shared.animeOAuthStart(clientID: clientID, redirectURI: redirectURI)
        }.value
        guard let url = URL(string: start.authorizeUrl) else {
            throw CoreError(category: "invalid_argument", message: "Bangumi OAuth URL 无效", code: nil)
        }
        return url
    }

    func completeBangumiOAuth(clientID: String, clientSecret: String, redirectURI: String, code: String) async throws {
        let token = try await Task.detached(priority: .userInitiated) {
            try CoreClient.shared.animeOAuthExchange(
                clientID: clientID,
                clientSecret: clientSecret,
                redirectURI: redirectURI,
                code: code
            )
        }.value
        try await persistBangumiToken(token)
    }

    func refreshBangumiIfNeeded(clientID: String, clientSecret: String) async {
        guard let session = bangumiSession, session.isExpired, !session.refreshToken.isEmpty else { return }
        do {
            let token = try await Task.detached(priority: .utility) {
                try CoreClient.shared.animeOAuthRefresh(
                    clientID: clientID,
                    clientSecret: clientSecret,
                    refreshToken: session.refreshToken
                )
            }.value
            try await persistBangumiToken(token)
        } catch {
            AppLog.warning("session", "Bangumi token 刷新失败", metadata: [
                "error": error.localizedDescription,
            ])
        }
    }

    func logoutBangumi() {
        BangumiSessionStore.clear()
        bangumiSession = nil
        AppLog.info("session", "Bangumi 已退出")
    }

    private func handleLoginExpired(method: String?) {
        guard isLoggedIn else { return }
        AppLog.warning("session", "检测到登录过期，清理本地登录态", metadata: [
            "mid": String(mid),
            "method": method ?? "-",
        ])
        core.logout()
        SessionStore.clear()
        refresh()
    }

    private func persistBangumiToken(_ token: AnimeOAuthTokenDTO) async throws {
        let user = try await Task.detached(priority: .userInitiated) {
            try CoreClient.shared.animeMe(accessToken: token.accessToken)
        }.value
        let persisted = BangumiSessionDTO(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            tokenType: token.tokenType,
            expiresAt: token.expiresAt,
            user: user
        )
        BangumiSessionStore.save(persisted)
        bangumiSession = persisted
        AppLog.info("session", "Bangumi 登录成功", metadata: [
            "username": user.username,
        ])
    }
}
