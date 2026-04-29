import SwiftUI

/// User-tunable display preferences. Persisted via `@AppStorage`.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// `0` means "auto" — pick by size class. Otherwise an explicit column count.
    @AppStorage("ibili.feed.columns") var columnsRaw: Int = 0
    /// `0` means "auto" — quality derived from cell pixel size. Otherwise a
    /// Bilibili `@<q>q.webp` quality value (e.g. 60, 75, 90, 100).
    @AppStorage("ibili.feed.imageQuality") var imageQualityRaw: Int = 0
    /// Preferred initial video quality (Bilibili `qn` code).
    /// `0` means "use the highest quality available for this video".
    /// Common values: 16=360P, 32=480P, 64=720P, 80=1080P, 112=1080P+, 120=4K,
    /// 116=1080P60, 125=HDR, 126=杜比, 127=8K.
    @AppStorage("ibili.player.preferredQn") var preferredQn: Int = 0
    /// Preferred audio quality (Bilibili audio stream id).
    /// 30251=Hi-Res, 30250=杜比全景声, 30280=192K, 30232=132K, 30216=64K.
    @AppStorage("ibili.player.preferredAudioQn") var preferredAudioQn: Int = 30251
    /// One-shot migration for older builds that hard-coded `64` (720P) as the
    /// implicit default. New default behaviour is "highest available".
    @AppStorage("ibili.player.preferredQnMigrated") private var preferredQnMigrated: Bool = false
    /// Whether to show danmaku overlay during playback.
    @AppStorage("ibili.player.danmakuEnabled") var danmakuEnabled: Bool = true
    /// Danmaku opacity, 0.1 ... 1.0.
    @AppStorage("ibili.player.danmakuOpacity") var danmakuOpacity: Double = 0.85
    /// Upstream-compatible danmaku cloud-block weight, 0...11.
    @AppStorage("ibili.player.danmakuBlockLevel") var danmakuBlockLevel: Int = 0
    /// Preferred danmaku render/update frame rate.
    @AppStorage("ibili.player.danmakuFrameRate") var danmakuFrameRate: Int = 60
    /// When enabled, rotating to landscape automatically enters fullscreen,
    /// rotating back to portrait exits fullscreen. Tap of the fullscreen
    /// button always rotates regardless of this setting.
    @AppStorage("ibili.player.autoRotateFullscreen") var autoRotateFullscreen: Bool = true
    /// Race the lowest available quality against the user's preferred
    /// quality on player startup. Whichever AVPlayerItem reaches
    /// `.readyToPlay` first is shown immediately; if the lowest variant
    /// won, the player seamlessly upgrades to the preferred quality
    /// once it finishes preparing.
    @AppStorage("ibili.player.fastLoad") var fastLoad: Bool = false
    /// Developer-only diagnostic option. When enabled, a playback
    /// failure exports a short upstream m4s sample plus an ffmpeg remux
    /// script for AVPlayer compatibility testing.
    @AppStorage("ibili.debug.exportRemuxSample") var exportRemuxSample: Bool = false

    private let maxFeedColumns = 3
    private let supportedDanmakuFrameRates = [30, 60]

    /// Resolves the effective column count given the current layout context.
    /// iOS defaults to 2 columns on phones and opens at most 3 columns.
    func effectiveColumns(horizontal: UserInterfaceSizeClass?, width: CGFloat) -> Int {
        let clampedStoredColumns = min(max(columnsRaw, 0), maxFeedColumns)
        if clampedStoredColumns != columnsRaw {
            columnsRaw = clampedStoredColumns
        }
        if clampedStoredColumns > 0 { return clampedStoredColumns }
        // Auto: width buckets tuned for iPhone portrait/landscape and iPad split views.
        switch width {
        case ..<480:   return 2          // iPhone portrait
        case ..<700:   return 3          // iPhone landscape / small iPad split
        case ..<1000:  return 3
        default:       return horizontal == .compact ? 2 : 3
        }
    }

    /// Returns the Bilibili `@<q>q` quality to request, or `nil` for "size-only,
    /// no explicit quality" so the CDN picks based on the resize box.
    func resolvedImageQuality() -> Int? {
        imageQualityRaw <= 0 ? nil : imageQualityRaw
    }

    /// Returns the preferred startup quality after applying the one-shot
    /// migration from the previous hard-coded 720P default.
    func resolvedPreferredVideoQn() -> Int {
        if !preferredQnMigrated && preferredQn == 64 {
            preferredQn = 0
            preferredQnMigrated = true
        } else if !preferredQnMigrated {
            preferredQnMigrated = true
        }
        return preferredQn
    }

    func resolvedDanmakuBlockLevel() -> Int {
        let resolved = min(max(danmakuBlockLevel, 0), 11)
        if danmakuBlockLevel != resolved {
            danmakuBlockLevel = resolved
        }
        return resolved
    }

    func resolvedDanmakuFrameRate() -> Int {
        let resolved = supportedDanmakuFrameRates.contains(danmakuFrameRate) ? danmakuFrameRate : 60
        if danmakuFrameRate != resolved {
            danmakuFrameRate = resolved
        }
        return resolved
    }
}
