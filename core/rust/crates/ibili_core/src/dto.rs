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
    pub format: String,
    pub quality: i64,
    pub duration_ms: i64,
    pub backup_urls: Vec<String>,
    /// Bilibili `accept_quality` numeric codes, in descending order
    /// (e.g. `[112, 80, 64, 32, 16]`).
    pub accept_quality: Vec<i64>,
    /// Human-readable labels matching `accept_quality` 1:1
    /// (e.g. `["高清 1080P+", "高清 1080P", ...]`).
    pub accept_description: Vec<String>,
}

#[derive(Debug, Serialize, Clone)]
pub struct DanmakuItem {
    /// Time in seconds when the comment should appear.
    pub time_sec: f32,
    /// Mode: 1/2/3 = scrolling, 4 = bottom-anchored, 5 = top-anchored.
    pub mode: i32,
    /// 0xRRGGBB.
    pub color: u32,
    /// Pixel font size as authored.
    pub font_size: i32,
    pub text: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct DanmakuTrack {
    pub items: Vec<DanmakuItem>,
}
