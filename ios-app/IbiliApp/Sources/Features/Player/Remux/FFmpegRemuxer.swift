import Foundation

#if canImport(FFmpegRemux)
import FFmpegRemux
#endif

enum FFmpegRemuxerError: Error, LocalizedError {
    case frameworkUnavailable
    case remuxFailed(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            return "FFmpegRemux.xcframework 尚未集成，请先运行 ios-app/ThirdParty/ffmpeg/build-ffmpeg-ios.sh"
        case .remuxFailed(let code, let message):
            return "FFmpeg remux 失败（\(code)）：\(message)"
        }
    }
}

final class FFmpegRemuxer {
    static let shared = FFmpegRemuxer()

    private init() {}

    var isAvailable: Bool {
        #if canImport(FFmpegRemux)
        true
        #else
        false
        #endif
    }

    func remuxToMP4(video: URL, audio: URL?, output: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }

            #if canImport(FFmpegRemux)
            let maxErrorBytes = 4096
            let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: maxErrorBytes)
            defer { errorBuffer.deallocate() }
            errorBuffer.initialize(repeating: 0, count: maxErrorBytes)

            let code = video.path.withCString { videoPath in
                output.path.withCString { outputPath in
                    if let audio {
                        return audio.path.withCString { audioPath in
                            ibili_remux_mp4(videoPath, audioPath, outputPath, errorBuffer, Int32(maxErrorBytes))
                        }
                    } else {
                        return ibili_remux_mp4(videoPath, nil, outputPath, errorBuffer, Int32(maxErrorBytes))
                    }
                }
            }
            guard code >= 0 else {
                let message = String(cString: errorBuffer)
                throw FFmpegRemuxerError.remuxFailed(code: code, message: message.isEmpty ? "unknown" : message)
            }
            return output
            #else
            throw FFmpegRemuxerError.frameworkUnavailable
            #endif
        }.value
    }
}
