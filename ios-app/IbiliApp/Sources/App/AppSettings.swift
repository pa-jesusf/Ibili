import SwiftUI

/// Toggle for displaying BV vs legacy AV id on the video detail page.
enum VideoIdDisplay: String, CaseIterable, Identifiable {
    case bv
    case av
    var id: String { rawValue }
    var label: String { self == .bv ? "BV 号" : "AV 号" }
}

/// Which numeric stat is shown next to the publish-date line on a feed
/// card. Users frequently switch between 弹幕 / 点赞 depending on what
/// they care about; "none" hides the column entirely. 收藏 was removed
/// because the home recommendation feed never carries it, so the option
/// only ever produced empty cards.
enum FeedCardStat: String, CaseIterable, Identifiable {
    case none, danmaku, like
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "不显示"
        case .danmaku: return "弹幕数"
        case .like: return "点赞数"
        }
    }
    var systemImage: String {
        switch self {
        case .none: return ""
        case .danmaku: return "text.bubble.fill"
        case .like: return "heart.fill"
        }
    }
}

/// Per-screen visibility config for video card meta. Pure value type so
/// it can be diffed cheaply by SwiftUI when passed into card views.
struct FeedCardMetaConfig: Equatable {
    var showPlay: Bool
    var showDuration: Bool
    var showPubdate: Bool
    var showAuthor: Bool
    var stat: FeedCardStat
}

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
    /// Show a transient "长按可发送弹幕" hint when danmaku is enabled.
    /// Off ⇒ user has acknowledged it and doesn't want to be reminded.
    @AppStorage("ibili.player.showDanmakuSendHint") var showDanmakuSendHint: Bool = true
    /// Danmaku opacity, 0.1 ... 1.0.
    @AppStorage("ibili.player.danmakuOpacity") var danmakuOpacity: Double = 0.85
    /// Upstream-compatible danmaku cloud-block weight, 0...11.
    @AppStorage("ibili.player.danmakuBlockLevel") var danmakuBlockLevel: Int = 0
    /// Preferred danmaku render/update frame rate.
    @AppStorage("ibili.player.danmakuFrameRate") var danmakuFrameRate: Int = 60
    /// Black outline width applied to *normal* danmaku (modes 1/4/5)
    /// for readability over busy backgrounds. Stored as a percentage
    /// of the font's point size (CoreText `kCTStrokeWidthAttributeName`
    /// is interpreted in those units), 0 disables the outline. Does
    /// not touch advanced (mode 7) bullets — those carry their own
    /// styling already and the user explicitly does not want them
    /// touched. Range 0...6, default 3.
    @AppStorage("ibili.player.danmakuStrokeWidth") var danmakuStrokeWidth: Double = 3.0
    /// Font weight for *normal* danmaku, 1...9 mapping to
    /// UIFont.Weight (1=ultraLight ... 5=medium 6=semibold 9=black).
    /// Default 6 (semibold) matches the previous hard-coded weight.
    @AppStorage("ibili.player.danmakuFontWeight") var danmakuFontWeight: Int = 6
    /// Font-size multiplier for *normal* danmaku, applied on top of
    /// the per-bullet `fontSize` field. Range 0.6...1.6, default 1.0.
    @AppStorage("ibili.player.danmakuFontScale") var danmakuFontScale: Double = 1.0
    /// Global playback gain in decibels, applied to every AVPlayer via
    /// its `volume` property (relative to the system volume slider).
    /// Range -20 ... 0 dB — only attenuation is supported because
    /// AVPlayer's volume caps at 1.0. Default -15 dB brings B 站
    /// content roughly in line with system loudness of 标准 apps
    /// (≈ 40 dB SPL at min system volume), which the user reported
    /// is otherwise ~15 dB louder than peers.
    @AppStorage("ibili.player.audioGainDb") var audioGainDb: Double = -15
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

    /// Whether the video detail page displays the canonical BV id or
    /// the legacy `av<aid>` form. Mirrors the upstream toggle.
    @AppStorage("ibili.video.idDisplay") var videoIdDisplayRaw: String = VideoIdDisplay.bv.rawValue
    var videoIdDisplay: VideoIdDisplay {
        get { VideoIdDisplay(rawValue: videoIdDisplayRaw) ?? .bv }
        set { videoIdDisplayRaw = newValue.rawValue }
    }

    // MARK: - Feed-card meta visibility (per screen)
    //
    // Home and Search keep separate flags so power users can show a
    // dense layout on search results while keeping the home grid lean,
    // or vice versa. Defaults match the freshly-redesigned
    // "投稿时间 + 弹幕数" preset.
    @AppStorage("ibili.card.home.showPlay") var homeShowPlay: Bool = true
    @AppStorage("ibili.card.home.showDuration") var homeShowDuration: Bool = true
    @AppStorage("ibili.card.home.showPubdate") var homeShowPubdate: Bool = true
    @AppStorage("ibili.card.home.showAuthor") var homeShowAuthor: Bool = true
    @AppStorage("ibili.card.home.stat") private var homeStatRaw: String = FeedCardStat.danmaku.rawValue

    @AppStorage("ibili.card.search.showPlay") var searchShowPlay: Bool = true
    @AppStorage("ibili.card.search.showDuration") var searchShowDuration: Bool = true
    @AppStorage("ibili.card.search.showPubdate") var searchShowPubdate: Bool = true
    @AppStorage("ibili.card.search.showAuthor") var searchShowAuthor: Bool = true
    @AppStorage("ibili.card.search.stat") private var searchStatRaw: String = FeedCardStat.danmaku.rawValue

    var homeCardStat: FeedCardStat {
        get { FeedCardStat(rawValue: homeStatRaw) ?? .danmaku }
        set { homeStatRaw = newValue.rawValue }
    }
    var searchCardStat: FeedCardStat {
        get { FeedCardStat(rawValue: searchStatRaw) ?? .danmaku }
        set { searchStatRaw = newValue.rawValue }
    }

    /// Disk-cache size cap for cover images, in MB. Stored as raw
    /// `Int64` bytes so `ImageDiskCache` can read the same value
    /// without going through `@AppStorage`.
    @AppStorage("ibili.cache.imageMaxBytes") var imageCacheMaxBytesRaw: Int = 256 * 1024 * 1024
    var imageCacheMaxMB: Int {
        get { max(imageCacheMaxBytesRaw / (1024 * 1024), 16) }
        set {
            let clamped = min(max(newValue, 16), 4096)
            imageCacheMaxBytesRaw = clamped * 1024 * 1024
            ImageDiskCache.shared.maxBytes = Int64(clamped) * 1024 * 1024
        }
    }

    var homeCardMeta: FeedCardMetaConfig {
        // Home recommendation feed never carries a like count and
        // rarely carries a pubdate, so we hard-disable both slots
        // regardless of the user's stored preference — keeps every
        // home card visually consistent.
        FeedCardMetaConfig(
            showPlay: homeShowPlay,
            showDuration: homeShowDuration,
            showPubdate: false,
            showAuthor: homeShowAuthor,
            stat: .none
        )
    }

    var searchCardMeta: FeedCardMetaConfig {
        FeedCardMetaConfig(
            showPlay: searchShowPlay,
            showDuration: searchShowDuration,
            showPubdate: searchShowPubdate,
            showAuthor: searchShowAuthor,
            stat: searchCardStat
        )
    }

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

    func resolvedDanmakuStrokeWidth() -> Double {
        let resolved = min(max(danmakuStrokeWidth, 0), 6)
        if danmakuStrokeWidth != resolved {
            danmakuStrokeWidth = resolved
        }
        return resolved
    }

    func resolvedDanmakuFontWeight() -> Int {
        let resolved = min(max(danmakuFontWeight, 1), 9)
        if danmakuFontWeight != resolved {
            danmakuFontWeight = resolved
        }
        return resolved
    }

    func resolvedDanmakuFontScale() -> Double {
        let resolved = min(max(danmakuFontScale, 0.6), 1.6)
        if danmakuFontScale != resolved {
            danmakuFontScale = resolved
        }
        return resolved
    }

    /// Clamps `audioGainDb` to the supported attenuation range and
    /// returns it. AVPlayer's `volume` cannot boost above unity, so
    /// we cap the maximum at 0 dB.
    func resolvedAudioGainDb() -> Double {
        let resolved = min(max(audioGainDb, -20), 0)
        if audioGainDb != resolved {
            audioGainDb = resolved
        }
        return resolved
    }

    /// Linear `AVPlayer.volume` value derived from `audioGainDb`.
    /// `1.0` means unattenuated, `0.316` is roughly -10 dB.
    func resolvedAudioVolumeLinear() -> Float {
        Float(pow(10.0, resolvedAudioGainDb() / 20.0))
    }
}
