import Foundation

/// Search result type tabs above the result grid. Mirrors PiliPlus
/// `SearchType` enum.
enum SearchResultType: String, CaseIterable, Identifiable {
    case video    // 视频
    case bangumi  // 番剧
    case movie    // 影视
    case user     // 用户
    case live     // 直播
    case article  // 专栏

    var id: String { rawValue }

    var label: String {
        switch self {
        case .video:   return "视频"
        case .bangumi: return "番剧"
        case .movie:   return "影视"
        case .user:    return "用户"
        case .live:    return "直播"
        case .article: return "专栏"
        }
    }

    var isImplemented: Bool { true }

    var hasFilters: Bool {
        switch self {
        case .video, .user, .article:
            return true
        case .live, .bangumi, .movie:
            return false
        }
    }
}

/// Sort order for video search. Values match upstream `order=` query
/// param. UI labels mirror the official Bilibili web search dropdown.
enum SearchOrder: String, CaseIterable, Identifiable {
    case totalrank // 综合排序
    case click     // 最多播放
    case pubdate   // 最新发布
    case dm        // 最多弹幕
    case stow      // 最多收藏
    case scores    // 最多评论

    var id: String { rawValue }

    var label: String {
        switch self {
        case .totalrank: return "综合排序"
        case .click:     return "最多播放"
        case .pubdate:   return "最新发布"
        case .dm:        return "最多弹幕"
        case .stow:      return "最多收藏"
        case .scores:    return "最多评论"
        }
    }
}

/// Duration filter buckets. Values match upstream `duration=` 0...4.
enum SearchDuration: Int64, CaseIterable, Identifiable {
    case any = 0    // 全部
    case under10    // 10 分钟以下
    case ten30      // 10-30 分钟
    case thirty60   // 30-60 分钟
    case over60     // 60 分钟以上

    var id: Int64 { rawValue }

    var label: String {
        switch self {
        case .any:       return "全部时长"
        case .under10:   return "10 分钟以下"
        case .ten30:     return "10-30 分钟"
        case .thirty60:  return "30-60 分钟"
        case .over60:    return "60 分钟以上"
        }
    }
}

enum SearchUserOrder: String, CaseIterable, Identifiable {
    case defaultOrder
    case fansDesc
    case fansAsc
    case levelDesc
    case levelAsc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .defaultOrder: return "默认排序"
        case .fansDesc: return "粉丝数由高到低"
        case .fansAsc: return "粉丝数由低到高"
        case .levelDesc: return "Lv等级由高到低"
        case .levelAsc: return "Lv等级由低到高"
        }
    }

    var order: String? {
        switch self {
        case .defaultOrder: return nil
        case .fansDesc, .fansAsc: return "fans"
        case .levelDesc, .levelAsc: return "level"
        }
    }

    var orderSort: Int64? {
        switch self {
        case .defaultOrder: return nil
        case .fansDesc, .levelDesc: return 0
        case .fansAsc, .levelAsc: return 1
        }
    }
}

enum SearchUserKind: Int64, CaseIterable, Identifiable {
    case all = 0
    case up = 1
    case common = 2
    case verified = 3

    var id: Int64 { rawValue }

    var label: String {
        switch self {
        case .all: return "全部用户"
        case .up: return "UP主"
        case .common: return "普通用户"
        case .verified: return "认证用户"
        }
    }

    var parameter: Int64? {
        self == .all ? nil : rawValue
    }
}

enum SearchArticleOrder: String, CaseIterable, Identifiable {
    case totalrank
    case pubdate
    case click
    case attention
    case scores

    var id: String { rawValue }

    var label: String {
        switch self {
        case .totalrank: return "综合排序"
        case .pubdate: return "最新发布"
        case .click: return "最多点击"
        case .attention: return "最多喜欢"
        case .scores: return "最多评论"
        }
    }
}

enum SearchArticleZone: Int64, CaseIterable, Identifiable {
    case all = 0
    case douga = 2
    case game = 1
    case cinephile = 28
    case life = 3
    case interest = 29
    case novel = 16
    case tech = 17
    case note = 41

    var id: Int64 { rawValue }

    var label: String {
        switch self {
        case .all: return "全部分区"
        case .douga: return "动画"
        case .game: return "游戏"
        case .cinephile: return "影视"
        case .life: return "生活"
        case .interest: return "兴趣"
        case .novel: return "轻小说"
        case .tech: return "科技"
        case .note: return "笔记"
        }
    }

    var categoryID: Int64? {
        self == .all ? nil : rawValue
    }
}
