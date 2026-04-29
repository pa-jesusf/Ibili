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

    private static let remuxSampleFragmentCount = 2

    struct Source {
        let videoCandidates: [URL]
        let audioCandidates: [URL]
        let videoProbe: ISOBMFF.Probe
        let audioProbe: ISOBMFF.Probe?
        let videoBandwidthHint: Int?
        let videoCodec: String
        let audioCodec: String
    }

    private let queue = DispatchQueue(label: "ibili.hls.proxy", qos: .userInitiated)
    private var listener: NWListener?
    /// All mutable state lives behind this lock. `OSAllocatedUnfairLock` is
    /// async-safe (unlike `NSLock`), which matters because the connection
    /// dispatcher is `async`.
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var port: UInt16 = 0
        var sources: [String: Source] = [:]
        var localFiles: [String: URL] = [:]
        var remuxSessions: [String: RemuxRegistration] = [:]
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
    var isHealthy: Bool { state.withLock { $0.listenerHealthy && $0.port != 0 } }

    var currentPort: UInt16 { state.withLock { $0.port } }

    func registerLocalFile(token: String, fileURL: URL) throws {
        try ensureRunning()
        state.withLock { $0.localFiles[token] = fileURL }
    }

    func updateLocalFile(token: String, fileURL: URL) {
        state.withLock { $0.localFiles[token] = fileURL }
    }

    func unregisterLocalFile(token: String) {
        state.withLock { _ = $0.localFiles.removeValue(forKey: token) }
    }

    struct RemuxRegistration {
        let session: StreamingRemuxSession
        let audioCandidates: [URL]
        let audioProbe: ISOBMFF.Probe?
    }

    func registerRemuxSession(token: String,
                              session: StreamingRemuxSession,
                              audioCandidates: [URL] = [],
                              audioProbe: ISOBMFF.Probe? = nil) throws -> URL {
        try ensureRunning()
        let reg = RemuxRegistration(session: session,
                                    audioCandidates: audioCandidates,
                                    audioProbe: audioProbe)
        let port = state.withLock { s -> UInt16 in
            s.remuxSessions[token] = reg
            return s.port
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/remux/\(token)/master.m3u8") else {
            throw ProxyServerError.invalidServerURL
        }
        return url
    }

    func unregisterRemuxSession(token: String) {
        state.withLock { _ = $0.remuxSessions.removeValue(forKey: token) }
    }

    private init() {
        // iOS will close our `NWListener` socket once the app has been
        // suspended in the background; the `.cancelled` callback often
        // arrives only AFTER the app is foregrounded again, which means
        // a naive health check still sees the listener as alive while
        // 127.0.0.1:<port> is already dead. Hooking
        // `didEnterBackgroundNotification` lets us flip the health flag
        // synchronously the moment the user locks the screen, so the
        // very first `register(...)` after resume rebinds a fresh port.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidate(reason: "didEnterBackground")
        }
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
        listener?.cancel()
        listener = nil
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
                hasSeparateAudio: source.audioProbe != nil,
                videoMediaPath: "video.m3u8",
                audioMediaPath: source.audioProbe == nil ? nil : "audio.m3u8",
                videoCodec: source.videoCodec,
                audioCodec: source.audioCodec
            )
            try write(master, to: dir.appendingPathComponent("master.m3u8"))
            try write(HLSPlaylistBuilder.makeMedia(probe: source.videoProbe, segmentPath: "v.seg"),
                      to: dir.appendingPathComponent("video.m3u8"))
            if let audioProbe = source.audioProbe {
                try write(HLSPlaylistBuilder.makeMedia(probe: audioProbe, segmentPath: "a.seg"),
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

            let shouldExportRemuxSample = UserDefaults.standard.bool(forKey: "ibili.debug.exportRemuxSample")
            if shouldExportRemuxSample {
                exported.merge(try await exportRemuxSamples(source: source, directory: dir)) { _, new in new }
                try writeRemuxPOCScript(to: dir)
                exported["ffmpeg-remux-poc.sh"] = "generated"
            }

            let metadata: [String: Any] = [
                "reason": reason,
                "token": token,
                "videoCodec": source.videoCodec,
                "audioCodec": source.audioCodec,
                "videoCandidates": source.videoCandidates.map(\.absoluteString),
                "audioCandidates": source.audioCandidates.map(\.absoluteString),
                "videoInitRange": rangeDescription(source.videoProbe.initSegment.range),
                "videoFirstFragmentRange": source.videoProbe.index.entries.first.map { rangeDescription($0.range) } ?? "-",
                "audioInitRange": source.audioProbe.map { rangeDescription($0.initSegment.range) } ?? "-",
                "audioFirstFragmentRange": source.audioProbe?.index.entries.first.map { rangeDescription($0.range) } ?? "-",
                "videoFragmentCount": source.videoProbe.index.entries.count,
                "audioFragmentCount": source.audioProbe?.index.entries.count ?? 0,
                "exportRemuxSample": shouldExportRemuxSample,
                "remuxSampleFragmentCount": Self.remuxSampleFragmentCount,
                "exported": exported,
            ]
            let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try metadataData.write(to: dir.appendingPathComponent("metadata.json"), options: [.atomic])
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let safeTimestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let shortToken = String(token.prefix(8))
        let dir = documents
            .appendingPathComponent("ibili-diagnostics", isDirectory: true)
            .appendingPathComponent("hls-\(safeTimestamp)-\(shortToken)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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

    private func exportRemuxSamples(source: Source, directory: URL) async throws -> [String: String] {
        var exported: [String: String] = [:]
        if let videoURL = source.videoCandidates.first {
            let videoOut = directory.appendingPathComponent("video-remux-sample.m4s")
            let rangeText = try await exportRemuxSample(
                url: videoURL,
                probe: source.videoProbe,
                output: videoOut
            )
            exported["video-remux-sample.m4s"] = rangeText
        }
        if let audioURL = source.audioCandidates.first, let audioProbe = source.audioProbe {
            let audioOut = directory.appendingPathComponent("audio-remux-sample.m4s")
            let rangeText = try await exportRemuxSample(
                url: audioURL,
                probe: audioProbe,
                output: audioOut
            )
            exported["audio-remux-sample.m4s"] = rangeText
        }
        return exported
    }

    private func exportRemuxSample(url: URL, probe: ISOBMFF.Probe, output: URL) async throws -> String {
        let selectedFragments = Array(probe.index.entries.prefix(Self.remuxSampleFragmentCount))
        var sample = Data()
        let initRange = probe.initSegment.range
        sample.append(try await ProxyURLLoader.shared.fetch(url: url, range: initRange).data)
        var ranges = [rangeDescription(initRange)]
        for entry in selectedFragments {
            sample.append(try await ProxyURLLoader.shared.fetch(url: url, range: entry.range).data)
            ranges.append(rangeDescription(entry.range))
        }
        try sample.write(to: output, options: [.atomic])
        return "\(sample.count) bytes; ranges=\(ranges.joined(separator: ","))"
    }

    private func writeRemuxPOCScript(to directory: URL) throws {
        let script = """
        #!/bin/sh
        set -eu
        cd "$(dirname "$0")"
        if ! command -v ffmpeg >/dev/null 2>&1; then
          echo "ffmpeg not found. Install with: brew install ffmpeg" >&2
          exit 1
        fi
        if [ ! -f video-remux-sample.m4s ]; then
          echo "video-remux-sample.m4s not found. Enable remux sample export and reproduce the failure." >&2
          exit 1
        fi
        mkdir -p remux-out
        if [ -f audio-remux-sample.m4s ]; then
          ffmpeg -hide_banner -y -i video-remux-sample.m4s -i audio-remux-sample.m4s \\
            -map 0:v:0 -map 1:a:0 -c copy -tag:v hvc1 remux-out/remux.mp4
        else
          ffmpeg -hide_banner -y -i video-remux-sample.m4s \\
            -map 0:v:0 -c copy -tag:v hvc1 remux-out/remux.mp4
        fi
        ffmpeg -hide_banner -y -i remux-out/remux.mp4 \\
          -c copy -hls_segment_type fmp4 -hls_time 5 -hls_playlist_type vod \\
          -hls_fmp4_init_filename init.mp4 \\
          -hls_segment_filename 'remux-out/seg-%03d.m4s' \\
          remux-out/remux.m3u8
        ffprobe -hide_banner -show_streams -show_format remux-out/remux.mp4 > remux-out/ffprobe-remux.txt 2>&1 || true
        echo "Generated remux-out/remux.m3u8 and remux-out/remux.mp4"
        """
        let url = directory.appendingPathComponent("ffmpeg-remux-poc.sh")
        try Data(script.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url, options: [.atomic])
    }

    private func rangeDescription(_ range: ClosedRange<UInt64>) -> String {
        "\(range.lowerBound)-\(range.upperBound)"
    }

    // MARK: - Lifecycle

    private func ensureRunning() throws {
        if let listener, state.withLock({ $0.listenerHealthy && $0.port != 0 }) {
            _ = listener
            return
        }
        // Drop any zombie listener — iOS may have cancelled it under us
        // while the app was suspended.
        if let stale = listener {
            stale.cancel()
            self.listener = nil
        }
        state.withLock { $0.port = 0; $0.listenerHealthy = false }
        let listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] netState in
            guard let self else { return }
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
            listener.cancel()
            throw ProxyServerError.startupTimedOut
        }
        self.listener = listener
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

        if parts.count == 3, parts[0] == "file" {
            let token = parts[1]
            guard let fileURL = state.withLock({ $0.localFiles[token] }) else {
                respondError(conn: conn, status: 410, body: "Token expired")
                return
            }
            await serveLocalFile(fileURL: fileURL, request: request, conn: conn)
            return
        }

        if parts.count == 3, parts[0] == "remux" {
            let token = parts[1]
            let resource = parts[2]
            guard let reg = state.withLock({ $0.remuxSessions[token] }) else {
                respondError(conn: conn, status: 410, body: "Token expired")
                return
            }
            await serveRemuxResource(reg: reg, resource: resource, request: request, conn: conn)
            return
        }

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
            serveMediaPlaylist(probe: source.videoProbe, segmentPath: "v.seg", conn: conn)
        case "audio.m3u8":
            if let probe = source.audioProbe {
                serveMediaPlaylist(probe: probe, segmentPath: "a.seg", conn: conn)
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
            hasSeparateAudio: source.audioProbe != nil,
            videoMediaPath: "video.m3u8",
            audioMediaPath: source.audioProbe == nil ? nil : "audio.m3u8",
            videoCodec: source.videoCodec,
            audioCodec: source.audioCodec
        )
        respondText(conn: conn, body: body, contentType: "application/vnd.apple.mpegurl")
    }

    private func serveMediaPlaylist(probe: ISOBMFF.Probe, segmentPath: String, conn: NWConnection) {
        let body = HLSPlaylistBuilder.makeMedia(probe: probe, segmentPath: segmentPath)
        respondText(conn: conn, body: body, contentType: "application/vnd.apple.mpegurl")
    }

    // MARK: - Streaming remux routes

    private func serveRemuxResource(reg: RemuxRegistration,
                                    resource: String,
                                    request: HTTPRequestHead,
                                    conn: NWConnection) async {
        AppLog.info("player", "remux 代理请求", metadata: [
            "resource": resource,
            "range": request.range.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "-",
        ])
        switch resource {
        case "master.m3u8":
            serveRemuxMasterPlaylist(reg: reg, conn: conn)
        case "video.m3u8":
            serveRemuxVideoPlaylist(session: reg.session, conn: conn)
        case "audio.m3u8":
            if let probe = reg.audioProbe {
                serveMediaPlaylist(probe: probe, segmentPath: "a.seg", conn: conn)
            } else {
                respondError(conn: conn, status: 404, body: "No audio track")
            }
        case "a.seg":
            if !reg.audioCandidates.isEmpty {
                await serveSegment(candidates: reg.audioCandidates,
                                   request: request, conn: conn, label: "audio")
            } else {
                respondError(conn: conn, status: 404, body: "No audio track")
            }
        case "init.mp4":
            logRemuxInitDiagnostics(fileURL: reg.session.initSegmentPath)
            await serveLocalFile(fileURL: reg.session.initSegmentPath,
                                 request: request, conn: conn)
        default:
            if resource.hasPrefix("seg-"), resource.hasSuffix(".m4s"),
               let index = Int(resource.dropFirst(4).dropLast(4)) {
                await serveLocalFile(fileURL: reg.session.segmentPath(index),
                                     request: request, conn: conn)
            } else {
                respondError(conn: conn, status: 404, body: "Not Found")
            }
        }
    }

    private func serveRemuxMasterPlaylist(reg: RemuxRegistration, conn: NWConnection) {
        let lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-STREAM-INF:BANDWIDTH=2000000",
            "video.m3u8",
        ]
        let body = lines.joined(separator: "\n") + "\n"
        AppLog.info("player", "remux master.m3u8", metadata: [
            "hasAudio": "false",
            "body": body,
        ])
        respondText(conn: conn, body: body, contentType: "application/vnd.apple.mpegurl")
    }

    private func serveRemuxVideoPlaylist(session: StreamingRemuxSession, conn: NWConnection) {
        let playlistURL = session.outputDirectory.appendingPathComponent("live.m3u8")
        guard var content = try? String(contentsOf: playlistURL, encoding: .utf8) else {
            respondError(conn: conn, status: 503, body: "Playlist not ready yet")
            return
        }
        let dirPrefix = session.outputDirectory.path
        content = content.replacingOccurrences(of: dirPrefix + "/", with: "")
        let initExists = FileManager.default.fileExists(atPath: session.initSegmentPath.path)
        let initSize = ((try? FileManager.default.attributesOfItem(atPath: session.initSegmentPath.path)[.size]) as? NSNumber)?.intValue ?? -1
        let seg0Path = session.segmentPath(0).path
        let seg0Exists = FileManager.default.fileExists(atPath: seg0Path)
        let seg0Size = ((try? FileManager.default.attributesOfItem(atPath: seg0Path)[.size]) as? NSNumber)?.intValue ?? -1
        AppLog.info("player", "remux video.m3u8", metadata: [
            "initExists": String(initExists),
            "initSize": String(initSize),
            "seg0Exists": String(seg0Exists),
            "seg0Size": String(seg0Size),
            "bodyPrefix": String(content.prefix(1500)),
        ])
        respondText(conn: conn, body: content, contentType: "application/vnd.apple.mpegurl")
    }

    private func logRemuxInitDiagnostics(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else {
            AppLog.warning("player", "remux init.mp4 诊断失败", metadata: [
                "path": fileURL.path,
                "reason": "read failed",
            ])
            return
        }
        let boxes = MP4BoxDiagnostics(data: data)
        AppLog.info("player", "remux init.mp4 诊断", metadata: [
            "path": fileURL.path,
            "size": String(data.count),
            "topBoxes": boxes.topLevelTypes.joined(separator: ","),
            "majorBrand": boxes.majorBrand ?? "-",
            "compatibleBrands": boxes.compatibleBrands.joined(separator: ","),
            "sampleEntries": boxes.sampleEntries.joined(separator: ","),
            "hasHvcC": String(boxes.contains(type: "hvcC")),
            "hvcC": boxes.hvcCDescription ?? "-",
            "hasDvcC": String(boxes.contains(type: "dvcC")),
            "hasDvvC": String(boxes.contains(type: "dvvC")),
            "allBoxTypes": boxes.allTypes.prefix(80).joined(separator: ","),
        ])
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

    // MARK: - Local file route

    private func serveLocalFile(fileURL: URL, request: HTTPRequestHead, conn: NWConnection) async {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attrs[.size] as? NSNumber)?.uint64Value,
              fileSize > 0 else {
            respondError(conn: conn, status: 404, body: "File not found")
            return
        }

        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            respondError(conn: conn, status: 500, body: "Cannot open file")
            return
        }
        defer { try? handle.close() }

        let totalSize = fileSize

        if let range = request.range {
            let start = range.lowerBound
            let end = min(range.upperBound, totalSize - 1)
            guard start <= end, start < totalSize else {
                respondError(conn: conn, status: 416, body: "Range Not Satisfiable")
                return
            }
            let length = end - start + 1
            handle.seek(toFileOffset: start)
            let data = handle.readData(ofLength: Int(length))

            var head = "HTTP/1.1 206 Partial Content\r\n"
            head += "Content-Type: video/mp4\r\n"
            head += "Content-Length: \(data.count)\r\n"
            head += "Content-Range: bytes \(start)-\(end)/\(totalSize)\r\n"
            head += "Accept-Ranges: bytes\r\n"
            head += "Connection: close\r\n"
            head += "\r\n"
            var packet = Data(head.utf8)
            packet.append(data)
            conn.send(content: packet, completion: .contentProcessed { _ in conn.cancel() })
        } else {
            let data = handle.readDataToEndOfFile()
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: video/mp4\r\n"
            head += "Content-Length: \(data.count)\r\n"
            head += "Accept-Ranges: bytes\r\n"
            head += "Connection: close\r\n"
            head += "\r\n"
            var packet = Data(head.utf8)
            packet.append(data)
            conn.send(content: packet, completion: .contentProcessed { _ in conn.cancel() })
        }
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

// MARK: - HTTP request parsing

private struct MP4BoxDiagnostics {
    let topLevelTypes: [String]
    let allTypes: [String]
    let sampleEntries: [String]
    let majorBrand: String?
    let compatibleBrands: [String]
    let hvcCDescription: String?

    init(data: Data) {
        var topLevelTypes: [String] = []
        var allTypes: [String] = []
        var sampleEntries: [String] = []
        var majorBrand: String?
        var compatibleBrands: [String] = []
        var hvcCDescription: String?

        func fourCC(at offset: Int) -> String? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let bytes = data[offset..<(offset + 4)]
            guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else { return nil }
            return String(bytes: bytes, encoding: .ascii)
        }

        func uint32(at offset: Int) -> UInt64? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return data[offset..<(offset + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }

        func uint64(at offset: Int) -> UInt64? {
            guard offset >= 0, offset + 8 <= data.count else { return nil }
            return data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }

        func boxHeader(at offset: Int, end: Int) -> (type: String, payloadStart: Int, boxEnd: Int)? {
            guard offset + 8 <= end,
                  let rawSize = uint32(at: offset),
                  let type = fourCC(at: offset + 4) else { return nil }
            var headerSize = 8
            var boxSize = rawSize
            if rawSize == 1 {
                guard let largesize = uint64(at: offset + 8) else { return nil }
                headerSize = 16
                boxSize = largesize
            } else if rawSize == 0 {
                boxSize = UInt64(end - offset)
            }
            guard boxSize >= UInt64(headerSize) else { return nil }
            let boxEnd64 = UInt64(offset) + boxSize
            guard boxEnd64 <= UInt64(end) else { return nil }
            return (type, offset + headerSize, Int(boxEnd64))
        }

        func describeHvcC(start: Int, end: Int) -> String? {
            guard start + 13 <= end else { return nil }
            let configurationVersion = data[start]
            let profileByte = data[start + 1]
            let generalProfileSpace = (profileByte >> 6) & 0x03
            let generalTierFlag = (profileByte >> 5) & 0x01
            let generalProfileIDC = profileByte & 0x1f
            let compatibility = uint32(at: start + 2) ?? 0
            let generalLevelIDC = data[start + 12]
            return "version=\(configurationVersion),profileSpace=\(generalProfileSpace),tier=\(generalTierFlag),profileIDC=\(generalProfileIDC),compat=0x\(String(compatibility, radix: 16)),levelIDC=\(generalLevelIDC)"
        }

        func parseBoxes(start: Int, end: Int, depth: Int) {
            var offset = start
            while offset + 8 <= end {
                guard let header = boxHeader(at: offset, end: end) else { break }
                if depth == 0 { topLevelTypes.append(header.type) }
                allTypes.append(header.type)

                if header.type == "ftyp" {
                    majorBrand = fourCC(at: header.payloadStart)
                    var brandOffset = header.payloadStart + 8
                    while brandOffset + 4 <= header.boxEnd {
                        if let brand = fourCC(at: brandOffset) {
                            compatibleBrands.append(brand)
                        }
                        brandOffset += 4
                    }
                } else if header.type == "hvcC" {
                    hvcCDescription = describeHvcC(start: header.payloadStart, end: header.boxEnd)
                }

                if header.type == "stsd" {
                    var entryOffset = header.payloadStart + 8
                    while entryOffset + 8 <= header.boxEnd {
                        guard let entry = boxHeader(at: entryOffset, end: header.boxEnd) else { break }
                        sampleEntries.append(entry.type)
                        allTypes.append(entry.type)
                        let childStart = visualSampleEntryChildStart(payloadStart: entry.payloadStart, boxEnd: entry.boxEnd)
                        parseBoxes(start: childStart, end: entry.boxEnd, depth: depth + 1)
                        entryOffset = entry.boxEnd
                    }
                } else if ["moov", "trak", "edts", "mdia", "minf", "dinf", "stbl", "mvex", "moof", "traf"].contains(header.type) {
                    parseBoxes(start: header.payloadStart, end: header.boxEnd, depth: depth + 1)
                }

                offset = header.boxEnd
            }
        }

        func visualSampleEntryChildStart(payloadStart: Int, boxEnd: Int) -> Int {
            let visualSampleEntryHeaderLength = 78
            let start = payloadStart + visualSampleEntryHeaderLength
            return start <= boxEnd ? start : boxEnd
        }

        parseBoxes(start: 0, end: data.count, depth: 0)

        self.topLevelTypes = topLevelTypes
        self.allTypes = allTypes
        self.sampleEntries = sampleEntries
        self.majorBrand = majorBrand
        self.compatibleBrands = compatibleBrands
        self.hvcCDescription = hvcCDescription
    }

    func contains(type: String) -> Bool {
        allTypes.contains(type) || sampleEntries.contains(type)
    }
}

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

    var errorDescription: String? {
        switch self {
        case .startupTimedOut:  return "本地 HLS 代理启动超时"
        case .invalidServerURL: return "本地 HLS 代理 URL 构造失败"
        }
    }
}
