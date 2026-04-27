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
}
