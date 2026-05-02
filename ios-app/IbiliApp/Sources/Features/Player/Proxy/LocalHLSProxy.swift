import Foundation
import Network
import UIKit
import os

/// In-process HTTP server bound to `127.0.0.1` that serves a tiny HLS view
/// of B 站 DASH streams. Sized to one app instance — there is exactly one
/// proxy and any number of registered playback tokens.
///
/// Routes (`<token>` is registered via `register(...)`):
/// * `GET /play/<token>/master.m3u8`  → master playlist
/// * `GET /play/<token>/video.m3u8`   → video media playlist
/// * `GET /play/<token>/audio.m3u8`   → audio media playlist (when present)
/// * `GET /play/<token>/v.seg`        → byte-range pass-through to video CDN
/// * `GET /play/<token>/a.seg`        → byte-range pass-through to audio CDN
///
/// All upstream requests carry the right UA + Referer; failed segment
/// requests automatically retry the next CDN candidate, so playback
/// self-heals across host outages mid-stream.
final class LocalHLSProxy: @unchecked Sendable {
    static let shared = LocalHLSProxy()
    private static let maxDiagnosticsExports = 5
    private static let listenerHealthcheckTimeout: TimeInterval = 0.2

    struct Source {
        let videoCandidates: [URL]
        let audioCandidates: [URL]
        let videoProbe: ISOBMFF.Probe
        let audioProbe: ISOBMFF.Probe?
        let videoBandwidthHint: Int?
        let videoCodec: String
        let audioCodec: String
        let videoWidthHint: Int?
        let videoHeightHint: Int?
        let videoFrameRateHint: String?
        let videoRangeHint: String?

        var videoResolutionHint: (Int, Int)? {
            guard let videoWidthHint, let videoHeightHint else { return nil }
            return (videoWidthHint, videoHeightHint)
        }

        var authoringVideoCodec: String? {
            videoProbe.videoMetadata?.codecString?.trimmedNilIfEmpty
                ?? videoCodec.trimmedNilIfEmpty
        }

        var authoringSupplementalVideoCodec: String? {
            videoProbe.videoMetadata?.supplementalCodecString?.trimmedNilIfEmpty
        }

        var authoringVideoRange: String? {
            videoProbe.videoMetadata?.videoRange?.rawValue
                ?? videoRangeHint?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().trimmedNilIfEmpty
        }
    }

    private let queue = DispatchQueue(label: "ibili.hls.proxy", qos: .userInitiated)
    private let healthCheckQueue = DispatchQueue(label: "ibili.hls.proxy.healthcheck", qos: .userInitiated)
    private var listener: NWListener?
    /// All mutable state lives behind this lock. `OSAllocatedUnfairLock` is
    /// async-safe (unlike `NSLock`), which matters because the connection
    /// dispatcher is `async`.
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var port: UInt16 = 0
        var sources: [String: Source] = [:]
        /// `true` between the listener's `.ready` event and the next
        /// `.failed` / `.cancelled` event. iOS will tear the listener
        /// down once the app has been suspended in the background long
        /// enough; we use this flag plus `port == 0` to know we have to
        /// re-bind on the next playback request.
        var listenerHealthy: Bool = false
    }

    /// Whether the local proxy is still serving requests. The Player
    /// view checks this when it returns to foreground so it can rebuild
    /// the AVPlayer item against a freshly-bound port.
    var isHealthy: Bool { validateExistingListener() }

    var currentPort: UInt16 { state.withLock { $0.port } }

    private init() {
        // We deliberately do NOT proactively invalidate the listener
        // on `didEnterBackgroundNotification`. iOS keeps apps running
        // in the background as long as an `AVAudioSession` with
        // category `.playback` is active, which means our `NWListener`
        // socket also stays alive — the user expects playback (and
        // therefore segment fetches against `127.0.0.1:<port>`) to
        // continue when the screen is locked.
        //
        // For the case where iOS *does* eventually suspend us (the
        // user navigates away from the player and stays away long
        // enough for the audio session to deactivate), the listener
        // emits `.failed` / `.cancelled` on resume, which flips
        // `listenerHealthy` to `false`; the next `register(...)` call
        // then rebinds a fresh port via `ensureRunning()`. The
        // `PlayerViewModel.isEngineAlive` check + scene-phase recovery
        // path in `PlayerView` handles that without any preemptive
        // teardown here.
    }

    /// Force the next `register(...)` to bind a fresh listener. Safe to
    /// call from any thread; idempotent.
    func invalidate(reason: String) {
        let wasHealthy = state.withLock { state -> Bool in
            let was = state.listenerHealthy
            state.listenerHealthy = false
            state.port = 0
            return was
        }
        guard wasHealthy else { return }
        AppLog.info("player", "主动封闭 HLS 代理监听", metadata: ["reason": reason])
        if let stale = listener {
            listener = nil
            stale.cancel()
        }
    }

    // MARK: - Public API

    /// Register a source and receive the `master.m3u8` URL on `127.0.0.1`.
    /// Idempotent: re-registering the same `token` overwrites the prior entry.
    func register(token: String, source: Source) throws -> URL {
        try ensureRunning()
        let port = state.withLock { s -> UInt16 in s.sources[token] = source; return s.port }
        guard let url = URL(string: "http://127.0.0.1:\(port)/play/\(token)/master.m3u8") else {
            throw ProxyServerError.invalidServerURL
        }
        return url
    }

    /// Drop a token. Callers should call this when they're done with a
    /// particular stream (player teardown, quality switch).
    func unregister(token: String) {
        state.withLock { _ = $0.sources.removeValue(forKey: token) }
    }

    /// Drop everything. Used by the engine on full teardown.
    func unregisterAll() {
        state.withLock { $0.sources.removeAll() }
    }

    private func lookupSource(token: String) -> Source? {
        state.withLock { $0.sources[token] }
    }

    func exportDiagnostics(token: String, reason: String) async -> URL? {
        guard let source = lookupSource(token: token) else {
            AppLog.warning("player", "HLS 诊断导出失败：token 不存在", metadata: ["token": token])
            return nil
        }
        do {
            let dir = try makeDiagnosticsDirectory(token: token)
            let master = HLSPlaylistBuilder.makeMaster(
                videoBandwidthHint: source.videoBandwidthHint,
                videoProbe: source.videoProbe,
                audioProbe: source.audioProbe,
                videoMediaPath: "video.m3u8",
                audioMediaPath: source.audioProbe == nil ? nil : "audio.m3u8",
                videoCodec: source.videoCodec,
                audioCodec: source.audioCodec,
                videoResolutionHint: source.videoResolutionHint,
                videoRangeHint: source.videoRangeHint,
                frameRateHint: source.videoFrameRateHint
            )
            try write(master, to: dir.appendingPathComponent("master.m3u8"))
            let mediaTargetDuration = sharedTargetDuration(videoProbe: source.videoProbe, audioProbe: source.audioProbe)
            try write(HLSPlaylistBuilder.makeMedia(probe: source.videoProbe, segmentPath: "v.seg", targetDurationOverride: mediaTargetDuration),
                      to: dir.appendingPathComponent("video.m3u8"))
            if let audioProbe = source.audioProbe {
                try write(HLSPlaylistBuilder.makeMedia(probe: audioProbe, segmentPath: "a.seg", targetDurationOverride: mediaTargetDuration),
                          to: dir.appendingPathComponent("audio.m3u8"))
            }

            var exported: [String: String] = [:]
            exported.merge(try await exportStreamArtifacts(
                label: "video",
                candidates: source.videoCandidates,
                probe: source.videoProbe,
                directory: dir
            )) { _, new in new }
            if let audioProbe = source.audioProbe, !source.audioCandidates.isEmpty {
                exported.merge(try await exportStreamArtifacts(
                    label: "audio",
                    candidates: source.audioCandidates,
                    probe: audioProbe,
                    directory: dir
                )) { _, new in new }
            }

            let metadataURL = dir.appendingPathComponent("metadata.json")
            var metadata: [String: Any] = [
                "reason": reason,
                "token": token,
                "audioCodec": source.audioCodec,
                "videoCandidates": source.videoCandidates.map(\.absoluteString),
                "audioCandidates": source.audioCandidates.map(\.absoluteString),
                "videoInitRange": rangeDescription(source.videoProbe.initSegment.range),
                "videoFirstFragmentRange": source.videoProbe.index.entries.first.map { rangeDescription($0.range) } ?? "-",
                "audioInitRange": source.audioProbe.map { rangeDescription($0.initSegment.range) } ?? "-",
                "audioFirstFragmentRange": source.audioProbe?.index.entries.first.map { rangeDescription($0.range) } ?? "-",
                "videoFragmentCount": source.videoProbe.index.entries.count,
                "audioFragmentCount": source.audioProbe?.index.entries.count ?? 0,
                "exported": exported,
            ]
            if let videoCodec = source.authoringVideoCodec {
                metadata["videoCodec"] = videoCodec
            }
            if let supplementalVideoCodec = source.authoringSupplementalVideoCodec {
                metadata["videoSupplementalCodec"] = supplementalVideoCodec
            }
            if let width = source.videoWidthHint ?? source.videoProbe.videoMetadata?.width {
                metadata["videoWidth"] = width
            }
            if let height = source.videoHeightHint ?? source.videoProbe.videoMetadata?.height {
                metadata["videoHeight"] = height
            }
            if let videoRange = source.authoringVideoRange {
                metadata["videoRange"] = videoRange
            }
            if let frameRate = source.videoFrameRateHint, !frameRate.isEmpty {
                metadata["videoFrameRate"] = frameRate
            }
            try writeJSONObject(metadata, to: metadataURL)

            let offlinePackagingBuild = await buildOfflinePackagingWorkspace(diagnosticsDirectory: dir)
            if let workspaceRootDirectory = offlinePackagingBuild["workspaceRootDirectory"] as? String {
                exported["packaging-workspace"] = workspaceRootDirectory
            }

            metadata["offlinePackagingBuild"] = offlinePackagingBuild
            metadata["exported"] = exported
            try writeJSONObject(metadata, to: metadataURL)
            AppLog.info("player", "HLS 诊断导出完成", metadata: [
                "path": dir.path,
                "reason": reason,
                "token": token,
            ])
            return dir
        } catch {
            AppLog.error("player", "HLS 诊断导出失败", error: error, metadata: [
                "token": token,
                "reason": reason,
            ])
            return nil
        }
    }

    private func makeDiagnosticsDirectory(token: String) throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = documents.appendingPathComponent("ibili-diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let safeTimestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let shortToken = String(token.prefix(8))
        let dir = root
            .appendingPathComponent("hls-\(safeTimestamp)-\(shortToken)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pruneDiagnosticsDirectories(root: root, keepingLatest: Self.maxDiagnosticsExports)
        return dir
    }

    private func pruneDiagnosticsDirectories(root: URL, keepingLatest limit: Int) {
        guard limit > 0 else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let directories = contents.compactMap { url -> (url: URL, createdAt: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey]),
                  values.isDirectory == true else {
                return nil
            }
            return (url, values.creationDate ?? .distantPast)
        }
        .sorted {
            if $0.createdAt == $1.createdAt {
                return $0.url.lastPathComponent > $1.url.lastPathComponent
            }
            return $0.createdAt > $1.createdAt
        }

        guard directories.count > limit else { return }
        for entry in directories.dropFirst(limit) {
            do {
                try fm.removeItem(at: entry.url)
                AppLog.info("player", "清理过期诊断导出", metadata: [
                    "path": entry.url.path,
                ])
            } catch {
                AppLog.warning("player", "清理过期诊断导出失败", metadata: [
                    "path": entry.url.path,
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    private func exportStreamArtifacts(label: String,
                                       candidates: [URL],
                                       probe: ISOBMFF.Probe,
                                       directory: URL) async throws -> [String: String] {
        guard let url = candidates.first else { return [:] }
        var exported: [String: String] = [:]
        let initRange = probe.initSegment.range
        let initResponse = try await ProxyURLLoader.shared.fetch(url: url, range: initRange)
        let initName = "\(label)-init.mp4"
        try initResponse.data.write(to: directory.appendingPathComponent(initName), options: [.atomic])
        exported[initName] = rangeDescription(initRange)

        if let first = probe.index.entries.first {
            let fragmentResponse = try await ProxyURLLoader.shared.fetch(url: url, range: first.range)
            let fragmentName = "\(label)-fragment-000.m4s"
            try fragmentResponse.data.write(to: directory.appendingPathComponent(fragmentName), options: [.atomic])
            exported[fragmentName] = rangeDescription(first.range)
        }
        return exported
    }

    private func buildOfflinePackagingWorkspace(diagnosticsDirectory: URL) async -> [String: Any] {
        AppLog.info("player", "开始生成 offline packaging workspace", metadata: [
            "diagnostics": diagnosticsDirectory.path,
        ])

        do {
            let result = try await Task.detached(priority: .utility) {
                try CoreClient.shared.packagingOfflineBuild(
                    diagnosticsDirectory: diagnosticsDirectory.path
                )
            }.value

            AppLog.info("player", "offline packaging workspace 已生成", metadata: [
                "diagnostics": result.diagnosticsDirectory,
                "workspace": result.workspaceRootDirectory,
                "sourceKind": result.sourceKind,
                "hasAudio": String(result.hasAudio),
                "startupReady": String(result.startupReady),
                "generatedFiles": String(result.generatedFiles.count),
                "warnings": String(result.warnings.count),
            ])

            var summary: [String: Any] = [
                "status": "built",
                "diagnosticsDirectory": result.diagnosticsDirectory,
                "workspaceRootDirectory": result.workspaceRootDirectory,
                "masterPlaylistPath": result.masterPlaylistPath,
                "videoPlaylistPath": result.videoPlaylistPath,
                "streamManifestPath": result.streamManifestPath,
                "authoringSummaryPath": result.authoringSummaryPath,
                "sourceKind": result.sourceKind,
                "hasAudio": result.hasAudio,
                "startupReady": result.startupReady,
                "stagedFiles": result.stagedFiles,
                "generatedFiles": result.generatedFiles,
                "warnings": result.warnings,
            ]
            if let audioPlaylistPath = result.audioPlaylistPath {
                summary["audioPlaylistPath"] = audioPlaylistPath
            }
            return summary
        } catch {
            let nsError = error as NSError
            AppLog.error("player", "offline packaging workspace 生成失败", error: error, metadata: [
                "diagnostics": diagnosticsDirectory.path,
            ])
            return [
                "status": "failed",
                "diagnosticsDirectory": diagnosticsDirectory.path,
                "errorDomain": nsError.domain,
                "errorCode": nsError.code,
                "errorDescription": nsError.localizedDescription,
            ]
        }
    }

    private func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url, options: [.atomic])
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
    }

    private func rangeDescription(_ range: ClosedRange<UInt64>) -> String {
        "\(range.lowerBound)-\(range.upperBound)"
    }

    // MARK: - Lifecycle

    @discardableResult
    private func validateExistingListener() -> Bool {
        let maybePort = state.withLock { state -> UInt16? in
            guard state.listenerHealthy, state.port != 0 else { return nil }
            return state.port
        }

        guard let port = maybePort else { return false }
        guard listener != nil else {
            state.withLock { $0.listenerHealthy = false; $0.port = 0 }
            return false
        }
        guard canReachListener(on: port) else {
            state.withLock { $0.listenerHealthy = false; $0.port = 0 }
            AppLog.warning("player", "HLS 代理监听探活失败，准备重绑", metadata: [
                "port": String(port),
            ])
            if let stale = listener {
                listener = nil
                stale.cancel()
            }
            return false
        }
        return true
    }

    private func canReachListener(on port: UInt16) -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }

        struct HealthCheckState {
            var finished = false
            var ready = false
        }

        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let semaphore = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock<HealthCheckState>(initialState: HealthCheckState())

        let finish: (Bool) -> Void = { didBecomeReady in
            let shouldSignal = state.withLock { state -> Bool in
                guard !state.finished else { return false }
                state.finished = true
                state.ready = didBecomeReady
                return true
            }
            if shouldSignal {
                semaphore.signal()
            }
        }

        connection.stateUpdateHandler = { netState in
            switch netState {
            case .ready:
                finish(true)
                connection.cancel()
            case .waiting(_), .failed(_), .cancelled:
                finish(false)
            default:
                break
            }
        }

        connection.start(queue: healthCheckQueue)
        let waitResult = semaphore.wait(timeout: .now() + Self.listenerHealthcheckTimeout)
        if waitResult == .timedOut {
            state.withLock {
                if !$0.finished { $0.finished = true }
            }
            connection.cancel()
            return false
        }
        return state.withLock { $0.ready }
    }

    private func ensureRunning() throws {
        if validateExistingListener() {
            return
        }
        // Drop any zombie listener — iOS may have cancelled it under us
        // while the app was suspended.
        if let stale = listener {
            self.listener = nil
            stale.cancel()
        }
        state.withLock { $0.port = 0; $0.listenerHealthy = false }
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] netState in
            guard let self else { return }
            guard self.listener === listener else { return }
            switch netState {
            case .ready:
                if let port = listener.port {
                    self.state.withLock {
                        $0.port = port.rawValue
                        $0.listenerHealthy = true
                    }
                    AppLog.info("player", "HLS 代理已启动", metadata: ["port": String(port.rawValue)])
                }
            case .failed(let err):
                self.state.withLock { $0.listenerHealthy = false; $0.port = 0 }
                AppLog.error("player", "HLS 代理监听失败", error: err)
            case .cancelled:
                self.state.withLock { $0.listenerHealthy = false; $0.port = 0 }
                AppLog.warning("player", "HLS 代理监听已取消", metadata: [:])
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener.start(queue: queue)
        // Wait briefly for `ready` so the caller gets a real port back.
        let deadline = Date().addingTimeInterval(2)
        var resolvedPort: UInt16 = 0
        while Date() < deadline {
            resolvedPort = state.withLock { $0.port }
            if resolvedPort != 0 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard resolvedPort != 0 else {
            self.listener = nil
            listener.cancel()
            throw ProxyServerError.startupTimedOut
        }
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn: conn, accumulated: Data())
    }

    private func receiveRequest(conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                AppLog.warning("player", "HLS 代理收报错误", metadata: ["error": error.debugDescription])
                conn.cancel(); return
            }
            var buf = accumulated
            if let data { buf.append(data) }
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = buf.subdata(in: 0..<headerEnd.lowerBound)
                guard let request = HTTPRequestHead.parse(head) else {
                    self.respondError(conn: conn, status: 400, body: "Bad Request")
                    return
                }
                Task { [weak self] in
                    await self?.dispatch(request: request, conn: conn)
                }
            } else if isComplete {
                conn.cancel()
            } else {
                self.receiveRequest(conn: conn, accumulated: buf)
            }
        }
    }

    private func dispatch(request: HTTPRequestHead, conn: NWConnection) async {
        let path = request.path
        let parts = path.split(separator: "/").map(String.init)

        // Expected: ["play", "<token>", "<resource>"]
        guard parts.count == 3, parts[0] == "play" else {
            respondError(conn: conn, status: 404, body: "Not Found")
            return
        }
        let token = parts[1]
        let resource = parts[2]
        let source = lookupSource(token: token)
        guard let source else {
            respondError(conn: conn, status: 410, body: "Token expired")
            return
        }
        switch resource {
        case "master.m3u8":
            serveMasterPlaylist(source: source, conn: conn)
        case "video.m3u8":
            serveMediaPlaylist(
                probe: source.videoProbe,
                segmentPath: "v.seg",
                targetDurationOverride: sharedTargetDuration(videoProbe: source.videoProbe, audioProbe: source.audioProbe),
                conn: conn
            )
        case "audio.m3u8":
            if let probe = source.audioProbe {
                serveMediaPlaylist(
                    probe: probe,
                    segmentPath: "a.seg",
                    targetDurationOverride: sharedTargetDuration(videoProbe: source.videoProbe, audioProbe: source.audioProbe),
                    conn: conn
                )
            } else {
                respondError(conn: conn, status: 404, body: "No audio track")
            }
        case "v.seg":
            await serveSegment(candidates: source.videoCandidates,
                               request: request,
                               conn: conn,
                               label: "video")
        case "a.seg":
            if !source.audioCandidates.isEmpty {
                await serveSegment(candidates: source.audioCandidates,
                                   request: request,
                                   conn: conn,
                                   label: "audio")
            } else {
                respondError(conn: conn, status: 404, body: "No audio track")
            }
        default:
            respondError(conn: conn, status: 404, body: "Not Found")
        }
    }

    // MARK: - Playlist routes

    private func serveMasterPlaylist(source: Source, conn: NWConnection) {
        let body = HLSPlaylistBuilder.makeMaster(
            videoBandwidthHint: source.videoBandwidthHint,
            videoProbe: source.videoProbe,
            audioProbe: source.audioProbe,
            videoMediaPath: "video.m3u8",
            audioMediaPath: source.audioProbe == nil ? nil : "audio.m3u8",
            videoCodec: source.videoCodec,
            audioCodec: source.audioCodec,
            videoResolutionHint: source.videoResolutionHint,
            videoRangeHint: source.videoRangeHint,
            frameRateHint: source.videoFrameRateHint
        )
        respondText(conn: conn, body: body, contentType: "application/vnd.apple.mpegurl")
    }

    private func serveMediaPlaylist(probe: ISOBMFF.Probe,
                                    segmentPath: String,
                                    targetDurationOverride: Int? = nil,
                                    conn: NWConnection) {
        let body = HLSPlaylistBuilder.makeMedia(
            probe: probe,
            segmentPath: segmentPath,
            targetDurationOverride: targetDurationOverride
        )
        respondText(conn: conn, body: body, contentType: "application/vnd.apple.mpegurl")
    }

    private func sharedTargetDuration(videoProbe: ISOBMFF.Probe, audioProbe: ISOBMFF.Probe?) -> Int {
        let videoTarget = Int(videoProbe.index.targetDurationSec.rounded(.up))
        let audioTarget = Int(audioProbe?.index.targetDurationSec.rounded(.up) ?? 0)
        return max(1, videoTarget, audioTarget)
    }

    // MARK: - Segment route (with CDN failover)

    private func serveSegment(candidates: [URL],
                              request: HTTPRequestHead,
                              conn: NWConnection,
                              label: String) async {
        guard let range = request.range else {
            respondError(conn: conn, status: 416, body: "Range required")
            return
        }
        var lastError: Error?
        for url in candidates {
            do {
                let resp = try await ProxyURLLoader.shared.fetch(url: url, range: range)
                respondBinary(conn: conn,
                              status: 206,
                              body: resp.data,
                              contentType: "video/mp4",
                              extraHeaders: [
                                "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound)/\(resp.totalBytes.map(String.init) ?? "*")",
                                "Accept-Ranges": "bytes",
                              ])
                return
            } catch {
                lastError = error
                AppLog.warning("player", "HLS 代理 segment 失败重试", metadata: [
                    "label": label,
                    "host": url.host ?? "?",
                    "range": "\(range.lowerBound)-\(range.upperBound)",
                    "error": ProxyURLLoader.debugSummary(of: error),
                ])
            }
        }
        let detail = lastError.map { ProxyURLLoader.debugSummary(of: $0) } ?? "no candidates"
        respondError(conn: conn, status: 502, body: "Upstream failed: \(detail)")
    }

    // MARK: - Response writers

    private func respondText(conn: NWConnection, body: String, contentType: String) {
        respondBinary(conn: conn,
                      status: 200,
                      body: Data(body.utf8),
                      contentType: contentType,
                      extraHeaders: [:])
    }

    private func respondBinary(conn: NWConnection,
                               status: Int,
                               body: Data,
                               contentType: String,
                               extraHeaders: [String: String]) {
        var head = "HTTP/1.1 \(status) \(httpReason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var packet = Data(head.utf8)
        packet.append(body)
        conn.send(content: packet, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func respondError(conn: NWConnection, status: Int, body: String) {
        respondBinary(conn: conn,
                      status: status,
                      body: Data(body.utf8),
                      contentType: "text/plain; charset=utf-8",
                      extraHeaders: [:])
    }

    private func httpReason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 410: return "Gone"
        case 416: return "Range Not Satisfiable"
        case 502: return "Bad Gateway"
        default:  return "OK"
        }
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - HTTP request parsing

private struct HTTPRequestHead {
    let method: String
    let path: String
    let range: ClosedRange<UInt64>?

    static func parse(_ data: Data) -> HTTPRequestHead? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.split(separator: " ").map(String.init)
        guard parts.count >= 3 else { return nil }
        let method = parts[0]
        let path = parts[1]
        var rangeHeader: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key.caseInsensitiveCompare("Range") == .orderedSame {
                rangeHeader = value
            }
        }
        return HTTPRequestHead(method: method,
                               path: path,
                               range: parseRange(rangeHeader))
    }

    private static func parseRange(_ header: String?) -> ClosedRange<UInt64>? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let body = header.dropFirst("bytes=".count)
        let parts = body.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              let lower = UInt64(parts[0]),
              let upper = UInt64(parts[1]),
              upper >= lower else { return nil }
        return lower...upper
    }
}

enum ProxyServerError: Error, LocalizedError {
    case startupTimedOut
    case invalidServerURL
    case invalidWorkspaceDirectory

    var errorDescription: String? {
        switch self {
        case .startupTimedOut:  return "本地 HLS 代理启动超时"
        case .invalidServerURL: return "本地 HLS 代理 URL 构造失败"
        case .invalidWorkspaceDirectory: return "离线 workspace 目录不存在"
        }
    }
}
