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
        }
        refresh()
    }

    func refresh() {
        let snap = core.sessionSnapshot()
        self.isLoggedIn = snap.loggedIn
        self.mid = snap.mid
    }

    func didLogin(_ persisted: PersistedSessionDTO) {
        SessionStore.save(persisted)
        refresh()
    }

    func logout() {
        core.logout()
        SessionStore.clear()
        refresh()
    }
}
