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
    /// Unix seconds. `0` when upstream did not provide a publish date
    /// for this card (the recommendation feed often omits it).
    pub pubdate: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct FeedPage {
    pub items: Vec<FeedItem>,
}

#[derive(Debug, Serialize, Clone)]
pub struct LiveFeedItem {
    pub room_id: i64,
    pub uid: i64,
    pub title: String,
    pub cover: String,
    pub system_cover: String,
    pub uname: String,
    pub face: String,
    pub area_name: String,
    pub watched_label: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct LiveFeedPage {
    pub items: Vec<LiveFeedItem>,
    pub has_more: bool,
}

#[derive(Debug, Serialize, Clone)]
pub struct LiveQuality {
    pub qn: i64,
    pub label: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct LiveRoomInfo {
    pub room_id: i64,
    pub uid: i64,
    pub title: String,
    pub cover: String,
    pub anchor_name: String,
    pub anchor_face: String,
    pub watched_label: String,
    pub live_status: i64,
    pub live_time: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct LivePlayUrl {
    pub url: String,
    pub quality: i64,
    pub accept_quality: Vec<LiveQuality>,
    pub live_status: i64,
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
    /// Upstream-advertised width of the picked video stream.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_width: Option<i64>,
    /// Upstream-advertised height of the picked video stream.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_height: Option<i64>,
    /// HLS-ready decimal frame rate string for the picked video stream.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_frame_rate: Option<String>,
    /// Best-effort dynamic range hint for the picked video stream.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_range: Option<String>,
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
    /// Server-recorded resume position for the *current cid*, in
    /// milliseconds. 0 when the account has no history for this cid
    /// or the response did not carry it (anonymous playback). The
    /// player layer seeks to this on first ready when non-zero.
    #[serde(default)]
    pub last_play_time_ms: i64,
    /// Server's "best resume target" cid for the same aid — set when
    /// the user previously stopped on a different page. We don't yet
    /// auto-switch pages on this signal but expose it so the iOS
    /// layer can offer a "继续观看 P3" prompt.
    #[serde(default)]
    pub last_play_cid: i64,
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

#[derive(Debug, Serialize, Clone)]
pub struct SearchLiveItem {
    pub room_id: i64,
    pub uid: i64,
    pub title: String,
    pub cover: String,
    pub uname: String,
    pub face: String,
    pub online: i64,
    pub area_name: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct SearchLivePage {
    pub items: Vec<SearchLiveItem>,
    pub num_results: i64,
    pub num_pages: i64,
}

// ---------- Video detail (view/full) ----------

/// Full video detail surface, mirrored from
/// `/x/web-interface/wbi/view`. We keep only fields the iOS detail
/// page consumes — pages list, ugc season, owner, stat, tags, descV2.
#[derive(Debug, Serialize, Clone)]
pub struct VideoView {
    pub aid: i64,
    pub bvid: String,
    pub cid: i64,
    pub title: String,
    pub cover: String,
    pub desc: String,
    pub desc_v2: Vec<VideoDescNode>,
    pub duration_sec: i64,
    pub pubdate: i64,
    pub ctime: i64,
    pub videos: i32,
    pub stat: VideoStat,
    pub owner: VideoOwner,
    pub pages: Vec<VideoPage>,
    pub tags: Vec<String>,
    pub honor: Vec<VideoHonor>,
    pub ugc_season: Option<UgcSeason>,
    pub redirect_url: String,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct VideoStat {
    pub view: i64,
    pub danmaku: i64,
    pub reply: i64,
    pub favorite: i64,
    pub coin: i64,
    pub share: i64,
    pub like: i64,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct VideoOwner {
    pub mid: i64,
    pub name: String,
    pub face: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct VideoPage {
    pub cid: i64,
    pub page: i32,
    pub part: String,
    pub duration_sec: i64,
    pub first_frame: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct VideoDescNode {
    /// 1=text, 2=at-user.
    pub kind: i32,
    pub raw_text: String,
    pub biz_id: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct VideoHonor {
    pub kind: i32,
    pub desc: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct UgcSeason {
    pub id: i64,
    pub title: String,
    pub cover: String,
    pub mid: i64,
    pub intro: String,
    pub ep_count: i32,
    pub sections: Vec<UgcSeasonSection>,
}

#[derive(Debug, Serialize, Clone)]
pub struct UgcSeasonSection {
    pub id: i64,
    pub title: String,
    pub episodes: Vec<UgcSeasonEpisode>,
}

#[derive(Debug, Serialize, Clone)]
pub struct UgcSeasonEpisode {
    pub id: i64,
    pub aid: i64,
    pub bvid: String,
    pub cid: i64,
    pub title: String,
    pub cover: String,
    pub duration_sec: i64,
}

// ---------- Related videos ----------

#[derive(Debug, Serialize, Clone)]
pub struct RelatedVideoItem {
    pub aid: i64,
    pub bvid: String,
    pub cid: i64,
    pub title: String,
    pub cover: String,
    pub author: String,
    pub face: String,
    pub mid: i64,
    pub duration_sec: i64,
    pub play: i64,
    pub danmaku: i64,
    pub pubdate: i64,
}

// ---------- Replies (comments) ----------

#[derive(Debug, Serialize, Clone)]
pub struct ReplyPage {
    pub items: Vec<ReplyItem>,
    pub top: Option<ReplyItem>,
    pub upper_mid: i64,
    pub cursor_next: String,
    pub is_end: bool,
    pub total: i64,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct ReplyEmote {
    /// e.g. `"[doge]"`. Includes the brackets.
    pub name: String,
    /// CDN URL of the emote PNG/animated WebP.
    pub url: String,
    /// 1 = small (inline 18pt), 2 = large (inline 32pt).
    pub size: i32,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct ReplyJumpUrl {
    /// The literal substring inside the message (e.g. `"BV1xx411y7yu"` or `"av12345"`).
    pub keyword: String,
    /// Display title returned by the server (e.g. video title). May be empty.
    pub title: String,
    /// Best-effort canonical URL (`https://www.bilibili.com/video/BVxxx`).
    pub url: String,
    /// Optional small icon CDN URL displayed before the keyword.
    pub prefix_icon: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct ReplyItem {
    pub rpid: i64,
    pub oid: i64,
    pub root: i64,
    pub parent: i64,
    pub mid: i64,
    pub uname: String,
    pub face: String,
    pub level: i32,
    pub vip_status: i32,
    pub message: String,
    pub ctime: i64,
    pub like: i64,
    pub action: i32,
    pub reply_count: i32,
    pub up_action_like: bool,
    pub up_action_reply: bool,
    pub location: String,
    /// First few preview replies (upstream `replies` array) when this
    /// is a top-level comment.
    pub preview_replies: Vec<ReplyItem>,
    /// Emotes keyed by their bracketed name. The iOS layer scans `message`
    /// for these tokens and inlines the matching image at runtime.
    pub emotes: Vec<ReplyEmote>,
    /// Inline picture attachments — fully-qualified CDN URLs in original
    /// upstream order. Rendered as a 2/3-column grid below the message.
    pub pictures: Vec<String>,
    /// `keyword → metadata` map of inline jump links (e.g. when the user
    /// types a BV id, the server detects it server-side and ships this so
    /// we can render it as a tappable chip routing into the player).
    pub jump_urls: Vec<ReplyJumpUrl>,
}

// ---------- Write-action results ----------

#[derive(Debug, Serialize, Clone, Default)]
pub struct LikeResult {
    /// Effective like state after the call: 0=not liked, 1=liked.
    pub liked: i32,
    pub toast: String,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct CoinResult {
    pub like: bool,
    pub toast: String,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct TripleResult {
    pub like: bool,
    pub coin: bool,
    pub fav: bool,
    pub multiply: i32,
    pub prompt: bool,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct FavoriteResult {
    pub prompt: bool,
    pub toast: String,
}

// ---------- Read-only relation queries ----------

/// Server-side relation state for a UGC video — used to seed the
/// detail page's like/coin/favorite/follow buttons so users don't
/// re-fire mutations that the server would 412 anyway.
///
/// Backed by `/x/web-interface/archive/relation`.
#[derive(Debug, Serialize, Clone, Default)]
pub struct ArchiveRelation {
    pub liked: bool,
    pub disliked: bool,
    pub favorited: bool,
    /// Whether the current account follows the uploader.
    pub attention: bool,
    /// Number of coins this account already threw at the video (0/1/2).
    pub coin_number: i32,
}

/// One favourite folder owned by the current user.
/// Backed by `/x/v3/fav/folder/created/list-all?type=2&rid=<aid>&up_mid=<mid>`.
/// When `rid` is supplied, `fav_state == 1` indicates the video is
/// already in this folder.
#[derive(Debug, Serialize, Clone, Default)]
pub struct FavFolderInfo {
    pub id: i64,
    pub fid: i64,
    pub mid: i64,
    pub attr: i32,
    pub title: String,
    pub fav_state: i32,
    pub media_count: i32,
}

/// Image attached to a comment. Wire format is what `/x/v2/reply/add`
/// expects in its `pictures` JSON-encoded array param.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct ReplyPicture {
    pub img_src: String,
    pub img_width: i32,
    pub img_height: i32,
    pub img_size: f64,
}

/// Result of submitting a comment.
#[derive(Debug, Serialize, Clone, Default)]
pub struct ReplyAddResult {
    pub rpid: i64,
    pub toast: String,
}

/// Image returned by the bfs upload endpoint.
#[derive(Debug, Serialize, Clone, Default)]
pub struct UploadedImage {
    pub url: String,
    pub width: i32,
    pub height: i32,
    pub size: f64,
}

/// One emote in a panel package.
#[derive(Debug, Serialize, Clone, Default)]
pub struct Emote {
    pub text: String,
    pub url: String,
}

/// One emote package — these populate tabs in the comment composer.
#[derive(Debug, Serialize, Clone, Default)]
pub struct EmotePackage {
    pub id: i64,
    pub text: String,
    pub url: String,
    pub kind: i32,
    pub emotes: Vec<Emote>,
}
