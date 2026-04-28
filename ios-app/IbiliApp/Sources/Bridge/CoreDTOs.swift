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

    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, cover, author, play, danmaku
        case durationSec = "duration_sec"
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
    public let debugMessage: String?
    enum CodingKeys: String, CodingKey {
        case url, format, quality
        case audioUrl = "audio_url"
        case streamType = "stream_type"
        case durationMs = "duration_ms"
        case backupUrls = "backup_urls"
        case audioBackupUrls = "audio_backup_urls"
        case acceptQuality = "accept_quality"
        case acceptDescription = "accept_description"
        case debugMessage = "debug_message"
    }
}

public struct DanmakuItemDTO: Decodable {
    public let timeSec: Float
    public let mode: Int32
    public let color: UInt32
    public let fontSize: Int32
    public let text: String
    enum CodingKeys: String, CodingKey {
        case timeSec = "time_sec"
        case mode
        case color
        case fontSize = "font_size"
        case text
    }
}

public struct DanmakuTrackDTO: Decodable {
    public let items: [DanmakuItemDTO]
}
