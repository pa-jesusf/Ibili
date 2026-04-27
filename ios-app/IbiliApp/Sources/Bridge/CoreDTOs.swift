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
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case mid
        case expiresAtSecs = "expires_at_secs"
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

    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, cover, author
        case durationSec = "duration_sec"
    }
}

public struct PlayUrlDTO: Decodable {
    public let url: String
    public let format: String
    public let quality: Int64
    public let durationMs: Int64
    public let backupUrls: [String]
    enum CodingKeys: String, CodingKey {
        case url, format, quality
        case durationMs = "duration_ms"
        case backupUrls = "backup_urls"
    }
}
