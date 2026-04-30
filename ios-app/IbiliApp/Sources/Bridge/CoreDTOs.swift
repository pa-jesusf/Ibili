import Foundation

// MARK: - DTOs mirrored from Rust core JSON output.

public struct SessionSnapshotDTO: Decodable {
    public let loggedIn: Bool
    public let mid: Int64
    public let expiresAtSecs: Int64
    enum CodingKeys: String, CodingKey {
        case loggedIn = "logged_in"
        case mid
        case expiresAtSecs = "expires_at_secs"
    }
}

public struct PersistedSessionDTO: Codable {
    public let accessToken: String
    public let refreshToken: String
    public let mid: Int64
    public let expiresAtSecs: Int64
    /// Web cookies (SESSDATA / bili_jct / DedeUserID …) returned by the TV
    /// QR poll. Required to authenticate `/x/player/wbi/playurl` and other
    /// web endpoints; absence caps playback at 480p (qn=64). Encoded as a
    /// JSON array of `[name, value]` pairs to match the Rust `Vec<(String,String)>`
    /// representation. Optional for back-compat with sessions saved before
    /// this field existed.
    public let webCookies: [[String]]?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case mid
        case expiresAtSecs = "expires_at_secs"
        case webCookies = "web_cookies"
    }
}

public struct TvQrStartDTO: Decodable {
    public let authCode: String
    public let url: String
    enum CodingKeys: String, CodingKey {
        case authCode = "auth_code"
        case url
    }
}

public enum TvQrPollDTO: Decodable {
    case pending
    case scanned
    case expired
    case confirmed(PersistedSessionDTO)

    private enum CK: String, CodingKey { case state, session }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        let state = try c.decode(String.self, forKey: .state)
        switch state {
        case "pending": self = .pending
        case "scanned": self = .scanned
        case "expired": self = .expired
        case "confirmed":
            let s = try c.decode(PersistedSessionDTO.self, forKey: .session)
            self = .confirmed(s)
        default: self = .pending
        }
    }
}

public struct FeedPageDTO: Decodable {
    public let items: [FeedItemDTO]
}

public struct FeedItemDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { aid }
    public let aid: Int64
    public let bvid: String
    public let cid: Int64
    public let title: String
    public let cover: String
    public let author: String
    public let durationSec: Int64
    public let play: Int64
    public let danmaku: Int64
    /// Unix seconds. `0` when upstream did not provide a publish date —
    /// the recommendation feed often omits it, search always carries it.
    public let pubdate: Int64

    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, cover, author, play, danmaku, pubdate
        case durationSec = "duration_sec"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aid = try c.decode(Int64.self, forKey: .aid)
        bvid = try c.decodeIfPresent(String.self, forKey: .bvid) ?? ""
        cid = try c.decodeIfPresent(Int64.self, forKey: .cid) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        durationSec = try c.decodeIfPresent(Int64.self, forKey: .durationSec) ?? 0
        play = try c.decodeIfPresent(Int64.self, forKey: .play) ?? 0
        danmaku = try c.decodeIfPresent(Int64.self, forKey: .danmaku) ?? 0
        pubdate = try c.decodeIfPresent(Int64.self, forKey: .pubdate) ?? 0
    }

    /// Memberwise convenience init for synthetic feed items (related,
    /// season episodes, deep-link routing). Mirrors the wire format
    /// field order; `pubdate` defaults to 0 since these synthetic
    /// origins never carry a publish date.
    public init(
        aid: Int64, bvid: String, cid: Int64, title: String,
        cover: String, author: String, durationSec: Int64,
        play: Int64, danmaku: Int64, pubdate: Int64 = 0
    ) {
        self.aid = aid; self.bvid = bvid; self.cid = cid
        self.title = title; self.cover = cover; self.author = author
        self.durationSec = durationSec; self.play = play
        self.danmaku = danmaku; self.pubdate = pubdate
    }
}

public struct PlayUrlDTO: Decodable {
    public let url: String
    public let audioUrl: String?
    public let format: String
    public let streamType: String
    public let quality: Int64
    public let durationMs: Int64
    public let backupUrls: [String]
    public let audioBackupUrls: [String]
    public let acceptQuality: [Int64]
    public let acceptDescription: [String]
    /// RFC6381 codec string for the video track (e.g. `"avc1.640032"`,
    /// `"hvc1.2.4.L150.B0"`). Empty string when unknown (legacy `durl`
    /// MP4 path). Forwarded into the local HLS master playlist's
    /// `CODECS` attribute so AVPlayer can dispatch to the correct
    /// decoder pipeline (HEVC Main10 / HDR) before fetching segments.
    public let videoCodec: String
    /// RFC6381 codec string for the audio track (e.g. `"mp4a.40.2"`,
    /// `"ec-3"`). Empty when there is no separate audio track or the
    /// upstream omitted it.
    public let audioCodec: String
    public let debugMessage: String?
    public let audioQuality: Int64
    public let audioQualityLabel: String
    public let acceptAudioQuality: [Int64]
    public let acceptAudioDescription: [String]
    /// Server-recorded resume position for this cid, in milliseconds.
    /// Zero when the account has no history for the cid (or playback
    /// is anonymous). The player seeks to it on first ready.
    public let lastPlayTimeMs: Int64
    /// Server's preferred resume cid for the same aid — set when the
    /// last watch was on a different page. Currently exposed but not
    /// auto-followed.
    public let lastPlayCid: Int64
    enum CodingKeys: String, CodingKey {
        case url, format, quality
        case audioUrl = "audio_url"
        case streamType = "stream_type"
        case durationMs = "duration_ms"
        case backupUrls = "backup_urls"
        case audioBackupUrls = "audio_backup_urls"
        case acceptQuality = "accept_quality"
        case acceptDescription = "accept_description"
        case videoCodec = "video_codec"
        case audioCodec = "audio_codec"
        case debugMessage = "debug_message"
        case audioQuality = "audio_quality"
        case audioQualityLabel = "audio_quality_label"
        case acceptAudioQuality = "accept_audio_quality"
        case acceptAudioDescription = "accept_audio_description"
        case lastPlayTimeMs = "last_play_time_ms"
        case lastPlayCid = "last_play_cid"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        audioUrl = try c.decodeIfPresent(String.self, forKey: .audioUrl)
        format = try c.decode(String.self, forKey: .format)
        streamType = try c.decode(String.self, forKey: .streamType)
        quality = try c.decode(Int64.self, forKey: .quality)
        durationMs = try c.decode(Int64.self, forKey: .durationMs)
        backupUrls = try c.decodeIfPresent([String].self, forKey: .backupUrls) ?? []
        audioBackupUrls = try c.decodeIfPresent([String].self, forKey: .audioBackupUrls) ?? []
        acceptQuality = try c.decodeIfPresent([Int64].self, forKey: .acceptQuality) ?? []
        acceptDescription = try c.decodeIfPresent([String].self, forKey: .acceptDescription) ?? []
        videoCodec = try c.decodeIfPresent(String.self, forKey: .videoCodec) ?? ""
        audioCodec = try c.decodeIfPresent(String.self, forKey: .audioCodec) ?? ""
        debugMessage = try c.decodeIfPresent(String.self, forKey: .debugMessage)
        audioQuality = try c.decodeIfPresent(Int64.self, forKey: .audioQuality) ?? 0
        audioQualityLabel = try c.decodeIfPresent(String.self, forKey: .audioQualityLabel) ?? ""
        acceptAudioQuality = try c.decodeIfPresent([Int64].self, forKey: .acceptAudioQuality) ?? []
        acceptAudioDescription = try c.decodeIfPresent([String].self, forKey: .acceptAudioDescription) ?? []
        lastPlayTimeMs = try c.decodeIfPresent(Int64.self, forKey: .lastPlayTimeMs) ?? 0
        lastPlayCid = try c.decodeIfPresent(Int64.self, forKey: .lastPlayCid) ?? 0
    }
}

public struct DanmakuItemDTO: Decodable {
    public let timeSec: Float
    public let mode: Int32
    public let color: UInt32
    public let fontSize: Int32
    public let text: String
    public let weight: Int32
    public let hasWeight: Bool
    public let midHash: String
    public let likeCount: Int64
    public let colorful: Int32
    public let count: Int32
    public let isSelf: Bool
    enum CodingKeys: String, CodingKey {
        case timeSec = "time_sec"
        case mode
        case color
        case fontSize = "font_size"
        case text
        case weight
        case hasWeight = "has_weight"
        case midHash = "mid_hash"
        case likeCount = "like_count"
        case colorful
        case count
        case isSelf = "is_self"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeSec = try c.decode(Float.self, forKey: .timeSec)
        mode = try c.decode(Int32.self, forKey: .mode)
        color = try c.decode(UInt32.self, forKey: .color)
        fontSize = try c.decode(Int32.self, forKey: .fontSize)
        text = try c.decode(String.self, forKey: .text)
        weight = try c.decodeIfPresent(Int32.self, forKey: .weight) ?? 0
        hasWeight = try c.decodeIfPresent(Bool.self, forKey: .hasWeight) ?? false
        midHash = try c.decodeIfPresent(String.self, forKey: .midHash) ?? ""
        likeCount = try c.decodeIfPresent(Int64.self, forKey: .likeCount) ?? 0
        colorful = try c.decodeIfPresent(Int32.self, forKey: .colorful) ?? 0
        count = try c.decodeIfPresent(Int32.self, forKey: .count) ?? 0
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
    }

    /// Memberwise convenience init for synthesizing local-echo bullets
    /// after a successful send. Defaults match the wire-format zeros so
    /// callers only have to fill in the user-visible fields.
    public init(
        timeSec: Float,
        mode: Int32,
        color: UInt32,
        fontSize: Int32,
        text: String,
        weight: Int32 = 0,
        hasWeight: Bool = false,
        midHash: String = "",
        likeCount: Int64 = 0,
        colorful: Int32 = 0,
        count: Int32 = 0,
        isSelf: Bool = false
    ) {
        self.timeSec = timeSec
        self.mode = mode
        self.color = color
        self.fontSize = fontSize
        self.text = text
        self.weight = weight
        self.hasWeight = hasWeight
        self.midHash = midHash
        self.likeCount = likeCount
        self.colorful = colorful
        self.count = count
        self.isSelf = isSelf
    }
}

public struct DanmakuTrackDTO: Decodable {
    public let items: [DanmakuItemDTO]
}

// MARK: - Search

/// One video result from `/x/web-interface/wbi/search/type?search_type=video`.
/// Field set is a strict superset of `FeedItemDTO`, with extra `like` and
/// `pubdate` (unix seconds) for the search result row.
public struct SearchVideoItemDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { aid }
    public let aid: Int64
    public let bvid: String
    public let cid: Int64
    public let title: String
    public let cover: String
    public let author: String
    public let durationSec: Int64
    public let play: Int64
    public let danmaku: Int64
    public let like: Int64
    /// Unix seconds. `0` means upstream did not provide a publish date.
    public let pubdate: Int64

    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, cover, author, play, danmaku, like, pubdate
        case durationSec = "duration_sec"
    }
}

public struct SearchVideoPageDTO: Decodable {
    public let items: [SearchVideoItemDTO]
    public let numResults: Int64
    public let numPages: Int64
    enum CodingKeys: String, CodingKey {
        case items
        case numResults = "num_results"
        case numPages = "num_pages"
    }
}

// MARK: - Video detail (full view)

public struct VideoStatDTO: Decodable, Hashable {
    public let view: Int64
    public let danmaku: Int64
    public let reply: Int64
    public let favorite: Int64
    public let coin: Int64
    public let share: Int64
    public let like: Int64
}

public struct VideoOwnerDTO: Decodable, Hashable {
    public let mid: Int64
    public let name: String
    public let face: String
}

public struct VideoPageDTO: Decodable, Hashable, Identifiable {
    public var id: Int64 { cid }
    public let cid: Int64
    public let page: Int32
    public let part: String
    public let durationSec: Int64
    public let firstFrame: String
    enum CodingKeys: String, CodingKey {
        case cid, page, part
        case durationSec = "duration_sec"
        case firstFrame = "first_frame"
    }
}

public struct VideoDescNodeDTO: Decodable, Hashable {
    /// 1 = plain text, 2 = at-user.
    public let kind: Int32
    public let rawText: String
    public let bizId: Int64
    enum CodingKeys: String, CodingKey {
        case kind = "kind"
        case rawText = "raw_text"
        case bizId = "biz_id"
    }
}

public struct VideoHonorDTO: Decodable, Hashable {
    public let kind: Int32
    public let desc: String
}

public struct UgcSeasonEpisodeDTO: Decodable, Hashable, Identifiable {
    public var id: Int64 { aid }
    public let episodeId: Int64
    public let aid: Int64
    public let bvid: String
    public let cid: Int64
    public let title: String
    public let cover: String
    public let durationSec: Int64
    enum CodingKeys: String, CodingKey {
        case episodeId = "id"
        case aid, bvid, cid, title, cover
        case durationSec = "duration_sec"
    }
}

public struct UgcSeasonSectionDTO: Decodable, Hashable, Identifiable {
    public let id: Int64
    public let title: String
    public let episodes: [UgcSeasonEpisodeDTO]
}

public struct UgcSeasonDTO: Decodable, Hashable, Identifiable {
    public let id: Int64
    public let title: String
    public let cover: String
    public let mid: Int64
    public let intro: String
    public let epCount: Int32
    public let sections: [UgcSeasonSectionDTO]
    enum CodingKeys: String, CodingKey {
        case id, title, cover, mid, intro, sections
        case epCount = "ep_count"
    }
}

public struct VideoViewDTO: Decodable, Hashable {
    public let aid: Int64
    public let bvid: String
    public let cid: Int64
    public let title: String
    public let cover: String
    public let desc: String
    public let descV2: [VideoDescNodeDTO]
    public let durationSec: Int64
    public let pubdate: Int64
    public let ctime: Int64
    public let videos: Int32
    public let stat: VideoStatDTO
    public let owner: VideoOwnerDTO
    public let pages: [VideoPageDTO]
    public let tags: [String]
    public let honor: [VideoHonorDTO]
    public let ugcSeason: UgcSeasonDTO?
    public let redirectUrl: String

    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, cover, desc, videos, pubdate, ctime, stat, owner, pages, tags, honor
        case descV2 = "desc_v2"
        case durationSec = "duration_sec"
        case ugcSeason = "ugc_season"
        case redirectUrl = "redirect_url"
    }
}

public struct RelatedVideoItemDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { aid }
    public let aid: Int64
    public let bvid: String
    public let cid: Int64
    public let title: String
    public let cover: String
    public let author: String
    public let face: String
    public let mid: Int64
    public let durationSec: Int64
    public let play: Int64
    public let danmaku: Int64
    public let pubdate: Int64
    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, cover, author, face, mid, play, danmaku, pubdate
        case durationSec = "duration_sec"
    }
}

// MARK: - Replies

public struct ReplyEmoteDTO: Decodable, Hashable {
    public let name: String
    public let url: String
    /// 1 = small inline (≈18pt), 2 = large inline (≈32pt).
    public let size: Int32
}

public struct ReplyJumpUrlDTO: Decodable, Hashable {
    public let keyword: String
    public let title: String
    public let url: String
    public let prefixIcon: String
    enum CodingKeys: String, CodingKey {
        case keyword, title, url
        case prefixIcon = "prefix_icon"
    }
}

public struct ReplyItemDTO: Decodable, Hashable, Identifiable {
    public var id: Int64 { rpid }
    public let rpid: Int64
    public let oid: Int64
    public let root: Int64
    public let parent: Int64
    public let mid: Int64
    public let uname: String
    public let face: String
    public let level: Int32
    public let vipStatus: Int32
    public let message: String
    public let ctime: Int64
    public var like: Int64
    public var action: Int32
    public let replyCount: Int32
    public let upActionLike: Bool
    public let upActionReply: Bool
    public let location: String
    public let previewReplies: [ReplyItemDTO]
    public let emotes: [ReplyEmoteDTO]
    public let pictures: [String]
    public let jumpUrls: [ReplyJumpUrlDTO]

    enum CodingKeys: String, CodingKey {
        case rpid, oid, root, parent, mid, uname, face, level, message, ctime, like, action, location, emotes, pictures
        case vipStatus = "vip_status"
        case replyCount = "reply_count"
        case upActionLike = "up_action_like"
        case upActionReply = "up_action_reply"
        case previewReplies = "preview_replies"
        case jumpUrls = "jump_urls"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rpid = try c.decode(Int64.self, forKey: .rpid)
        oid = try c.decode(Int64.self, forKey: .oid)
        root = try c.decode(Int64.self, forKey: .root)
        parent = try c.decode(Int64.self, forKey: .parent)
        mid = try c.decode(Int64.self, forKey: .mid)
        uname = try c.decode(String.self, forKey: .uname)
        face = try c.decode(String.self, forKey: .face)
        level = try c.decode(Int32.self, forKey: .level)
        vipStatus = try c.decode(Int32.self, forKey: .vipStatus)
        message = try c.decode(String.self, forKey: .message)
        ctime = try c.decode(Int64.self, forKey: .ctime)
        like = try c.decode(Int64.self, forKey: .like)
        action = try c.decode(Int32.self, forKey: .action)
        replyCount = try c.decode(Int32.self, forKey: .replyCount)
        upActionLike = try c.decode(Bool.self, forKey: .upActionLike)
        upActionReply = try c.decode(Bool.self, forKey: .upActionReply)
        location = try c.decode(String.self, forKey: .location)
        previewReplies = try c.decodeIfPresent([ReplyItemDTO].self, forKey: .previewReplies) ?? []
        emotes = try c.decodeIfPresent([ReplyEmoteDTO].self, forKey: .emotes) ?? []
        pictures = try c.decodeIfPresent([String].self, forKey: .pictures) ?? []
        jumpUrls = try c.decodeIfPresent([ReplyJumpUrlDTO].self, forKey: .jumpUrls) ?? []
    }

    /// Memberwise initializer for synthesizing a local-echo reply when
    /// the user has just submitted a new comment — avoids a refetch
    /// of the entire page just to surface their own message.
    public init(
        rpid: Int64,
        oid: Int64,
        root: Int64 = 0,
        parent: Int64 = 0,
        mid: Int64,
        uname: String,
        face: String,
        level: Int32 = 0,
        vipStatus: Int32 = 0,
        message: String,
        ctime: Int64 = Int64(Date().timeIntervalSince1970),
        like: Int64 = 0,
        action: Int32 = 0,
        replyCount: Int32 = 0,
        upActionLike: Bool = false,
        upActionReply: Bool = false,
        location: String = "",
        previewReplies: [ReplyItemDTO] = [],
        emotes: [ReplyEmoteDTO] = [],
        pictures: [String] = [],
        jumpUrls: [ReplyJumpUrlDTO] = []
    ) {
        self.rpid = rpid
        self.oid = oid
        self.root = root
        self.parent = parent
        self.mid = mid
        self.uname = uname
        self.face = face
        self.level = level
        self.vipStatus = vipStatus
        self.message = message
        self.ctime = ctime
        self.like = like
        self.action = action
        self.replyCount = replyCount
        self.upActionLike = upActionLike
        self.upActionReply = upActionReply
        self.location = location
        self.previewReplies = previewReplies
        self.emotes = emotes
        self.pictures = pictures
        self.jumpUrls = jumpUrls
    }
}

public struct ReplyPageDTO: Decodable {
    public let items: [ReplyItemDTO]
    public let top: ReplyItemDTO?
    public let upperMid: Int64
    public let cursorNext: String
    public let isEnd: Bool
    public let total: Int64
    enum CodingKeys: String, CodingKey {
        case items, top, total
        case upperMid = "upper_mid"
        case cursorNext = "cursor_next"
        case isEnd = "is_end"
    }
}

// MARK: - Interaction results

public struct LikeResultDTO: Decodable {
    public let liked: Int32
    public let toast: String
}

public struct CoinResultDTO: Decodable {
    public let like: Bool
    public let toast: String
}

public struct TripleResultDTO: Decodable {
    public let like: Bool
    public let coin: Bool
    public let fav: Bool
    public let multiply: Int32
    public let prompt: Bool
}

public struct FavoriteResultDTO: Decodable {
    public let prompt: Bool
    public let toast: String
}

/// Server-side relation state for a UGC video.
/// Backed by Rust `interaction.archive_relation`.
public struct ArchiveRelationDTO: Decodable {
    public let liked: Bool
    public let disliked: Bool
    public let favorited: Bool
    public let attention: Bool
    public let coinNumber: Int32

    enum CodingKeys: String, CodingKey {
        case liked, disliked, favorited, attention
        case coinNumber = "coin_number"
    }
}

/// One favourite folder owned by the current user. `favState == 1`
/// indicates the queried video already lives inside this folder.
public struct FavFolderInfoDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { folderId }
    public let folderId: Int64
    public let fid: Int64
    public let mid: Int64
    public let attr: Int32
    public let title: String
    public let favState: Int32
    public let mediaCount: Int32

    enum CodingKeys: String, CodingKey {
        case folderId = "id"
        case fid, mid, attr, title
        case favState = "fav_state"
        case mediaCount = "media_count"
    }
}

/// One image attached to a comment. Wire-compatible with what the
/// `pictures` parameter on `/x/v2/reply/add` expects.
public struct ReplyPictureDTO: Codable, Hashable {
    public let imgSrc: String
    public let imgWidth: Int32
    public let imgHeight: Int32
    public let imgSize: Double

    public init(imgSrc: String, imgWidth: Int32, imgHeight: Int32, imgSize: Double) {
        self.imgSrc = imgSrc
        self.imgWidth = imgWidth
        self.imgHeight = imgHeight
        self.imgSize = imgSize
    }

    enum CodingKeys: String, CodingKey {
        case imgSrc = "img_src"
        case imgWidth = "img_width"
        case imgHeight = "img_height"
        case imgSize = "img_size"
    }
}

public struct ReplyAddResultDTO: Decodable {
    public let rpid: Int64
    public let toast: String
}

public struct UploadedImageDTO: Decodable {
    public let url: String
    public let width: Int32
    public let height: Int32
    public let size: Double
}

public struct EmoteDTO: Decodable, Hashable, Identifiable {
    public var id: String { text + url }
    public let text: String
    public let url: String
}

public struct EmotePackageDTO: Decodable, Hashable, Identifiable {
    public let id: Int64
    public let text: String
    public let url: String
    public let kind: Int32
    public let emotes: [EmoteDTO]
}

// MARK: - User space

public struct UserCardDTO: Decodable, Hashable {
    public let mid: Int64
    public let name: String
    public let face: String
    public let sign: String
    public let follower: Int64
    public let following: Int64
    public let archiveCount: Int64
    public let vipType: Int64
    public let vipStatus: Int64
    public let vipLabel: String

    enum CodingKeys: String, CodingKey {
        case mid, name, face, sign, follower, following
        case archiveCount = "archive_count"
        case vipType = "vip_type"
        case vipStatus = "vip_status"
        case vipLabel = "vip_label"
    }
}

public struct HistoryItemDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { aid }
    public let aid: Int64
    public let bvid: String
    public let cid: Int64
    public let title: String
    public let cover: String
    public let author: String
    public let durationSec: Int64
    public let progressSec: Int64
    public let viewAt: Int64
    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, cover, author
        case durationSec = "duration_sec"
        case progressSec = "progress_sec"
        case viewAt = "view_at"
    }
}

public struct HistoryPageDTO: Decodable {
    public let items: [HistoryItemDTO]
    public let nextMax: Int64
    public let nextViewAt: Int64
    enum CodingKeys: String, CodingKey {
        case items
        case nextMax = "next_max"
        case nextViewAt = "next_view_at"
    }
}

public struct FavResourceItemDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { aid }
    public let aid: Int64
    public let bvid: String
    public let cid: Int64
    public let title: String
    public let cover: String
    public let author: String
    public let durationSec: Int64
    public let play: Int64
    public let danmaku: Int64
    public let pubdate: Int64
    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, cover, author, play, danmaku, pubdate
        case durationSec = "duration_sec"
    }
}

public struct FavResourcePageDTO: Decodable {
    public let items: [FavResourceItemDTO]
    public let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
    }
}

public struct BangumiFollowItemDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { seasonId }
    public let seasonId: Int64
    public let mediaId: Int64
    public let title: String
    public let cover: String
    public let progress: String
    public let evaluate: String
    public let totalCount: Int64
    enum CodingKeys: String, CodingKey {
        case title, cover, progress, evaluate
        case seasonId = "season_id"
        case mediaId = "media_id"
        case totalCount = "total_count"
    }
}

public struct BangumiFollowPageDTO: Decodable {
    public let items: [BangumiFollowItemDTO]
    public let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
    }
}

public struct WatchLaterItemDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { aid }
    public let aid: Int64
    public let bvid: String
    public let cid: Int64
    public let title: String
    public let cover: String
    public let author: String
    public let durationSec: Int64
    public let progressSec: Int64
    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, cover, author
        case durationSec = "duration_sec"
        case progressSec = "progress_sec"
    }
}

public struct RelationUserDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { mid }
    public let mid: Int64
    public let name: String
    public let face: String
    public let sign: String
}

public struct RelationPageDTO: Decodable {
    public let items: [RelationUserDTO]
    public let total: Int64
}

// MARK: - Dynamic feed

public enum DynamicKindDTO: String, Decodable {
    case video, draw, word, forward, pgc, article, live
    case unsupported
}

public struct DynamicAuthorDTO: Decodable, Hashable {
    public let mid: Int64
    public let name: String
    public let face: String
    public let pubLabel: String
    public let pubTs: Int64
    enum CodingKeys: String, CodingKey {
        case mid, name, face
        case pubLabel = "pub_label"
        case pubTs = "pub_ts"
    }
}

public struct DynamicStatDTO: Decodable, Hashable {
    public let like: Int64
    public let comment: Int64
    public let forward: Int64
}

public struct DynamicVideoDTO: Decodable, Hashable {
    public let aid: Int64
    public let bvid: String
    public let title: String
    public let cover: String
    public let durationLabel: String
    public let statLabel: String
    enum CodingKeys: String, CodingKey {
        case aid, bvid, title, cover
        case durationLabel = "duration_label"
        case statLabel = "stat_label"
    }
}

public struct DynamicImageDTO: Decodable, Hashable {
    public let url: String
    public let width: Int64
    public let height: Int64
}

public struct DynamicItemDTO: Decodable, Identifiable, Hashable {
    public var id: String { idStr }
    public let idStr: String
    public let kind: DynamicKindDTO
    public let author: DynamicAuthorDTO
    public let stat: DynamicStatDTO
    public let text: String
    public let video: DynamicVideoDTO?
    public let images: [DynamicImageDTO]
    public let commentId: Int64
    public let commentType: Int32
    /// One-level forward original; the wire layer flattens deeper
    /// nesting so we only carry a single optional indirection here.
    public let orig: DynamicItemRefDTO?

    enum CodingKeys: String, CodingKey {
        case kind, author, stat, text, video, images, orig
        case idStr = "id_str"
        case commentId = "comment_id"
        case commentType = "comment_type"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        idStr = try c.decode(String.self, forKey: .idStr)
        kind = (try? c.decode(DynamicKindDTO.self, forKey: .kind)) ?? .unsupported
        author = try c.decode(DynamicAuthorDTO.self, forKey: .author)
        stat = (try? c.decode(DynamicStatDTO.self, forKey: .stat)) ?? DynamicStatDTO(like: 0, comment: 0, forward: 0)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        video = try? c.decodeIfPresent(DynamicVideoDTO.self, forKey: .video)
        images = (try? c.decodeIfPresent([DynamicImageDTO].self, forKey: .images)) ?? []
        commentId = (try? c.decode(Int64.self, forKey: .commentId)) ?? 0
        commentType = (try? c.decode(Int32.self, forKey: .commentType)) ?? 0
        orig = try? c.decodeIfPresent(DynamicItemRefDTO.self, forKey: .orig)
    }
}

/// Same shape as `DynamicItemDTO` minus the `orig` field (no
/// recursion). Splitting them avoids the infinite-type dance we'd
/// otherwise need for `DynamicItemDTO` to embed itself.
public struct DynamicItemRefDTO: Decodable, Hashable {
    public let idStr: String
    public let kind: DynamicKindDTO
    public let author: DynamicAuthorDTO
    public let stat: DynamicStatDTO
    public let text: String
    public let video: DynamicVideoDTO?
    public let images: [DynamicImageDTO]

    enum CodingKeys: String, CodingKey {
        case kind, author, stat, text, video, images
        case idStr = "id_str"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        idStr = try c.decode(String.self, forKey: .idStr)
        kind = (try? c.decode(DynamicKindDTO.self, forKey: .kind)) ?? .unsupported
        author = try c.decode(DynamicAuthorDTO.self, forKey: .author)
        stat = (try? c.decode(DynamicStatDTO.self, forKey: .stat)) ?? DynamicStatDTO(like: 0, comment: 0, forward: 0)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        video = try? c.decodeIfPresent(DynamicVideoDTO.self, forKey: .video)
        images = (try? c.decodeIfPresent([DynamicImageDTO].self, forKey: .images)) ?? []
    }

    /// Memberwise init used by `DynamicFeedView` when projecting a
    /// fully-formed `DynamicItemDTO` into the (non-recursive) ref
    /// type for shared body rendering.
    public init(idStr: String, kind: DynamicKindDTO, author: DynamicAuthorDTO,
                stat: DynamicStatDTO, text: String,
                video: DynamicVideoDTO?, images: [DynamicImageDTO]) {
        self.idStr = idStr
        self.kind = kind
        self.author = author
        self.stat = stat
        self.text = text
        self.video = video
        self.images = images
    }
}

public struct DynamicFeedPageDTO: Decodable {
    public let items: [DynamicItemDTO]
    public let offset: String
    public let hasMore: Bool
    public let updateBaseline: String
    public let updateNum: Int64
    enum CodingKeys: String, CodingKey {
        case items, offset
        case hasMore = "has_more"
        case updateBaseline = "update_baseline"
        case updateNum = "update_num"
    }
}
