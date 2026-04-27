import Foundation

/// Persists `PersistedSessionDTO` via UserDefaults. Replace with Keychain in production.
enum SessionStore {
    private static let key = "ibili.session.v1"

    static func save(_ s: PersistedSessionDTO) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> PersistedSessionDTO? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedSessionDTO.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
