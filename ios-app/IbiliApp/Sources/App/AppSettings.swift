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
    /// Common values: 16=360P, 32=480P, 64=720P, 80=1080P, 112=1080P+, 120=4K.
    @AppStorage("ibili.player.preferredQn") var preferredQn: Int = 0
    /// One-shot migration for older builds that hard-coded `64` (720P) as the
    /// implicit default. New default behaviour is "highest available".
    @AppStorage("ibili.player.preferredQnMigrated") private var preferredQnMigrated: Bool = false
    /// Whether to show danmaku overlay during playback.
    @AppStorage("ibili.player.danmakuEnabled") var danmakuEnabled: Bool = true
    /// Danmaku opacity, 0.1 ... 1.0.
    @AppStorage("ibili.player.danmakuOpacity") var danmakuOpacity: Double = 0.85
    /// When enabled, rotating to landscape automatically enters fullscreen,
    /// rotating back to portrait exits fullscreen. Tap of the fullscreen
    /// button always rotates regardless of this setting.
    @AppStorage("ibili.player.autoRotateFullscreen") var autoRotateFullscreen: Bool = true

    /// Resolves the effective column count given the current layout context.
    /// Phones default to 2; iPads scale with width up to 4.
    func effectiveColumns(horizontal: UserInterfaceSizeClass?, width: CGFloat) -> Int {
        if columnsRaw > 0 { return columnsRaw }
        // Auto: width buckets tuned for iPhone portrait/landscape and iPad split views.
        switch width {
        case ..<480:   return 2          // iPhone portrait
        case ..<700:   return 3          // iPhone landscape / small iPad split
        case ..<1000:  return horizontal == .compact ? 3 : 4
        default:       return 4
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
}
