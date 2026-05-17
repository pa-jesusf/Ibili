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

public struct FeedItemDTO: Codable, Identifiable, Hashable {
    public var id: Int64 { isPGC ? (epID > 0 ? epID : aid) : aid }
    public let aid: Int64
    public let bvid: String
    public let cid: Int64
    public let epID: Int64
    public let seasonID: Int64
    public let isPGC: Bool
    public let title: String
    public let cover: String
    public let author: String
    public let durationSec: Int64
    public let play: Int64
    public let danmaku: Int64
    /// Unix seconds. `0` when upstream did not provide a publish date —
    /// the recommendation feed often omits it, search always carries it.
    public let pubdate: Int64
    public let isFollowed: Bool

    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, cover, author, play, danmaku, pubdate
        case epID = "ep_id"
        case seasonID = "season_id"
        case isPGC = "is_pgc"
        case durationSec = "duration_sec"
        case isFollowed = "is_followed"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aid = try c.decode(Int64.self, forKey: .aid)
        bvid = try c.decodeIfPresent(String.self, forKey: .bvid) ?? ""
        cid = try c.decodeIfPresent(Int64.self, forKey: .cid) ?? 0
        epID = try c.decodeIfPresent(Int64.self, forKey: .epID) ?? 0
        seasonID = try c.decodeIfPresent(Int64.self, forKey: .seasonID) ?? 0
        isPGC = try c.decodeIfPresent(Bool.self, forKey: .isPGC) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        durationSec = try c.decodeIfPresent(Int64.self, forKey: .durationSec) ?? 0
        play = try c.decodeIfPresent(Int64.self, forKey: .play) ?? 0
        danmaku = try c.decodeIfPresent(Int64.self, forKey: .danmaku) ?? 0
        pubdate = try c.decodeIfPresent(Int64.self, forKey: .pubdate) ?? 0
        isFollowed = try c.decodeIfPresent(Bool.self, forKey: .isFollowed) ?? false
    }

    /// Memberwise convenience init for synthetic feed items (related,
    /// season episodes, deep-link routing). Mirrors the wire format
    /// field order; `pubdate` defaults to 0 since these synthetic
    /// origins never carry a publish date.
    public init(
        aid: Int64, bvid: String, cid: Int64, title: String,
        cover: String, author: String, durationSec: Int64,
        play: Int64, danmaku: Int64, pubdate: Int64 = 0,
        isFollowed: Bool = false, epID: Int64 = 0,
        seasonID: Int64 = 0, isPGC: Bool = false
    ) {
        self.aid = aid; self.bvid = bvid; self.cid = cid
        self.epID = epID; self.seasonID = seasonID; self.isPGC = isPGC
        self.title = title; self.cover = cover; self.author = author
        self.durationSec = durationSec; self.play = play
        self.danmaku = danmaku; self.pubdate = pubdate
        self.isFollowed = isFollowed
    }
}

// MARK: - Live

public struct LiveFeedItemDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { roomID }
    public let roomID: Int64
    public let uid: Int64
    public let title: String
    public let cover: String
    public let systemCover: String
    public let uname: String
    public let face: String
    public let areaName: String
    public let watchedLabel: String
    public let isFollowed: Bool

    enum CodingKeys: String, CodingKey {
        case uid, title, cover, uname, face
        case roomID = "room_id"
        case systemCover = "system_cover"
        case areaName = "area_name"
        case watchedLabel = "watched_label"
        case isFollowed = "is_followed"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomID = try c.decodeIfPresent(Int64.self, forKey: .roomID) ?? 0
        uid = try c.decodeIfPresent(Int64.self, forKey: .uid) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        systemCover = try c.decodeIfPresent(String.self, forKey: .systemCover) ?? ""
        uname = try c.decodeIfPresent(String.self, forKey: .uname) ?? ""
        face = try c.decodeIfPresent(String.self, forKey: .face) ?? ""
        areaName = try c.decodeIfPresent(String.self, forKey: .areaName) ?? ""
        watchedLabel = try c.decodeIfPresent(String.self, forKey: .watchedLabel) ?? ""
        isFollowed = try c.decodeIfPresent(Bool.self, forKey: .isFollowed) ?? false
    }
}

public struct LiveFeedPageDTO: Decodable {
    public let items: [LiveFeedItemDTO]
    public let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
    }
}

public struct LiveQualityDTO: Decodable, Hashable, Identifiable {
    public var id: Int64 { qn }
    public let qn: Int64
    public let label: String
}

public struct LiveRoomInfoDTO: Decodable, Hashable {
    public let roomID: Int64
    public let uid: Int64
    public let title: String
    public let cover: String
    public let anchorName: String
    public let anchorFace: String
    public let watchedLabel: String
    public let liveStatus: Int64
    public let liveTime: Int64

    enum CodingKeys: String, CodingKey {
        case uid, title, cover
        case roomID = "room_id"
        case anchorName = "anchor_name"
        case anchorFace = "anchor_face"
        case watchedLabel = "watched_label"
        case liveStatus = "live_status"
        case liveTime = "live_time"
    }
}

public struct LivePlayUrlDTO: Decodable {
    public let url: String
    public let quality: Int64
    public let acceptQuality: [LiveQualityDTO]
    public let liveStatus: Int64

    enum CodingKeys: String, CodingKey {
        case url, quality
        case acceptQuality = "accept_quality"
        case liveStatus = "live_status"
    }
}

public struct LiveDanmakuHostDTO: Decodable, Hashable {
    public let host: String
    public let port: Int64
    public let wsPort: Int64
    public let wssPort: Int64

    enum CodingKeys: String, CodingKey {
        case host, port
        case wsPort = "ws_port"
        case wssPort = "wss_port"
    }
}

public struct LiveDanmakuInfoDTO: Decodable {
    public let token: String
    public let hostList: [LiveDanmakuHostDTO]

    enum CodingKeys: String, CodingKey {
        case token
        case hostList = "host_list"
    }
}

public struct LiveDanmakuMessageDTO: Decodable, Identifiable, Hashable {
    public let id: String
    public let uid: Int64
    public let name: String
    public let text: String
    public let isSelf: Bool
    public let emotes: [ReplyEmoteDTO]

    enum CodingKeys: String, CodingKey {
        case id
        case uid
        case name
        case text
        case isSelf = "is_self"
        case emotes
    }

    public init(id: String, uid: Int64, name: String, text: String, isSelf: Bool, emotes: [ReplyEmoteDTO] = []) {
        self.id = id
        self.uid = uid
        self.name = name
        self.text = text
        self.isSelf = isSelf
        self.emotes = emotes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        uid = try c.decode(Int64.self, forKey: .uid)
        name = try c.decode(String.self, forKey: .name)
        text = try c.decode(String.self, forKey: .text)
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        emotes = try c.decodeIfPresent([ReplyEmoteDTO].self, forKey: .emotes) ?? []
    }
}

public struct LiveDanmakuHistoryDTO: Decodable {
    public let items: [LiveDanmakuMessageDTO]
}

public struct PlayUrlDTO: Codable {
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
    public let videoWidth: Int?
    public let videoHeight: Int?
    public let videoFrameRate: String?
    public let videoRange: String?
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
    public let subtitles: [VideoSubtitleDTO]
    public let viewPoints: [VideoViewPointDTO]

    public init(
        url: String,
        audioUrl: String?,
        format: String,
        streamType: String,
        quality: Int64,
        durationMs: Int64,
        backupUrls: [String],
        audioBackupUrls: [String],
        acceptQuality: [Int64],
        acceptDescription: [String],
        videoCodec: String,
        audioCodec: String,
        videoWidth: Int?,
        videoHeight: Int?,
        videoFrameRate: String?,
        videoRange: String?,
        debugMessage: String?,
        audioQuality: Int64,
        audioQualityLabel: String,
        acceptAudioQuality: [Int64],
        acceptAudioDescription: [String],
        lastPlayTimeMs: Int64,
        lastPlayCid: Int64,
        subtitles: [VideoSubtitleDTO] = [],
        viewPoints: [VideoViewPointDTO] = []
    ) {
        self.url = url
        self.audioUrl = audioUrl
        self.format = format
        self.streamType = streamType
        self.quality = quality
        self.durationMs = durationMs
        self.backupUrls = backupUrls
        self.audioBackupUrls = audioBackupUrls
        self.acceptQuality = acceptQuality
        self.acceptDescription = acceptDescription
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoFrameRate = videoFrameRate
        self.videoRange = videoRange
        self.debugMessage = debugMessage
        self.audioQuality = audioQuality
        self.audioQualityLabel = audioQualityLabel
        self.acceptAudioQuality = acceptAudioQuality
        self.acceptAudioDescription = acceptAudioDescription
        self.lastPlayTimeMs = lastPlayTimeMs
        self.lastPlayCid = lastPlayCid
        self.subtitles = subtitles
        self.viewPoints = viewPoints
    }
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
        case videoWidth = "video_width"
        case videoHeight = "video_height"
        case videoFrameRate = "video_frame_rate"
        case videoRange = "video_range"
        case debugMessage = "debug_message"
        case audioQuality = "audio_quality"
        case audioQualityLabel = "audio_quality_label"
        case acceptAudioQuality = "accept_audio_quality"
        case acceptAudioDescription = "accept_audio_description"
        case lastPlayTimeMs = "last_play_time_ms"
        case lastPlayCid = "last_play_cid"
        case subtitles
        case viewPoints = "view_points"
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
        if let width = try c.decodeIfPresent(Int.self, forKey: .videoWidth), width > 0 {
            videoWidth = width
        } else {
            videoWidth = nil
        }
        if let height = try c.decodeIfPresent(Int.self, forKey: .videoHeight), height > 0 {
            videoHeight = height
        } else {
            videoHeight = nil
        }
        videoFrameRate = try c.decodeIfPresent(String.self, forKey: .videoFrameRate)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        videoRange = try c.decodeIfPresent(String.self, forKey: .videoRange)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        debugMessage = try c.decodeIfPresent(String.self, forKey: .debugMessage)
        audioQuality = try c.decodeIfPresent(Int64.self, forKey: .audioQuality) ?? 0
        audioQualityLabel = try c.decodeIfPresent(String.self, forKey: .audioQualityLabel) ?? ""
        acceptAudioQuality = try c.decodeIfPresent([Int64].self, forKey: .acceptAudioQuality) ?? []
        acceptAudioDescription = try c.decodeIfPresent([String].self, forKey: .acceptAudioDescription) ?? []
        lastPlayTimeMs = try c.decodeIfPresent(Int64.self, forKey: .lastPlayTimeMs) ?? 0
        lastPlayCid = try c.decodeIfPresent(Int64.self, forKey: .lastPlayCid) ?? 0
        subtitles = try c.decodeIfPresent([VideoSubtitleDTO].self, forKey: .subtitles) ?? []
        viewPoints = try c.decodeIfPresent([VideoViewPointDTO].self, forKey: .viewPoints) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(audioUrl, forKey: .audioUrl)
        try c.encode(format, forKey: .format)
        try c.encode(streamType, forKey: .streamType)
        try c.encode(quality, forKey: .quality)
        try c.encode(durationMs, forKey: .durationMs)
        try c.encode(backupUrls, forKey: .backupUrls)
        try c.encode(audioBackupUrls, forKey: .audioBackupUrls)
        try c.encode(acceptQuality, forKey: .acceptQuality)
        try c.encode(acceptDescription, forKey: .acceptDescription)
        try c.encode(videoCodec, forKey: .videoCodec)
        try c.encode(audioCodec, forKey: .audioCodec)
        try c.encodeIfPresent(videoWidth, forKey: .videoWidth)
        try c.encodeIfPresent(videoHeight, forKey: .videoHeight)
        try c.encodeIfPresent(videoFrameRate, forKey: .videoFrameRate)
        try c.encodeIfPresent(videoRange, forKey: .videoRange)
        try c.encodeIfPresent(debugMessage, forKey: .debugMessage)
        try c.encode(audioQuality, forKey: .audioQuality)
        try c.encode(audioQualityLabel, forKey: .audioQualityLabel)
        try c.encode(acceptAudioQuality, forKey: .acceptAudioQuality)
        try c.encode(acceptAudioDescription, forKey: .acceptAudioDescription)
        try c.encode(lastPlayTimeMs, forKey: .lastPlayTimeMs)
        try c.encode(lastPlayCid, forKey: .lastPlayCid)
        try c.encode(subtitles, forKey: .subtitles)
        try c.encode(viewPoints, forKey: .viewPoints)
    }

    public func replacingLocalMediaURLs(videoURL: URL, audioURL: URL?) -> PlayUrlDTO {
        PlayUrlDTO(
            url: videoURL.absoluteString,
            audioUrl: audioURL?.absoluteString,
            format: format,
            streamType: "offline_\(streamType)",
            quality: quality,
            durationMs: durationMs,
            backupUrls: [],
            audioBackupUrls: [],
            acceptQuality: acceptQuality,
            acceptDescription: acceptDescription,
            videoCodec: videoCodec,
            audioCodec: audioURL == nil ? "" : audioCodec,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            videoFrameRate: videoFrameRate,
            videoRange: videoRange,
            debugMessage: debugMessage,
            audioQuality: audioURL == nil ? 0 : audioQuality,
            audioQualityLabel: audioURL == nil ? "" : audioQualityLabel,
            acceptAudioQuality: acceptAudioQuality,
            acceptAudioDescription: acceptAudioDescription,
            lastPlayTimeMs: 0,
            lastPlayCid: lastPlayCid,
            subtitles: subtitles,
            viewPoints: viewPoints
        )
    }
}

// MARK: - Bangumi / Anime Tracking

public struct AnimeOAuthStartDTO: Codable {
    public let authorizeUrl: String

    enum CodingKeys: String, CodingKey {
        case authorizeUrl = "authorize_url"
    }
}

public struct AnimeOAuthTokenDTO: Codable {
    public let accessToken: String
    public let refreshToken: String
    public let tokenType: String
    public let expiresIn: Int64
    public let expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
    }
}

public struct AnimeBangumiUserDTO: Codable, Hashable {
    public let id: Int64
    public let username: String
    public let nickname: String
    public let avatar: String
}

public struct AnimeSubjectImageDTO: Codable, Hashable {
    public let large: String
    public let common: String
    public let medium: String
    public let small: String
    public let grid: String
}

public struct AnimeInfoItemDTO: Codable, Hashable, Identifiable {
    public var id: String { "\(key)-\(value)" }
    public let key: String
    public let value: String
}

public struct AnimeEpisodeDTO: Codable, Hashable, Identifiable {
    public let id: Int64
    public let subjectID: Int64
    public let sort: Double
    public let ep: Double
    public let name: String
    public let nameCn: String
    public let duration: String
    public let airdate: String
    public let desc: String
    public let collectionType: Int64

    public init(
        id: Int64,
        subjectID: Int64,
        sort: Double,
        ep: Double,
        name: String,
        nameCn: String,
        duration: String,
        airdate: String,
        desc: String,
        collectionType: Int64
    ) {
        self.id = id
        self.subjectID = subjectID
        self.sort = sort
        self.ep = ep
        self.name = name
        self.nameCn = nameCn
        self.duration = duration
        self.airdate = airdate
        self.desc = desc
        self.collectionType = collectionType
    }

    enum CodingKeys: String, CodingKey {
        case id, sort, ep, name, duration, airdate, desc
        case subjectID = "subject_id"
        case nameCn = "name_cn"
        case collectionType = "collection_type"
    }

    public var displayTitle: String {
        if !nameCn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nameCn }
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        let number = Int(sort.rounded())
        return number > 0 ? "第 \(number) 集" : "正片"
    }
}

public struct AnimeSubjectDTO: Codable, Hashable, Identifiable {
    public let id: Int64
    public let name: String
    public let nameCn: String
    public let summary: String
    public let date: String
    public let image: AnimeSubjectImageDTO
    public let ratingScore: Double
    public let ratingTotal: Int64
    public let rank: Int64
    public let collectionType: Int64
    public let collectionLabel: String
    public let epStatus: Int64
    public let totalEpisodes: Int64
    public let tags: [String]
    public let aliases: [String]
    public let infoItems: [AnimeInfoItemDTO]
    public let episodes: [AnimeEpisodeDTO]

    public init(
        id: Int64,
        name: String,
        nameCn: String,
        summary: String,
        date: String,
        image: AnimeSubjectImageDTO,
        ratingScore: Double,
        ratingTotal: Int64,
        rank: Int64,
        collectionType: Int64,
        collectionLabel: String,
        epStatus: Int64,
        totalEpisodes: Int64,
        tags: [String],
        aliases: [String],
        infoItems: [AnimeInfoItemDTO],
        episodes: [AnimeEpisodeDTO]
    ) {
        self.id = id
        self.name = name
        self.nameCn = nameCn
        self.summary = summary
        self.date = date
        self.image = image
        self.ratingScore = ratingScore
        self.ratingTotal = ratingTotal
        self.rank = rank
        self.collectionType = collectionType
        self.collectionLabel = collectionLabel
        self.epStatus = epStatus
        self.totalEpisodes = totalEpisodes
        self.tags = tags
        self.aliases = aliases
        self.infoItems = infoItems
        self.episodes = episodes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, date, image, rank, tags, aliases, episodes
        case nameCn = "name_cn"
        case ratingScore = "rating_score"
        case ratingTotal = "rating_total"
        case collectionType = "collection_type"
        case collectionLabel = "collection_label"
        case epStatus = "ep_status"
        case totalEpisodes = "total_episodes"
        case infoItems = "info_items"
    }

    public var displayTitle: String {
        nameCn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : nameCn
    }

    public var coverURL: String {
        [image.large, image.common, image.medium, image.small, image.grid]
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }
}

public struct AnimeCollectionItemDTO: Codable, Hashable, Identifiable {
    public var id: Int64 { subject.id }
    public let subject: AnimeSubjectDTO
    public let collectionType: Int64
    public let collectionLabel: String
    public let updatedAt: String
    public let epStatus: Int64

    enum CodingKeys: String, CodingKey {
        case subject
        case collectionType = "collection_type"
        case collectionLabel = "collection_label"
        case updatedAt = "updated_at"
        case epStatus = "ep_status"
    }
}

public struct AnimeCollectionPageDTO: Codable {
    public let total: Int64
    public let page: Int64
    public let pageSize: Int64
    public let items: [AnimeCollectionItemDTO]

    enum CodingKeys: String, CodingKey {
        case total, page, items
        case pageSize = "page_size"
    }
}

public struct AnimeSubjectSearchPageDTO: Codable {
    public let total: Int64
    public let page: Int64
    public let pageSize: Int64
    public let items: [AnimeSubjectDTO]

    enum CodingKeys: String, CodingKey {
        case total, page, items
        case pageSize = "page_size"
    }
}

public struct AnimeSourceDTO: Codable, Hashable, Identifiable {
    public let id: String
    public let factoryID: String
    public let version: Int64
    public let name: String
    public let description: String
    public let iconURL: String
    public let tier: String
    public var enabled: Bool
    public let arguments: AnyCodableValue

    public init(
        id: String,
        factoryID: String,
        version: Int64,
        name: String,
        description: String,
        iconURL: String,
        tier: String,
        enabled: Bool,
        arguments: AnyCodableValue
    ) {
        self.id = id
        self.factoryID = factoryID
        self.version = version
        self.name = name
        self.description = description
        self.iconURL = iconURL
        self.tier = tier
        self.enabled = enabled
        self.arguments = arguments
    }

    enum CodingKeys: String, CodingKey {
        case id, version, name, description, tier, enabled, arguments
        case factoryID = "factory_id"
        case iconURL = "icon_url"
    }
}

public struct AnimeSourceUpdateDTO: Codable {
    public let sources: [AnimeSourceDTO]
    public let updatedAt: Int64

    public init(sources: [AnimeSourceDTO], updatedAt: Int64) {
        self.sources = sources
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case sources
        case updatedAt = "updated_at"
    }
}

public struct AnimeMediaCandidateDTO: Codable, Hashable, Identifiable {
    public let id: String
    public let sourceID: String
    public let sourceName: String
    public let title: String
    public let url: String
    public let pageURL: String
    public let kind: String
    public let qualityLabel: String
    public let isSupported: Bool
    public let unsupportedReason: String
    public let referer: String
    public let userAgent: String
    public let headers: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, title, url, kind, referer, headers
        case sourceID = "source_id"
        case sourceName = "source_name"
        case pageURL = "page_url"
        case qualityLabel = "quality_label"
        case isSupported = "is_supported"
        case unsupportedReason = "unsupported_reason"
        case userAgent = "user_agent"
    }
}

public struct AnimeMediaFetchResultDTO: Codable {
    public let candidates: [AnimeMediaCandidateDTO]
    public let diagnostics: AnimeMediaFetchDiagnosticsDTO
}

public struct AnimeMediaFetchDiagnosticsDTO: Codable, Hashable {
    public let enabledSources: Int64
    public let attemptedQueries: Int64
    public let succeededQueries: Int64
    public let failedQueries: Int64
    public let unsupportedCandidates: Int64
    public let supportedCandidates: Int64
    public let messages: [String]
    public let sourceReports: [AnimeMediaSourceReportDTO]

    enum CodingKeys: String, CodingKey {
        case messages
        case enabledSources = "enabled_sources"
        case attemptedQueries = "attempted_queries"
        case succeededQueries = "succeeded_queries"
        case failedQueries = "failed_queries"
        case unsupportedCandidates = "unsupported_candidates"
        case supportedCandidates = "supported_candidates"
        case sourceReports = "source_reports"
    }
}

public struct AnimeMediaSourceReportDTO: Codable, Hashable, Identifiable {
    public let sourceID: String
    public let sourceName: String
    public let factoryID: String
    public let attemptedQueries: Int64
    public let succeededQueries: Int64
    public let failedQueries: Int64
    public let candidateCount: Int64
    public let supportedCount: Int64
    public let status: String
    public let message: String
    public let captchaURL: String
    public let captchaKind: String

    public var id: String { sourceID }

    enum CodingKeys: String, CodingKey {
        case status, message
        case sourceID = "source_id"
        case sourceName = "source_name"
        case factoryID = "factory_id"
        case attemptedQueries = "attempted_queries"
        case succeededQueries = "succeeded_queries"
        case failedQueries = "failed_queries"
        case candidateCount = "candidate_count"
        case supportedCount = "supported_count"
        case captchaURL = "captcha_url"
        case captchaKind = "captcha_kind"
    }
}

public struct AnimePlayUrlDTO: Codable, Hashable {
    public let url: String
    public let format: String
    public let title: String
    public let cover: String
    public let referer: String
    public let userAgent: String
    public let headers: [String: String]
    public let durationMs: Int64

    enum CodingKeys: String, CodingKey {
        case url, format, title, cover, referer, headers
        case userAgent = "user_agent"
        case durationMs = "duration_ms"
    }
}

public struct AnimeEpisodePlayResultDTO: Codable {
    public let play: AnimePlayUrlDTO?
    public let candidates: [AnimeMediaCandidateDTO]
    public let diagnostics: AnimeMediaFetchDiagnosticsDTO
}

public enum AnyCodableValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyCodableValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AnyCodableValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public struct VideoSubtitleDTO: Codable, Identifiable, Hashable {
    public var id: String { "\(lan)|\(subtitleUrl)|\(subtitleUrlV2)" }
    public let lan: String
    public let lanDoc: String
    public let subtitleUrl: String
    public let subtitleUrlV2: String
    public let isAI: Bool

    enum CodingKeys: String, CodingKey {
        case lan
        case lanDoc = "lan_doc"
        case subtitleUrl = "subtitle_url"
        case subtitleUrlV2 = "subtitle_url_v2"
        case isAI = "is_ai"
    }
}

public struct VideoViewPointDTO: Codable, Identifiable, Hashable {
    public var id: String { "\(fromSec)-\(toSec)-\(content)" }
    public let kind: Int64
    public let fromSec: Int64
    public let toSec: Int64
    public let content: String
    public let imageUrl: String

    enum CodingKeys: String, CodingKey {
        case kind
        case fromSec = "from_sec"
        case toSec = "to_sec"
        case content
        case imageUrl = "image_url"
    }
}

public struct SubtitleTrackDTO: Hashable {
    public let items: [SubtitleCueDTO]
}

public struct SubtitleCueDTO: Hashable, Identifiable {
    public var id: String { "\(fromSec)-\(toSec)-\(content)" }
    public let fromSec: Double
    public let toSec: Double
    public let content: String
}

struct SubtitleResponseDTO: Decodable {
    let body: [SubtitleBodyDTO]

    enum CodingKeys: String, CodingKey {
        case body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        body = try c.decodeIfPresent([SubtitleBodyDTO].self, forKey: .body) ?? []
    }
}

struct SubtitleBodyDTO: Decodable {
    let from: Double
    let to: Double
    let content: String
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public struct PackagingOfflineBuildDTO: Decodable {
    public let diagnosticsDirectory: String
    public let workspaceRootDirectory: String
    public let masterPlaylistPath: String
    public let videoPlaylistPath: String
    public let audioPlaylistPath: String?
    public let streamManifestPath: String
    public let authoringSummaryPath: String
    public let sourceKind: String
    public let hasAudio: Bool
    public let startupReady: Bool
    public let stagedFiles: [String]
    public let generatedFiles: [String]
    public let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case diagnosticsDirectory = "diagnostics_dir"
        case workspaceRootDirectory = "workspace_root_dir"
        case masterPlaylistPath = "master_playlist_path"
        case videoPlaylistPath = "video_playlist_path"
        case audioPlaylistPath = "audio_playlist_path"
        case streamManifestPath = "stream_manifest_path"
        case authoringSummaryPath = "authoring_summary_path"
        case sourceKind = "source_kind"
        case hasAudio = "has_audio"
        case startupReady = "startup_ready"
        case stagedFiles = "staged_files"
        case generatedFiles = "generated_files"
        case warnings
    }
}

public struct OfflinePlayUrlDTO: Decodable {
    public let play: PlayUrlDTO
    public let losslessContainerCandidates: [String]
    public let canLosslessRemux: Bool
    public let losslessNote: String

    enum CodingKeys: String, CodingKey {
        case losslessContainerCandidates = "lossless_container_candidates"
        case canLosslessRemux = "can_lossless_remux"
        case losslessNote = "lossless_note"
    }

    public init(from decoder: Decoder) throws {
        play = try PlayUrlDTO(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        losslessContainerCandidates = try c.decodeIfPresent([String].self, forKey: .losslessContainerCandidates) ?? ["mp4", "m4v", "mov"]
        canLosslessRemux = try c.decodeIfPresent(Bool.self, forKey: .canLosslessRemux) ?? false
        losslessNote = try c.decodeIfPresent(String.self, forKey: .losslessNote) ?? ""
    }
}

public struct DanmakuItemDTO: Codable {
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

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timeSec, forKey: .timeSec)
        try c.encode(mode, forKey: .mode)
        try c.encode(color, forKey: .color)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(text, forKey: .text)
        try c.encode(weight, forKey: .weight)
        try c.encode(hasWeight, forKey: .hasWeight)
        try c.encode(midHash, forKey: .midHash)
        try c.encode(likeCount, forKey: .likeCount)
        try c.encode(colorful, forKey: .colorful)
        try c.encode(count, forKey: .count)
        try c.encode(isSelf, forKey: .isSelf)
    }
}

public struct DanmakuTrackDTO: Codable {
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

public struct SearchLiveItemDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { roomID }
    public let roomID: Int64
    public let uid: Int64
    public let title: String
    public let cover: String
    public let uname: String
    public let face: String
    public let online: Int64
    public let areaName: String

    enum CodingKeys: String, CodingKey {
        case uid, title, cover, uname, face, online
        case roomID = "room_id"
        case areaName = "area_name"
    }
}

public struct SearchLivePageDTO: Decodable {
    public let items: [SearchLiveItemDTO]
    public let numResults: Int64
    public let numPages: Int64
    enum CodingKeys: String, CodingKey {
        case items
        case numResults = "num_results"
        case numPages = "num_pages"
    }
}

public struct SearchUserItemDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { mid }
    public let mid: Int64
    public let uname: String
    public let face: String
    public let sign: String
    public let fans: Int64
    public let videos: Int64
    public let level: Int32
    public let isLive: Bool
    public let roomID: Int64
    public let officialDesc: String

    enum CodingKeys: String, CodingKey {
        case mid, uname, face, sign, fans, videos, level
        case isLive = "is_live"
        case roomID = "room_id"
        case officialDesc = "official_desc"
    }
}

public struct SearchUserPageDTO: Decodable {
    public let items: [SearchUserItemDTO]
    public let numResults: Int64
    public let numPages: Int64
    enum CodingKeys: String, CodingKey {
        case items
        case numResults = "num_results"
        case numPages = "num_pages"
    }
}

public struct SearchArticleItemDTO: Decodable, Identifiable, Hashable {
    public let id: Int64
    public let title: String
    public let desc: String
    public let cover: String
    public let mid: Int64
    public let categoryName: String
    public let view: Int64
    public let like: Int64
    public let reply: Int64
    public let pubTime: Int64

    enum CodingKeys: String, CodingKey {
        case id, title, desc, cover, mid, view, like, reply
        case categoryName = "category_name"
        case pubTime = "pub_time"
    }
}

public struct SearchArticlePageDTO: Decodable {
    public let items: [SearchArticleItemDTO]
    public let numResults: Int64
    public let numPages: Int64
    enum CodingKeys: String, CodingKey {
        case items
        case numResults = "num_results"
        case numPages = "num_pages"
    }
}

public struct SearchPgcItemDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { seasonID }
    public let seasonID: Int64
    public let mediaID: Int64
    public let title: String
    public let cover: String
    public let areas: String
    public let styles: String
    public let seasonType: Int64
    public let seasonTypeName: String
    public let score: String
    public let indexShow: String
    public let desc: String
    public let pubtime: Int64

    enum CodingKeys: String, CodingKey {
        case title, cover, areas, styles, score, desc, pubtime
        case seasonID = "season_id"
        case mediaID = "media_id"
        case seasonType = "season_type"
        case seasonTypeName = "season_type_name"
        case indexShow = "index_show"
    }
}

public struct SearchPgcPageDTO: Decodable {
    public let items: [SearchPgcItemDTO]
    public let numResults: Int64
    public let numPages: Int64
    enum CodingKeys: String, CodingKey {
        case items
        case numResults = "num_results"
        case numPages = "num_pages"
    }
}

public struct PgcEpisodeDTO: Decodable, Hashable, Identifiable {
    public var id: Int64 { epID }
    public let epID: Int64
    public let aid: Int64
    public let bvid: String
    public let cid: Int64
    public let title: String
    public let longTitle: String
    public let cover: String
    public let durationSec: Int64
    public let pubTime: Int64
    public let badge: String

    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, cover, badge
        case epID = "ep_id"
        case longTitle = "long_title"
        case durationSec = "duration_sec"
        case pubTime = "pub_time"
    }
}

public struct PgcStatDTO: Decodable, Hashable {
    public let view: Int64
    public let danmaku: Int64
    public let reply: Int64
    public let favorite: Int64
    public let coin: Int64
    public let share: Int64
    public let like: Int64
}

public struct PgcSeasonDTO: Decodable, Hashable {
    public let seasonID: Int64
    public let mediaID: Int64
    public let title: String
    public let seasonTitle: String
    public let cover: String
    public let evaluate: String
    public let subtitle: String
    public let areas: [String]
    public let actors: String
    public let ratingScore: String
    public let newEpDesc: String
    public let seasonType: Int64
    public let upMID: Int64
    public let upName: String
    public let stat: PgcStatDTO
    public let episodes: [PgcEpisodeDTO]

    enum CodingKeys: String, CodingKey {
        case title, cover, evaluate, subtitle, areas, actors, stat, episodes
        case seasonID = "season_id"
        case mediaID = "media_id"
        case seasonTitle = "season_title"
        case ratingScore = "rating_score"
        case newEpDesc = "new_ep_desc"
        case seasonType = "season_type"
        case upMID = "up_mid"
        case upName = "up_name"
    }
}

// MARK: - Article / opus

public struct ArticleDetailDTO: Decodable, Hashable {
    public let id: String
    public let kind: String
    public let title: String
    public let summary: String
    public let cover: String
    public let author: ArticleAuthorDTO
    public let stat: ArticleStatDTO
    public let pubTs: Int64
    public let commentId: Int64
    public let commentType: Int32
    public let dynId: String
    public let url: String
    public let blocks: [ArticleBlockDTO]

    enum CodingKeys: String, CodingKey {
        case id, kind, title, summary, cover, author, stat, url, blocks
        case pubTs = "pub_ts"
        case commentId = "comment_id"
        case commentType = "comment_type"
        case dynId = "dyn_id"
    }
}

public struct ArticleAuthorDTO: Decodable, Hashable {
    public let mid: Int64
    public let name: String
    public let face: String
}

public struct ArticleStatDTO: Decodable, Hashable {
    public let view: Int64
    public let like: Int64
    public let reply: Int64
    public let favorite: Int64
    public let share: Int64
}

public struct ArticleImageDTO: Decodable, Hashable {
    public let url: String
    public let width: Int64
    public let height: Int64
}

public struct ArticleLinkCardDTO: Decodable, Hashable {
    public let title: String
    public let subtitle: String
    public let cover: String
    public let url: String
}

public struct ArticleBlockDTO: Decodable, Hashable, Identifiable {
    public var id: Int { hashValue }
    public let kind: String
    public let text: String
    public let richText: [ArticleRichNodeDTO]
    public let images: [ArticleImageDTO]
    public let linkCard: ArticleLinkCardDTO?
    public let codeLang: String

    enum CodingKeys: String, CodingKey {
        case kind, text, images
        case richText = "rich_text"
        case linkCard = "link_card"
        case codeLang = "code_lang"
    }
}

public struct ArticleRichNodeDTO: Decodable, Hashable, Identifiable {
    public var id: Int { hashValue }
    public let text: String
    public let url: String
    public let kind: String
    public let rid: String
    public let emojiURL: String
    public let bold: Bool
    public let italic: Bool
    public let strikethrough: Bool

    enum CodingKeys: String, CodingKey {
        case text, url, kind, rid, bold, italic, strikethrough
        case emojiURL = "emoji_url"
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

    public init(name: String, url: String, size: Int32) {
        self.name = name
        self.url = url
        self.size = size
    }
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

    public func withReplyAdded(_ reply: ReplyItemDTO? = nil) -> ReplyItemDTO {
        var preview = previewReplies
        if let reply, !preview.contains(where: { $0.rpid == reply.rpid }) {
            preview.insert(reply, at: 0)
            if preview.count > 3 {
                preview = Array(preview.prefix(3))
            }
        }
        return ReplyItemDTO(
            rpid: rpid,
            oid: oid,
            root: root,
            parent: parent,
            mid: mid,
            uname: uname,
            face: face,
            level: level,
            vipStatus: vipStatus,
            message: message,
            ctime: ctime,
            like: like,
            action: action,
            replyCount: replyCount + 1,
            upActionLike: upActionLike,
            upActionReply: upActionReply,
            location: location,
            previewReplies: preview,
            emotes: emotes,
            pictures: pictures,
            jumpUrls: jumpUrls
        )
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

public struct UserLiveRoomDTO: Decodable, Hashable {
    public let roomID: Int64
    public let liveStatus: Int64
    public let title: String
    public let cover: String
    public let online: Int64
    public let url: String

    public var isLive: Bool {
        liveStatus == 1 && roomID > 0
    }

    enum CodingKeys: String, CodingKey {
        case title, cover, online, url
        case roomID = "room_id"
        case liveStatus = "live_status"
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

public struct SubscriptionFolderDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { folderID }
    public let folderID: Int64
    public let fid: Int64
    public let mid: Int64
    public let title: String
    public let cover: String
    public let intro: String
    public let upperMid: Int64
    public let upperName: String
    public let mediaCount: Int64
    public let viewCount: Int64
    public let favState: Int64
    public let type: Int64

    enum CodingKeys: String, CodingKey {
        case folderID = "id"
        case fid, mid, title, cover, intro
        case upperMid = "upper_mid"
        case upperName = "upper_name"
        case mediaCount = "media_count"
        case viewCount = "view_count"
        case favState = "fav_state"
        case type
    }
}

public struct SubscriptionFolderPageDTO: Decodable {
    public let items: [SubscriptionFolderDTO]
    public let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
    }
}

public struct SubscriptionResourceDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { aid }
    public let aid: Int64
    public let bvid: String
    public let cid: Int64
    public let title: String
    public let cover: String
    public let durationSec: Int64
    public let play: Int64
    public let danmaku: Int64
    public let pubdate: Int64
    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, cover, play, danmaku, pubdate
        case durationSec = "duration_sec"
    }
}

public struct SubscriptionResourcePageDTO: Decodable {
    public let info: SubscriptionFolderDTO?
    public let items: [SubscriptionResourceDTO]
    public let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case info, items
        case hasMore = "has_more"
    }
}

public struct BangumiFollowItemDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { seasonId }
    public let seasonId: Int64
    public let mediaId: Int64
    public let title: String
    public let cover: String
    public let badge: String
    public let renewalTime: String
    public let progress: String
    public let evaluate: String
    public let totalCount: Int64
    public let isFinish: Int64
    public let newEpIndexShow: String
    enum CodingKeys: String, CodingKey {
        case title, cover, badge, progress, evaluate
        case seasonId = "season_id"
        case mediaId = "media_id"
        case renewalTime = "renewal_time"
        case totalCount = "total_count"
        case isFinish = "is_finish"
        case newEpIndexShow = "new_ep_index_show"
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
    public let cid: Int64
    public let epID: Int64
    public let seasonID: Int64
    public let isPGC: Bool
    public let title: String
    public let cover: String
    public let durationLabel: String
    public let statLabel: String
    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, cover
        case epID = "ep_id"
        case seasonID = "season_id"
        case isPGC = "is_pgc"
        case durationLabel = "duration_label"
        case statLabel = "stat_label"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aid = try c.decodeIfPresent(Int64.self, forKey: .aid) ?? 0
        bvid = try c.decodeIfPresent(String.self, forKey: .bvid) ?? ""
        cid = try c.decodeIfPresent(Int64.self, forKey: .cid) ?? 0
        epID = try c.decodeIfPresent(Int64.self, forKey: .epID) ?? 0
        seasonID = try c.decodeIfPresent(Int64.self, forKey: .seasonID) ?? 0
        isPGC = try c.decodeIfPresent(Bool.self, forKey: .isPGC) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        durationLabel = try c.decodeIfPresent(String.self, forKey: .durationLabel) ?? ""
        statLabel = try c.decodeIfPresent(String.self, forKey: .statLabel) ?? ""
    }
}

public struct DynamicLiveDTO: Decodable, Hashable {
    public let roomID: Int64
    public let title: String
    public let cover: String
    public let areaName: String
    public let watchedLabel: String
    public let liveStatus: Int64

    public var isOpenable: Bool {
        roomID > 0
    }

    enum CodingKeys: String, CodingKey {
        case title, cover
        case roomID = "room_id"
        case areaName = "area_name"
        case watchedLabel = "watched_label"
        case liveStatus = "live_status"
    }
}

public struct DynamicArticleDTO: Decodable, Hashable {
    public let id: String
    public let kind: String
    public let title: String
    public let summary: String
    public let cover: String
    public let jumpURL: String
    public let commentId: Int64
    public let commentType: Int32

    enum CodingKeys: String, CodingKey {
        case id, kind, title, summary, cover
        case jumpURL = "jump_url"
        case commentId = "comment_id"
        case commentType = "comment_type"
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
    public let live: DynamicLiveDTO?
    public let article: DynamicArticleDTO?
    public let images: [DynamicImageDTO]
    public let commentId: Int64
    public let commentType: Int32
    /// One-level forward original; the wire layer flattens deeper
    /// nesting so we only carry a single optional indirection here.
    public let orig: DynamicItemRefDTO?

    enum CodingKeys: String, CodingKey {
        case kind, author, stat, text, video, live, article, images, orig
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
        live = try? c.decodeIfPresent(DynamicLiveDTO.self, forKey: .live)
        article = try? c.decodeIfPresent(DynamicArticleDTO.self, forKey: .article)
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
    public let live: DynamicLiveDTO?
    public let article: DynamicArticleDTO?
    public let images: [DynamicImageDTO]

    enum CodingKeys: String, CodingKey {
        case kind, author, stat, text, video, live, article, images
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
        live = try? c.decodeIfPresent(DynamicLiveDTO.self, forKey: .live)
        article = try? c.decodeIfPresent(DynamicArticleDTO.self, forKey: .article)
        images = (try? c.decodeIfPresent([DynamicImageDTO].self, forKey: .images)) ?? []
    }

    /// Memberwise init used by `DynamicFeedView` when projecting a
    /// fully-formed `DynamicItemDTO` into the (non-recursive) ref
    /// type for shared body rendering.
    public init(idStr: String, kind: DynamicKindDTO, author: DynamicAuthorDTO,
                stat: DynamicStatDTO, text: String,
                video: DynamicVideoDTO?, live: DynamicLiveDTO?, article: DynamicArticleDTO? = nil,
                images: [DynamicImageDTO]) {
        self.idStr = idStr
        self.kind = kind
        self.author = author
        self.stat = stat
        self.text = text
        self.video = video
        self.live = live
        self.article = article
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

public struct SpaceArcItemDTO: Decodable, Identifiable, Hashable {
    public var id: Int64 { aid }
    public let aid: Int64
    public let bvid: String
    public let title: String
    public let cover: String
    public let author: String
    public let durationLabel: String
    public let play: Int64
    public let danmaku: Int64
    public let comment: Int64
    public let created: Int64
    enum CodingKeys: String, CodingKey {
        case aid, bvid, title, cover, author, play, danmaku, comment, created
        case durationLabel = "duration_label"
    }
}

public struct SpaceArcSearchPageDTO: Decodable {
    public let items: [SpaceArcItemDTO]
    public let count: Int64
    public let page: Int64
    public let pageSize: Int64
    enum CodingKeys: String, CodingKey {
        case items, count, page
        case pageSize = "page_size"
    }
}
