import Foundation

/// One Bilibili video zone (一级分区) used as a search shortcut on the
/// search landing screen. The data is intentionally static — upstream
/// has no public "list zones" endpoint, and PiliPlus also keeps the
/// same hardcoded list (`lib/models/common/search/video_search_type.dart`).
struct SearchCategory: Identifiable, Hashable {
    /// SF Symbol used as the leading icon. Picked to roughly match the
    /// vibe of each zone without needing a custom asset bundle.
    let id: String
    let name: String
    /// `tids` query parameter for `searchByType`. Zero means "all".
    let tids: Int64
    let systemImage: String
}

enum SearchCategories {
    /// The canonical PiliPlus-aligned zone list, in the order Bilibili
    /// itself displays them in the official app's category grid.
    static let all: [SearchCategory] = [
        .init(id: "douga",       name: "动画",   tids: 1,   systemImage: "sparkles.tv"),
        .init(id: "anime",       name: "番剧",   tids: 13,  systemImage: "play.tv"),
        .init(id: "guochuang",   name: "国创",   tids: 167, systemImage: "flag"),
        .init(id: "music",       name: "音乐",   tids: 3,   systemImage: "music.note"),
        .init(id: "dance",       name: "舞蹈",   tids: 129, systemImage: "figure.dance"),
        .init(id: "game",        name: "游戏",   tids: 4,   systemImage: "gamecontroller"),
        .init(id: "knowledge",   name: "知识",   tids: 36,  systemImage: "book"),
        .init(id: "tech",        name: "科技",   tids: 188, systemImage: "cpu"),
        .init(id: "sports",      name: "运动",   tids: 234, systemImage: "figure.run"),
        .init(id: "car",         name: "汽车",   tids: 223, systemImage: "car"),
        .init(id: "life",        name: "生活",   tids: 160, systemImage: "leaf"),
        .init(id: "food",        name: "美食",   tids: 211, systemImage: "fork.knife"),
        .init(id: "animal",      name: "动物圈", tids: 217, systemImage: "pawprint"),
        .init(id: "kichiku",     name: "鬼畜",   tids: 119, systemImage: "waveform"),
        .init(id: "fashion",     name: "时尚",   tids: 155, systemImage: "tshirt"),
        .init(id: "info",        name: "资讯",   tids: 202, systemImage: "newspaper"),
        .init(id: "ent",         name: "娱乐",   tids: 5,   systemImage: "star"),
        .init(id: "cinephile",   name: "影视",   tids: 181, systemImage: "film"),
        .init(id: "documentary", name: "纪录片", tids: 177, systemImage: "globe.asia.australia"),
        .init(id: "movie",       name: "电影",   tids: 23,  systemImage: "movieclapper"),
        .init(id: "tv",          name: "电视剧", tids: 11,  systemImage: "tv"),
    ]
}
