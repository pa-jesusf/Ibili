import Foundation

enum BangumiOAuthConfig {
    static let clientID = "bgm61256a05fb8f0c407"
    static let clientSecret = "36779576597f970fd8b9a59436651040"
    static let redirectURI = "ibili://bangumi-oauth"
}

enum AnimeDanmakuConfig {
    static var dandanplayAppID: String {
        sanitizedBundleValue("DANDANPLAY_APP_ID")
    }

    static var dandanplayAppSecret: String {
        sanitizedBundleValue("DANDANPLAY_APP_SECRET")
    }

    static var dandanplayCallbackURL: String {
        sanitizedBundleValue("DANDANPLAY_CALLBACK_URL")
    }

    private static func sanitizedBundleValue(_ key: String) -> String {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("$(") ? "" : value
    }
}
