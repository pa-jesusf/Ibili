import Foundation

#if canImport(FFmpegRemux)
import FFmpegRemux
#endif

/// Manages a long-lived FFmpeg HLS remux pipeline for **video only**.
///
/// Audio does not need remux and is handled separately by the HLS proxy's
/// native byte-range pass-through.
///
/// Pipeline:
/// 1. Creates a named pipe for video input.
/// 2. A background feeder downloads CDN video fragments and writes them
///    into the pipe sequentially.
/// 3. `ibili_remux_hls_live` (on a detached thread) reads the pipe with
///    minimal probesize and outputs `init.mp4` + `seg-N.m4s` files.
/// 4. The proxy serves these segments as standard HLS fMP4 to AVPlayer.
final class StreamingRemuxSession: @unchecked Sendable {

    let outputDirectory: URL
    let initFilename = "init.mp4"

    private let videoCandidates: [URL]
    private let videoProbe: ISOBMFF.Probe
    private let videoPipePath: String
    private let hlsTime: Int

    private var feederTask: Task<Void, Never>?
    private var ffmpegTask: Task<Void, Never>?
    private let lock = NSLock()
    private var _isFinished = false

    var isFinished: Bool { lock.withLock { _isFinished } }
    var totalFragments: Int { videoProbe.index.entries.count }

    init(videoCandidates: [URL],
         videoProbe: ISOBMFF.Probe,
         outputDirectory: URL,
         hlsTime: Int = 6) {
        self.videoCandidates = videoCandidates
        self.videoProbe = videoProbe
        self.outputDirectory = outputDirectory
        self.hlsTime = hlsTime
        self.videoPipePath = outputDirectory
            .appendingPathComponent("video.pipe").path
    }

    func start() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        if fm.fileExists(atPath: videoPipePath) {
            try fm.removeItem(atPath: videoPipePath)
        }
        guard mkfifo(videoPipePath, 0o600) == 0 else {
            throw StreamingRemuxError.mkfifoFailed(path: videoPipePath, errno: errno)
        }

        let playlistPath = outputDirectory.appendingPathComponent("live.m3u8").path
        let segPattern = outputDirectory.appendingPathComponent("seg-%d.m4s").path

        ffmpegTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            self.runFFmpeg(playlistPath: playlistPath, segPattern: segPattern)
        }

        feederTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runFeeder()
        }
    }

    func cancel() {
        feederTask?.cancel()
        ffmpegTask?.cancel()
        feederTask = nil
        ffmpegTask = nil
        let fd = open(videoPipePath, O_WRONLY | O_NONBLOCK)
        if fd >= 0 { close(fd) }
    }

    func segmentPath(_ index: Int) -> URL {
        outputDirectory.appendingPathComponent("seg-\(index).m4s")
    }

    var initSegmentPath: URL {
        outputDirectory.appendingPathComponent(initFilename)
    }

    // MARK: - FFmpeg thread (video only, no audio)

    private func runFFmpeg(playlistPath: String, segPattern: String) {
        #if canImport(FFmpegRemux)
        let maxErr = 4096
        let errBuf = UnsafeMutablePointer<CChar>.allocate(capacity: maxErr)
        defer { errBuf.deallocate() }
        errBuf.initialize(repeating: 0, count: maxErr)

        let code = videoPipePath.withCString { vPath in
            playlistPath.withCString { plPath in
                initFilename.withCString { initFn in
                    segPattern.withCString { segFn in
                        ibili_remux_hls_live(vPath, nil, plPath, initFn, segFn,
                                             Int32(hlsTime), errBuf, Int32(maxErr))
                    }
                }
            }
        }

        lock.withLock { _isFinished = true }

        if code < 0 {
            let msg = String(cString: errBuf)
            AppLog.error("player", "streaming remux FFmpeg 退出", metadata: [
                "code": String(code), "error": msg,
            ])
        } else {
            AppLog.info("player", "streaming remux FFmpeg 正常退出")
        }
        #else
        AppLog.error("player", "streaming remux: FFmpegRemux framework 不可用")
        lock.withLock { _isFinished = true }
        #endif
    }

    // MARK: - Feeder (CDN video fragments → pipe)

    private func runFeeder() async {
        guard let videoURL = videoCandidates.first else {
            AppLog.error("player", "streaming remux feeder: 无 video 候选")
            closePipe()
            return
        }

        AppLog.info("player", "streaming remux feeder 启动", metadata: [
            "videoFragments": String(videoProbe.index.entries.count),
        ])

        let fd = open(videoPipePath, O_WRONLY)
        guard fd >= 0 else {
            AppLog.error("player", "streaming remux feeder: 打开 pipe 失败",
                         metadata: ["errno": String(errno)])
            return
        }
        defer { close(fd) }

        do {
            let initData = try await ProxyURLLoader.shared.fetch(
                url: videoURL, range: videoProbe.initSegment.range
            ).data
            writeAll(fd: fd, data: initData)

            for (i, entry) in videoProbe.index.entries.enumerated() {
                try Task.checkCancellation()
                let data = try await ProxyURLLoader.shared.fetch(
                    url: videoURL, range: entry.range
                ).data
                writeAll(fd: fd, data: data)

                if i == 0 || (i + 1) % 20 == 0
                    || i == videoProbe.index.entries.count - 1 {
                    AppLog.info("player", "streaming remux feeder 进度", metadata: [
                        "fragment": "\(i + 1)/\(videoProbe.index.entries.count)",
                    ])
                }
            }
            AppLog.info("player", "streaming remux feeder 完成")
        } catch is CancellationError {
            AppLog.info("player", "streaming remux feeder 已取消")
        } catch {
            AppLog.error("player", "streaming remux feeder 错误", error: error)
        }
    }

    private func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base + offset, buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private func closePipe() {
        let fd = open(videoPipePath, O_WRONLY | O_NONBLOCK)
        if fd >= 0 { close(fd) }
    }
}

enum StreamingRemuxError: Error, LocalizedError {
    case mkfifoFailed(path: String, errno: Int32)
    case ffmpegNotAvailable
    case timeout

    var errorDescription: String? {
        switch self {
        case .mkfifoFailed(let path, let errno):
            return "mkfifo 失败: \(path) (errno=\(errno))"
        case .ffmpegNotAvailable:
            return "FFmpegRemux.xcframework 未集成"
        case .timeout:
            return "等待 FFmpeg 输出超时"
        }
    }
}
