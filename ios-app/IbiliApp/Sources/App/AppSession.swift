import Foundation
import Combine

enum AppConnectionState: Equatable {
    case starting
    case online
    case login
    case offline(String)
}

struct AppSessionServices {
    var load: () -> PersistedSessionDTO?
    var save: (PersistedSessionDTO) -> Void
    var restore: (PersistedSessionDTO) -> Void
    var clear: () -> Void
    var logout: () -> Void
    var check: () async throws -> SessionSnapshotDTO

    static var live: Self {
        Self(load: SessionStore.load, save: SessionStore.save,
             restore: CoreClient.shared.restoreSession, clear: SessionStore.clear,
             logout: CoreClient.shared.logout,
             check: { try await CoreClient.shared.perform { try $0.checkSession() } })
    }
}

/// Local credentials and online availability have independent lifetimes.
@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var isLoggedIn = false
    @Published private(set) var mid: Int64 = 0
    @Published private(set) var connectionState: AppConnectionState = .starting
    @Published private(set) var isCheckingConnection = false

    private let services: AppSessionServices
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var expirationObserver: NSObjectProtocol?

    init(services: AppSessionServices = .live) {
        self.services = services
        // Strictly local: no synchronous HTTP before the root view can render.
        if let restored = services.load() {
            services.restore(restored)
            isLoggedIn = true
            mid = restored.mid
        }
        expirationObserver = NotificationCenter.default.addObserver(
            forName: .coreLoginExpired, object: nil, queue: .main
        ) { [weak self] notification in
            let generation = notification.userInfo?["generation"] as? UUID
            Task { @MainActor [weak self] in
                if let generation, generation != CoreClient.shared.sessionGeneration { return }
                self?.handleLoginExpired()
            }
        }
    }

    deinit {
        connectionTask?.cancel()
        if let expirationObserver { NotificationCenter.default.removeObserver(expirationObserver) }
    }

    func start() {
        guard connectionState == .starting else { return }
        reconnect()
    }

    func reconnect() {
        guard !isCheckingConnection else { return }
        isCheckingConnection = true
        connectionGeneration += 1
        let generation = connectionGeneration
        connectionTask = Task { [weak self, services] in
            let result: Result<SessionSnapshotDTO, Error>
            do { result = .success(try await services.check()) }
            catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.connectionGeneration == generation else { return }
            self.isCheckingConnection = false
            self.connectionTask = nil
            switch result {
            case .success(let snapshot) where snapshot.loggedIn:
                self.isLoggedIn = true
                self.mid = snapshot.mid
                self.connectionState = .online
            case .success:
                let hadCredentials = self.isLoggedIn
                self.clearCredentials()
                self.connectionState = hadCredentials
                    ? .offline("登录已失效，本地缓存仍可播放。重新连接后可重新登录。")
                    : .login
            case .failure:
                // Network/service errors are not evidence that the credentials expired.
                self.connectionState = .offline("暂时无法连接或确认登录状态，已进入离线模式。可播放已下载的视频，也可重连或重新登录。")
            }
        }
    }

    func didLogin(_ persisted: PersistedSessionDTO) {
        invalidateConnectionCheck()
        services.restore(persisted)
        services.save(persisted)
        isLoggedIn = true
        mid = persisted.mid
        connectionState = .online
        AppLog.info("session", "登录成功并持久化会话", metadata: ["mid": String(mid)])
    }

    func logout() {
        invalidateConnectionCheck()
        clearCredentials()
        connectionState = .login
    }

    func requestLogin() {
        invalidateConnectionCheck()
        connectionState = .login
    }

    private func handleLoginExpired() {
        guard isLoggedIn else { return }
        // An app-only API may reject a cookie-only account. Validate the web
        // session before discarding credentials that still work for web APIs.
        reconnect()
    }

    private func clearCredentials() {
        services.logout()
        services.clear()
        isLoggedIn = false
        mid = 0
    }

    private func invalidateConnectionCheck() {
        connectionGeneration += 1
        connectionTask?.cancel()
        connectionTask = nil
        isCheckingConnection = false
    }
}
