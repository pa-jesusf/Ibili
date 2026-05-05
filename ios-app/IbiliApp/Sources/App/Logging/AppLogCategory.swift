import Foundation

enum AppLogCategoryGroup: String, CaseIterable, Hashable, Identifiable {
    case apiRequests
    case playerBehavior
    case authSession
    case content
    case interaction
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apiRequests: return "API 请求"
        case .playerBehavior: return "播放器行为"
        case .authSession: return "登录与会话"
        case .content: return "内容加载"
        case .interaction: return "互动与评论"
        case .other: return "其他"
        }
    }
}

struct AppLogCategoryDescriptor: Hashable, Identifiable {
    let key: String
    let title: String
    let group: AppLogCategoryGroup

    var id: String { key }
}

enum AppLogCategoryCatalog {
    static func normalizedKey(_ rawCategory: String) -> String {
        rawCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func descriptor(for rawCategory: String) -> AppLogCategoryDescriptor {
        let key = normalizedKey(rawCategory)
        switch key {
        case "core":
            return AppLogCategoryDescriptor(key: key, title: "Core / API", group: .apiRequests)
        case "prefetch":
            return AppLogCategoryDescriptor(key: key, title: "资源预取", group: .apiRequests)
        case "player":
            return AppLogCategoryDescriptor(key: key, title: "播放器", group: .playerBehavior)
        case "danmaku":
            return AppLogCategoryDescriptor(key: key, title: "弹幕", group: .playerBehavior)
        case "auth":
            return AppLogCategoryDescriptor(key: key, title: "登录认证", group: .authSession)
        case "session":
            return AppLogCategoryDescriptor(key: key, title: "会话", group: .authSession)
        case "home":
            return AppLogCategoryDescriptor(key: key, title: "首页", group: .content)
        case "video":
            return AppLogCategoryDescriptor(key: key, title: "视频详情", group: .content)
        case "interaction":
            return AppLogCategoryDescriptor(key: key, title: "互动", group: .interaction)
        case "comments":
            return AppLogCategoryDescriptor(key: key, title: "评论", group: .interaction)
        default:
            return AppLogCategoryDescriptor(key: key,
                                            title: displayTitle(forUnknownKey: key),
                                            group: .other)
        }
    }

    static func descriptors(from entries: [AppLogEntry],
                            in group: AppLogCategoryGroup? = nil) -> [AppLogCategoryDescriptor] {
        var seen: Set<String> = []
        return entries.compactMap { entry in
            let descriptor = descriptor(for: entry.category)
            guard group == nil || descriptor.group == group else { return nil }
            guard seen.insert(descriptor.key).inserted else { return nil }
            return descriptor
        }
        .sorted {
            if $0.group != $1.group {
                return $0.group.title < $1.group.title
            }
            return $0.title < $1.title
        }
    }

    private static func displayTitle(forUnknownKey key: String) -> String {
        let normalized = key.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        guard !normalized.isEmpty else { return "未分类" }
        return normalized.capitalized
    }
}

extension AppLogEntry {
    var categoryDescriptor: AppLogCategoryDescriptor {
        AppLogCategoryCatalog.descriptor(for: category)
    }
}