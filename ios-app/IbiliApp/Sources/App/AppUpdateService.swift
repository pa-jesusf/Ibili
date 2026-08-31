import Foundation

struct AppUpdateRelease: Equatable {
    let version: String
    let title: String
    let notes: String
    let htmlURL: URL

    var displayVersion: String {
        version.lowercased().hasPrefix("v") ? version : "v\(version)"
    }
}

enum AppUpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppUpdateRelease)
    case failed
}

enum AppUpdateServiceError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidRelease

    var errorDescription: String? {
        switch self {
        case .invalidResponse, .invalidRelease:
            return "更新信息格式无效"
        case .httpStatus(let status):
            return "更新服务返回 HTTP \(status)"
        }
    }
}

/// Reads the latest stable GitHub Release for the app repository.
enum AppUpdateService {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/pa-jesusf/Ibili/releases/latest")!

    static func fetchLatestRelease() async throws -> AppUpdateRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Ibili/\(AppVersion.current.marketingVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateServiceError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw AppUpdateServiceError.httpStatus(httpResponse.statusCode)
        }

        let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        guard let version = releaseVersion(tagName: release.tagName, name: release.name) else {
            throw AppUpdateServiceError.invalidRelease
        }
        let title = release.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AppUpdateRelease(
            version: version,
            title: title.isEmpty ? release.tagName : title,
            notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            htmlURL: release.htmlURL
        )
    }

    static func isNewer(_ remote: String, than current: String) -> Bool {
        guard let remoteVersion = ReleaseVersion(remote),
              let currentVersion = ReleaseVersion(current) else {
            return false
        }
        return remoteVersion > currentVersion
    }

    static func releaseVersion(tagName: String, name: String?) -> String? {
        if ReleaseVersion(tagName) != nil {
            return tagName
        }
        guard let name, ReleaseVersion(name) != nil else { return nil }
        return name
    }

    private struct GitHubReleaseResponse: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
        }
    }
}

/// Numeric comparison for release tags such as `v0.2.0` and `0.2.0`.
private struct ReleaseVersion: Comparable {
    let components: [Int]

    init?(_ rawValue: String) {
        var components: [Int] = []
        var digits = ""

        for character in rawValue {
            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                guard let component = Int(digits) else { return nil }
                components.append(component)
                digits.removeAll(keepingCapacity: true)
            }
        }
        if !digits.isEmpty {
            guard let component = Int(digits) else { return nil }
            components.append(component)
        }

        guard !components.isEmpty else { return nil }
        self.components = components
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

@MainActor
final class AppUpdateChecker: ObservableObject {
    @Published private(set) var state: AppUpdateCheckState = .idle

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    func check() async {
        guard !isChecking else { return }
        state = .checking

        do {
            let release = try await AppUpdateService.fetchLatestRelease()
            if AppUpdateService.isNewer(
                release.version,
                than: AppVersion.current.marketingVersion
            ) {
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            AppLog.error("app", "检查应用更新失败", error: error)
            state = .failed
        }
    }
}
