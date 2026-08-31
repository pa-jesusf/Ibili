import Foundation

/// The two version values shipped in the app bundle.
///
/// `MARKETING_VERSION` is the user-facing release version, while
/// `CURRENT_PROJECT_VERSION` identifies a particular build of that release.
struct AppVersion: Equatable {
    let marketingVersion: String
    let buildNumber: String

    static let current = AppVersion(bundle: .main)

    var displayString: String {
        if buildNumber.isEmpty {
            return marketingVersion
        }
        return "\(marketingVersion) (\(buildNumber))"
    }

    init(bundle: Bundle) {
        marketingVersion = Self.value(
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString"),
            fallback: "0.1.0"
        )
        buildNumber = Self.value(
            bundle.object(forInfoDictionaryKey: "CFBundleVersion"),
            fallback: "1"
        )
    }

    init(marketingVersion: String, buildNumber: String) {
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
    }

    private static func value(_ rawValue: Any?, fallback: String) -> String {
        guard let value = rawValue as? String,
              !value.isEmpty,
              !value.contains("$(") else {
            return fallback
        }
        return value
    }
}
