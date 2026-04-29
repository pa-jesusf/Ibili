import Foundation
import IbiliCore

/// Errors surfaced from the Rust core.
public struct CoreError: Error, LocalizedError {
    public let category: String
    public let message: String
    public let code: Int64?
    public var errorDescription: String? { "[\(category)] \(message)" }
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
            AppLog.debug("core", "Core 调用成功", metadata: [
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
        throw resolvedError
    }

    private func callVoid(_ method: String, args: Encodable? = nil) throws {
        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            _ = try callRaw(method, args: args)
            AppLog.debug("core", "Core void 调用完成", metadata: [
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

    public func playUrl(aid: Int64, cid: Int64, qn: Int64 = 0) throws -> PlayUrlDTO {
        struct A: Encodable { let aid: Int64; let cid: Int64; let qn: Int64 }
        return try call("video.playurl", args: A(aid: aid, cid: cid, qn: qn), decoding: PlayUrlDTO.self)
    }

    public func playUrlTV(aid: Int64, cid: Int64, qn: Int64 = 0) throws -> PlayUrlDTO {
        struct A: Encodable { let aid: Int64; let cid: Int64; let qn: Int64 }
        return try call("video.playurl.tv", args: A(aid: aid, cid: cid, qn: qn), decoding: PlayUrlDTO.self)
    }

    public func danmakuList(cid: Int64) throws -> DanmakuTrackDTO {
        struct A: Encodable { let cid: Int64 }
        return try call("danmaku.list", args: A(cid: cid), decoding: DanmakuTrackDTO.self)
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


