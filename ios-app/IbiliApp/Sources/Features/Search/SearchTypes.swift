import Foundation

/// Search result type tabs above the result grid. Mirrors PiliPlus
/// `SearchType` enum but only `.video` actually fetches in this MVP;
/// the other cases render an "敬请期待" placeholder so the UI stays
/// honest about what's implemented.
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

    var isImplemented: Bool { self == .video }
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
