#if canImport(FFmpegRemux)
import FFmpegRemux
#endif

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
}
