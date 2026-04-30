import Foundation
import IbiliCore

/// Errors surfaced from the Rust core.
public struct CoreError: Error, LocalizedError {
    public let category: String
    public let message: String
    public let code: Int64?
    public var errorDescription: String? { "[\(category)] \(message)" }

    public var isLoginExpired: Bool {
        code == -101 || category == "login_expired" || category == "auth_required"
    }
}

extension Notification.Name {
    static let coreLoginExpired = Notification.Name("IbiliCoreLoginExpired")
}

/// Thin Swift wrapper around the C ABI. Single shared instance.
public final class CoreClient: @unchecked Sendable {
    public static let shared = CoreClient()

    private let handle: OpaquePointer
    private let lock = NSLock()

    private init() {
        guard let h = "{}".withCString({ ibili_core_new($0) }) else {
            fatalError("ibili_core_new returned null")
        }
        self.handle = h
    }

    deinit {
        ibili_core_free(handle)
    }

    // MARK: - Dispatch

    private func call<T: Decodable>(_ method: String, args: Encodable? = nil, decoding: T.Type = T.self) throws -> T {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let raw: String
        do {
            raw = try callRaw(method, args: args)
        } catch {
            AppLog.error("core", "Core 调用失败", error: error, metadata: [
                "method": method,
                "stage": "callRaw",
                "ms": elapsedMilliseconds(since: startedAt),
            ])
            throw error
        }

        guard let data = raw.data(using: .utf8) else {
            let error = CoreError(category: "decode", message: "non-utf8", code: nil)
            AppLog.error("core", "Core 返回了非 UTF-8 响应", error: error, metadata: [
                "method": method,
                "ms": elapsedMilliseconds(since: startedAt),
            ])
            throw error
        }

        let env: Envelope<T>
        do {
            env = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            AppLog.error("core", "Core 响应解码失败", error: error, metadata: [
                "method": method,
                "stage": "decode",
                "ms": elapsedMilliseconds(since: startedAt),
            ])
            throw error
        }

        if env.ok, let d = env.data {
            // Promoted from .debug to .info so every API hit is
            // visible in the in-app log viewer without re-enabling
            // verbose mode — makes diagnosing failed requests much
            // easier in the field.
            AppLog.info("core", "API 调用成功", metadata: [
                "method": method,
                "ms": elapsedMilliseconds(since: startedAt),
            ])
            return d
        }

        let resolvedError = env.error.map { CoreError(category: $0.category, message: $0.message, code: $0.code) }
            ?? CoreError(category: "internal", message: "missing data", code: nil)
        AppLog.error("core", "Core 返回错误", error: resolvedError, metadata: [
            "method": method,
            "ms": elapsedMilliseconds(since: startedAt),
        ])
        if resolvedError.isLoginExpired {
            NotificationCenter.default.post(name: .coreLoginExpired,
                                            object: nil,
                                            userInfo: ["method": method])
        }
        throw resolvedError
    }

    private func callVoid(_ method: String, args: Encodable? = nil) throws {
        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            _ = try callRaw(method, args: args)
            AppLog.info("core", "API 调用完成", metadata: [
                "method": method,
                "ms": elapsedMilliseconds(since: startedAt),
            ])
        } catch {
            AppLog.error("core", "Core void 调用失败", error: error, metadata: [
                "method": method,
                "ms": elapsedMilliseconds(since: startedAt),
            ])
            throw error
        }
    }

    private func callRaw(_ method: String, args: Encodable?) throws -> String {
        var argsJson = "{}"
        if let a = args {
            let data = try JSONEncoder().encode(AnyEncodable(a))
            argsJson = String(data: data, encoding: .utf8) ?? "{}"
        }
        lock.lock(); defer { lock.unlock() }
        let resultPtr: UnsafeMutablePointer<CChar>? = method.withCString { mPtr in
            argsJson.withCString { aPtr in
                ibili_call(handle, mPtr, aPtr)
            }
        }
        guard let ptr = resultPtr else {
            throw CoreError(category: "internal", message: "null response", code: nil)
        }
        defer { ibili_string_free(ptr) }
        let s = String(cString: ptr)
        // Inspect ok flag eagerly so non-decoded errors surface.
        if s.contains("\"ok\":false") {
            // still return raw; decoder will parse error
        }
        return s
    }

    // MARK: - High-level methods

    public func sessionSnapshot() -> SessionSnapshotDTO {
        (try? call("session.snapshot", decoding: SessionSnapshotDTO.self)) ?? SessionSnapshotDTO(loggedIn: false, mid: 0, expiresAtSecs: 0)
    }

    public func restoreSession(_ p: PersistedSessionDTO) {
        try? callVoid("session.restore", args: p)
    }

    public func logout() {
        try? callVoid("session.logout")
    }

    public func tvQrStart() throws -> TvQrStartDTO {
        try call("auth.tv_qr.start", decoding: TvQrStartDTO.self)
    }

    public func tvQrPoll(authCode: String) throws -> TvQrPollDTO {
        try call("auth.tv_qr.poll", args: ["auth_code": authCode], decoding: TvQrPollDTO.self)
    }

    public func feedHome(idx: Int64 = 0, ps: Int64 = 20) throws -> FeedPageDTO {
        struct A: Encodable { let idx: Int64; let ps: Int64 }
        return try call("feed.home", args: A(idx: idx, ps: ps), decoding: FeedPageDTO.self)
    }

    public func playUrl(aid: Int64, cid: Int64, qn: Int64 = 0, audioQn: Int64 = 0) throws -> PlayUrlDTO {
        struct A: Encodable { let aid: Int64; let cid: Int64; let qn: Int64; let audio_qn: Int64 }
        return try call("video.playurl", args: A(aid: aid, cid: cid, qn: qn, audio_qn: audioQn), decoding: PlayUrlDTO.self)
    }

    public func playUrlTV(aid: Int64, cid: Int64, qn: Int64 = 0) throws -> PlayUrlDTO {
        struct A: Encodable { let aid: Int64; let cid: Int64; let qn: Int64 }
        return try call("video.playurl.tv", args: A(aid: aid, cid: cid, qn: qn), decoding: PlayUrlDTO.self)
    }

    public func danmakuList(cid: Int64, durationSec: Int64) throws -> DanmakuTrackDTO {
        struct A: Encodable { let cid: Int64; let duration_sec: Int64 }
        return try call("danmaku.list", args: A(cid: cid, duration_sec: durationSec), decoding: DanmakuTrackDTO.self)
    }

    /// Resolve the canonical playback `cid` for a `bvid` via
    /// `/x/web-interface/view`. Used when navigating from the search
    /// results screen, where the search-by-type endpoint does not
    /// return cids on video rows.
    public func videoViewCid(bvid: String) throws -> Int64 {
        struct A: Encodable { let bvid: String }
        struct R: Decodable { let cid: Int64 }
        return try call("video.view_cid", args: A(bvid: bvid), decoding: R.self).cid
    }

    /// Keyword search for videos. `page` is 1-based; `order`, `duration` and
    /// `tids` mirror upstream PiliPlus search parameters.
    public func searchVideo(
        keyword: String,
        page: Int64 = 1,
        order: String? = nil,
        duration: Int64? = nil,
        tids: Int64? = nil
    ) throws -> SearchVideoPageDTO {
        struct A: Encodable {
            let keyword: String
            let page: Int64
            let order: String?
            let duration: Int64?
            let tids: Int64?
        }
        return try call(
            "search.video",
            args: A(
                keyword: keyword,
                page: page,
                order: order,
                duration: duration,
                tids: tids
            ),
            decoding: SearchVideoPageDTO.self
        )
    }

    // MARK: - Video detail

    /// Fetch the full video detail (title, owner, stat, pages, ugc_season,
    /// tags, descV2). Backed by `/x/web-interface/wbi/view`.
    public func videoViewFull(aid: Int64 = 0, bvid: String = "") throws -> VideoViewDTO {
        struct A: Encodable { let aid: Int64; let bvid: String }
        return try call("video.view_full", args: A(aid: aid, bvid: bvid), decoding: VideoViewDTO.self)
    }

    /// List of related videos (`/x/web-interface/archive/related`).
    public func videoRelated(aid: Int64 = 0, bvid: String = "") throws -> [RelatedVideoItemDTO] {
        struct A: Encodable { let aid: Int64; let bvid: String }
        return try call("video.related", args: A(aid: aid, bvid: bvid), decoding: [RelatedVideoItemDTO].self)
    }

    // MARK: - Comments

    /// Top-level comments. `kind` is upstream's `type` (1=视频, 11=动态…).
    /// `sort` is 1 (热门) or 2 (时间). `nextOffset` is the cursor returned
    /// by the previous call (`""` for the first page).
    public func replyMain(
        oid: Int64,
        kind: Int32 = 1,
        sort: Int32 = 1,
        nextOffset: String = ""
    ) throws -> ReplyPageDTO {
        struct A: Encodable {
            let oid: Int64
            let kind: Int32
            let sort: Int32
            let next_offset: String
        }
        return try call(
            "reply.main",
            args: A(oid: oid, kind: kind, sort: sort, next_offset: nextOffset),
            decoding: ReplyPageDTO.self
        )
    }

    /// Replies to a single root comment. Page-based.
    public func replyDetail(
        oid: Int64,
        kind: Int32 = 1,
        root: Int64,
        page: Int64 = 1
    ) throws -> ReplyPageDTO {
        struct A: Encodable {
            let oid: Int64
            let kind: Int32
            let root: Int64
            let page: Int64
        }
        return try call(
            "reply.detail",
            args: A(oid: oid, kind: kind, root: root, page: page),
            decoding: ReplyPageDTO.self
        )
    }

    // MARK: - Write actions

    /// Toggle like. `action` is 1 (点赞) or 2 (取消点赞).
    public func archiveLike(aid: Int64, action: Int32 = 1) throws -> LikeResultDTO {
        struct A: Encodable { let aid: Int64; let action: Int32 }
        return try call("interaction.like", args: A(aid: aid, action: action), decoding: LikeResultDTO.self)
    }

    public func archiveDislike(aid: Int64) throws {
        struct A: Encodable { let aid: Int64 }
        try callVoid("interaction.dislike", args: A(aid: aid))
    }

    public func archiveCoin(aid: Int64, multiply: Int32 = 1, alsoLike: Bool = false) throws -> CoinResultDTO {
        struct A: Encodable { let aid: Int64; let multiply: Int32; let also_like: Bool }
        return try call(
            "interaction.coin",
            args: A(aid: aid, multiply: multiply, also_like: alsoLike),
            decoding: CoinResultDTO.self
        )
    }

    public func archiveTriple(aid: Int64) throws -> TripleResultDTO {
        struct A: Encodable { let aid: Int64 }
        return try call("interaction.triple", args: A(aid: aid), decoding: TripleResultDTO.self)
    }

    public func archiveFavorite(aid: Int64, addIds: [Int64], delIds: [Int64]) throws -> FavoriteResultDTO {
        struct A: Encodable { let aid: Int64; let add_ids: [Int64]; let del_ids: [Int64] }
        return try call(
            "interaction.favorite",
            args: A(aid: aid, add_ids: addIds, del_ids: delIds),
            decoding: FavoriteResultDTO.self
        )
    }

    /// Follow / unfollow a user. `act` is 1 (关注) or 2 (取消关注).
    public func relationModify(fid: Int64, act: Int32) throws {
        struct A: Encodable { let fid: Int64; let act: Int32 }
        try callVoid("interaction.relation", args: A(fid: fid, act: act))
    }

    public func watchLaterAdd(aid: Int64) throws {
        struct A: Encodable { let aid: Int64 }
        try callVoid("interaction.watchlater_add", args: A(aid: aid))
    }

    public func watchLaterDel(aid: Int64) throws {
        struct A: Encodable { let aid: Int64 }
        try callVoid("interaction.watchlater_del", args: A(aid: aid))
    }

    /// Read like/coin/favorite/follow state for a video (server-side).
    public func archiveRelation(aid: Int64 = 0, bvid: String = "") throws -> ArchiveRelationDTO {
        struct A: Encodable { let aid: Int64; let bvid: String }
        return try call("interaction.archive_relation", args: A(aid: aid, bvid: bvid), decoding: ArchiveRelationDTO.self)
    }

    /// List favourite folders owned by `upMid`. Pass `rid` (an aid) to
    /// have the server populate `fav_state` for each folder relative
    /// to that video.
    public func favFolders(rid: Int64 = 0, upMid: Int64) throws -> [FavFolderInfoDTO] {
        struct A: Encodable { let rid: Int64; let up_mid: Int64 }
        return try call("interaction.fav_folders", args: A(rid: rid, up_mid: upMid), decoding: [FavFolderInfoDTO].self)
    }

    /// Report a UGC playback heartbeat so Bilibili records the
    /// position into the user's history. `playedSeconds` is the
    /// current playhead in whole seconds. No-op for anonymous
    /// sessions.
    public func archiveHeartbeat(aid: Int64, bvid: String, cid: Int64, playedSeconds: Int64) throws {
        struct A: Encodable { let aid: Int64; let bvid: String; let cid: Int64; let played_seconds: Int64 }
        try callVoid("interaction.heartbeat", args: A(aid: aid, bvid: bvid, cid: cid, played_seconds: playedSeconds))
    }

    /// Aids currently in the active account's 稍后再看 list.
    public func watchLaterAids() throws -> [Int64] {
        return try call("interaction.watchlater_aids", decoding: [Int64].self)
    }

    /// Like / un-like a single comment. `action` is 1 (like) or 0 (un-like).
    public func replyLike(oid: Int64, kind: Int32 = 1, rpid: Int64, action: Int32) throws {
        struct A: Encodable { let oid: Int64; let kind: Int32; let rpid: Int64; let action: Int32 }
        try callVoid("interaction.reply_like", args: A(oid: oid, kind: kind, rpid: rpid, action: action))
    }

    /// Post a danmaku to the given cid. `progressMs` is the playhead in
    /// milliseconds, `mode` 1 = roll, 4 = bottom, 5 = top, `color` is
    /// packed RGB (white = 16777215).
    public func sendDanmaku(
        aid: Int64,
        cid: Int64,
        msg: String,
        progressMs: Int64,
        mode: Int32 = 1,
        color: Int32 = 16_777_215,
        fontsize: Int32 = 25
    ) throws {
        struct A: Encodable {
            let aid: Int64
            let cid: Int64
            let msg: String
            let progress_ms: Int64
            let mode: Int32
            let color: Int32
            let fontsize: Int32
        }
        try callVoid("interaction.send_danmaku", args: A(
            aid: aid, cid: cid, msg: msg,
            progress_ms: progressMs, mode: mode, color: color, fontsize: fontsize
        ))
    }

    /// Submit a top-level / nested comment. `pictures` carry image
    /// attachments returned from `uploadBfs`. Passing an empty array
    /// posts a text-only comment.
    public func replyAdd(
        oid: Int64,
        kind: Int32 = 1,
        message: String,
        root: Int64 = 0,
        parent: Int64 = 0,
        pictures: [ReplyPictureDTO] = []
    ) throws -> ReplyAddResultDTO {
        struct A: Encodable {
            let oid: Int64
            let kind: Int32
            let message: String
            let root: Int64
            let parent: Int64
            let pictures: [ReplyPictureDTO]
        }
        return try call("interaction.reply_add", args: A(
            oid: oid, kind: kind, message: message,
            root: root, parent: parent, pictures: pictures
        ), decoding: ReplyAddResultDTO.self)
    }

    /// Upload an image attachment. `bytes` is the raw image data
    /// (jpeg/png recommended); the iOS layer base64-encodes it once
    /// for the FFI hop.
    public func uploadBfs(
        bytes: Data,
        fileName: String = "image.jpg"
    ) throws -> UploadedImageDTO {
        struct A: Encodable {
            let bytes_b64: String
            let file_name: String
            let biz: String
            let category: String
        }
        let b64 = bytes.base64EncodedString()
        return try call("interaction.upload_bfs", args: A(
            bytes_b64: b64, file_name: fileName,
            biz: "new_dyn", category: "daily"
        ), decoding: UploadedImageDTO.self)
    }

    /// Fetch the current account's emote panel for the given business
    /// (`reply` for the comment composer).
    public func emotePanel(business: String = "reply") throws -> [EmotePackageDTO] {
        struct A: Encodable { let business: String }
        return try call("interaction.emote_panel", args: A(business: business),
                        decoding: [EmotePackageDTO].self)
    }
}

private func elapsedMilliseconds(since start: CFAbsoluteTime) -> String {
    String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
}

// MARK: - Envelope decoding

private struct Envelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: ErrPayload?
    struct ErrPayload: Decodable {
        let category: String
        let message: String
        let code: Int64?
    }
}

/// Erases an `Encodable` through a stored encoder closure.
private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init(_ wrapped: Encodable) {
        self._encode = { enc in try wrapped.encode(to: enc) }
    }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}


