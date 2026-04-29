use serde::{Deserialize, Serialize};

/// Bilibili envelope: `{ "code": 0, "message": "0", "data": ... }`.
#[derive(Debug, Deserialize)]
#[serde(bound(deserialize = "T: Deserialize<'de>"))]
pub struct ApiEnvelope<T> {
    pub code: i64,
    #[serde(default)]
    pub message: String,
    pub data: Option<T>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TvQrStart {
    pub auth_code: String,
    pub url: String,
}

#[derive(Debug, Serialize, Clone)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum TvQrPoll {
    Pending,
    Scanned,
    Expired,
    Confirmed { session: super::session::PersistedSession },
}

#[derive(Debug, Serialize, Clone)]
pub struct FeedItem {
    pub aid: i64,
    pub bvid: String,
    pub cid: i64,
    pub title: String,
    pub cover: String,
    pub author: String,
    pub duration_sec: i64,
    pub play: i64,
    pub danmaku: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct FeedPage {
    pub items: Vec<FeedItem>,
}

#[derive(Debug, Serialize, Clone)]
pub struct PlayUrl {
    pub url: String,
    pub audio_url: Option<String>,
    pub format: String,
    pub stream_type: String,
    pub quality: i64,
    pub duration_ms: i64,
    pub backup_urls: Vec<String>,
    pub audio_backup_urls: Vec<String>,
    /// Bilibili `accept_quality` numeric codes, in descending order
    /// (e.g. `[112, 80, 64, 32, 16]`).
    pub accept_quality: Vec<i64>,
    /// Human-readable labels matching `accept_quality` 1:1
    /// (e.g. `["高清 1080P+", "高清 1080P", ...]`).
    pub accept_description: Vec<String>,
    /// RFC6381 codec string for the picked video stream
    /// (e.g. `"avc1.640032"`, `"hvc1.2.4.L150.B0"`). Empty string
    /// when the upstream response did not provide one (legacy `durl`
    /// MP4 path). The iOS layer forwards this into the local HLS
    /// master playlist's `CODECS` attribute so AVPlayer can route to
    /// the correct decoder pipeline (Main10/HDR HEVC etc.) before
    /// fetching segments — without it some HDR variants fail with
    /// `CoreMediaErrorDomain -12927`.
    #[serde(default)]
    pub video_codec: String,
    /// RFC6381 codec string for the picked audio stream (e.g.
    /// `"mp4a.40.2"`, `"ec-3"`). Empty when there is no separate
    /// audio track or the upstream omitted it.
    #[serde(default)]
    pub audio_codec: String,
    /// Diagnostic message for non-fatal degradations (e.g. wbi/playurl
    /// failed and we silently fell back to tv_durl). Surfaced by the iOS
    /// layer into the in-app log viewer so the cause is visible.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub debug_message: Option<String>,
    /// Audio quality id of the picked audio stream (e.g. 30280=192K,
    /// 30251=Hi-Res, 30250=Dolby Atmos). 0 when no separate audio.
    #[serde(default)]
    pub audio_quality: i64,
    /// Human-readable label for the picked audio quality.
    #[serde(default)]
    pub audio_quality_label: String,
    /// Available audio quality ids, in descending quality order.
    #[serde(default)]
    pub accept_audio_quality: Vec<i64>,
    /// Human-readable labels for `accept_audio_quality`, 1:1.
    #[serde(default)]
    pub accept_audio_description: Vec<String>,
}

#[derive(Debug, Serialize, Clone)]
pub struct DanmakuItem {
    /// Time in seconds when the comment should appear.
    pub time_sec: f32,
    /// Mode: 1/2/3 = scrolling, 4 = bottom-anchored, 5 = top-anchored,
    /// 7 = special/advanced danmaku.
    pub mode: i32,
    /// 0xRRGGBB.
    pub color: u32,
    /// Pixel font size as authored.
    pub font_size: i32,
    pub text: String,
    /// Upstream cloud-block weight, 0...11.
    pub weight: i32,
    /// Whether `weight` came from the segmented protobuf source.
    pub has_weight: bool,
    /// Sender identity hash used by upstream to detect self-sent danmaku.
    pub mid_hash: String,
    /// Upstream like count for this danmaku.
    pub like_count: i64,
    /// Upstream colorful enum value, e.g. VIP gradual color.
    pub colorful: i32,
    /// Duplicate count after upstream/client-side coalescing.
    pub count: i32,
    /// Best-effort self flag derived from the active session and upstream data.
    pub is_self: bool,
}

#[derive(Debug, Serialize, Clone)]
pub struct DanmakuTrack {
    pub items: Vec<DanmakuItem>,
}

/// One video result row from `/x/web-interface/wbi/search/type?search_type=video`.
///
/// Field set is intentionally a superset of [`FeedItem`] so the iOS layer
/// can render search hits with the same card UI; the search-only metadata
/// (`like`, `pubdate`) sits at the end.
#[derive(Debug, Serialize, Clone)]
pub struct SearchVideoItem {
    pub aid: i64,
    pub bvid: String,
    pub cid: i64,
    pub title: String,
    pub cover: String,
    pub author: String,
    pub duration_sec: i64,
    pub play: i64,
    pub danmaku: i64,
    pub like: i64,
    /// Unix seconds. `0` means upstream did not provide a publish date.
    pub pubdate: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct SearchVideoPage {
    pub items: Vec<SearchVideoItem>,
    pub num_results: i64,
    pub num_pages: i64,
}
