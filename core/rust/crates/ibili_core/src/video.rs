use crate::Core;
use crate::dto::PlayUrl;
use crate::error::{CoreError, CoreResult};
use serde::Deserialize;

/// Mirrors `Api.tvPlayUrl = '/x/tv/playurl'` (resolved against api.bilibili.com).
const URL_PLAYURL: &str = "https://api.bilibili.com/x/tv/playurl";

#[derive(Deserialize)]
struct PlayUrlRoot {
    #[serde(default)] quality: i64,
    #[serde(default)] format: String,
    #[serde(default)] timelength: i64,
    #[serde(default)] durl: Vec<Durl>,
}

#[derive(Deserialize)]
struct Durl {
    #[serde(default)] url: String,
    #[serde(default)] backup_url: Vec<String>,
}

impl Core {
    /// Mirrors `VideoHttp.tvPlayUrl` from upstream PiliPlus.
    pub fn video_playurl(&self, aid: i64, cid: i64, qn: i64) -> CoreResult<PlayUrl> {
        let access_key = self.session.read().access_key()
            .ok_or(CoreError::AuthRequired)?;
        // PiliPlus default qn is 80; we accept caller override.
        let qn = if qn <= 0 { 80 } else { qn };
        let params = vec![
            ("access_key".into(), access_key.clone()),
            ("actionKey".into(), "appkey".into()),
            ("cid".into(), cid.to_string()),
            ("fourk".into(), "1".into()),
            ("is_proj".into(), "1".into()),
            ("mobile_access_key".into(), access_key),
            ("mobi_app".into(), "android".into()),
            ("object_id".into(), aid.to_string()),
            ("platform".into(), "android".into()),
            ("playurl_type".into(), "1".into()), // 1 = ugc
            ("protocol".into(), "0".into()),
            ("qn".into(), qn.to_string()),
        ];
        let r: PlayUrlRoot = self.http.get_signed_app(URL_PLAYURL, params)?;
        let first = r.durl.into_iter().next()
            .ok_or_else(|| CoreError::Decode("empty durl".into()))?;
        Ok(PlayUrl {
            url: first.url,
            format: r.format,
            quality: r.quality,
            duration_ms: r.timelength,
            backup_urls: first.backup_url,
        })
    }
}
