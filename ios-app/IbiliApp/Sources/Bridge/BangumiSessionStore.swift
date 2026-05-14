import Foundation
import Security

struct BangumiSessionDTO: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var tokenType: String
    var expiresAt: Int64
    var user: AnimeBangumiUserDTO

    var isExpired: Bool {
        expiresAt > 0 && expiresAt <= Int64(Date().timeIntervalSince1970) + 60
    }
}

enum BangumiSessionStore {
    private static let service = "app.ibili.client.bangumi"
    private static let account = "oauth"

    static func load() -> BangumiSessionDTO? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(BangumiSessionDTO.self, from: data)
    }

    static func save(_ session: BangumiSessionDTO) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
