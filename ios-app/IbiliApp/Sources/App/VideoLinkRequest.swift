import Foundation

/// Unresolved page hints belong to the link, not to a trusted playback CID.
/// Resolve them against the video's own page list before requesting playurl.
public struct VideoLinkSelection: Codable, Hashable {
    public let cid: Int64?
    public let page: Int32?
}

enum VideoLinkRequest {
    static func positiveID(_ text: String?) -> Int64? {
        guard let text, let number = Int64(text), number > 0 else { return nil }
        return number
    }

    static func isBVID(_ text: String) -> Bool {
        text.range(of: #"^BV[0-9A-Za-z]{10}$"#, options: .regularExpression) != nil
    }

    static func progressMilliseconds(in components: URLComponents) -> Int64? {
        func value(_ key: String) -> String? { components.queryItems?.first { $0.name == key }?.value }
        if let raw = value("start_progress") ?? value("dm_progress") {
            guard let milliseconds = Int64(raw), milliseconds >= 0 else { return nil }
            return milliseconds
        }
        guard let raw = value("t"), let seconds = Double(raw), seconds.isFinite, seconds >= 0,
              seconds * 1000 < Double(Int64.max) else { return nil }
        return Int64(seconds * 1000)
    }

    static func playbackQuery(in components: URLComponents) -> [URLQueryItem] {
        var result: [URLQueryItem] = []
        for key in ["p", "cid"] {
            if let value = positiveID(components.queryItems?.first { $0.name == key }?.value),
               key != "p" || value <= Int32.max {
                result.append(URLQueryItem(name: key, value: String(value)))
            }
        }
        if let progress = progressMilliseconds(in: components) {
            result.append(URLQueryItem(name: "start_progress", value: String(progress)))
        }
        return result
    }

    static func feedItem(from url: URL) -> FeedItemDTO? {
        guard url.scheme?.lowercased() == "ibili",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.pathComponents.filter({ $0 != "/" }).count == 1 else { return nil }
        let id = url.lastPathComponent
        let aid: Int64
        let bvid: String
        switch url.host?.lowercased() {
        case "bv":
            guard isBVID(id) else { return nil }
            aid = 0; bvid = id
        case "av":
            guard let number = positiveID(id) else { return nil }
            aid = number; bvid = ""
        default: return nil
        }
        let query = playbackQuery(in: components)
        func value(_ key: String) -> String? { query.first { $0.name == key }?.value }
        return FeedItemDTO(aid: aid, bvid: bvid, cid: 0, title: "", cover: "", author: "",
                           durationSec: 0, play: 0, danmaku: 0,
                           resumePositionMs: value("start_progress").flatMap(Int64.init),
                           linkSelection: VideoLinkSelection(cid: positiveID(value("cid")), page: value("p").flatMap(Int32.init)))
    }

    /// Called after the view API returns. Never pair another video's CID with
    /// this link's BV/AV, and never silently replace an explicit missing part.
    static func resolve(_ item: FeedItemDTO, using view: VideoViewDTO) throws -> FeedItemDTO {
        guard view.aid > 0, isBVID(view.bvid),
              item.aid <= 0 || item.aid == view.aid,
              item.bvid.isEmpty || item.bvid == view.bvid else {
            throw ResolutionError("视频标识与链接不匹配")
        }
        let requestedCID = item.linkSelection?.cid ?? (item.cid > 0 ? item.cid : nil)
        let requestedPage = item.linkSelection?.page
        let page: VideoPageDTO?
        if let requestedCID {
            page = view.pages.first { $0.cid == requestedCID }
            guard page != nil, requestedPage == nil || page?.page == requestedPage else {
                throw ResolutionError("链接中的分 P 与该视频不匹配")
            }
        } else if let requestedPage {
            page = view.pages.first { $0.page == requestedPage }
            guard page != nil else { throw ResolutionError("链接指定的分 P 不存在") }
        } else {
            page = view.pages.first
        }
        let cid = page?.cid ?? view.cid
        guard cid > 0 else { throw ResolutionError("视频没有可播放的分 P") }
        return FeedItemDTO(aid: view.aid, bvid: view.bvid, cid: cid, title: view.title,
                           cover: view.cover, author: view.owner.name, durationSec: page?.durationSec ?? view.durationSec,
                           play: view.stat.view, danmaku: view.stat.danmaku, pubdate: view.pubdate,
                           isFollowed: item.isFollowed, ownerMID: view.owner.mid,
                           feedGoto: item.feedGoto, feedID: item.feedID,
                           dislikeReasons: item.dislikeReasons, feedbackReasons: item.feedbackReasons,
                           resumePositionMs: item.resumePositionMs, dimension: page?.dimension ?? item.dimension)
    }

    struct ResolutionError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
