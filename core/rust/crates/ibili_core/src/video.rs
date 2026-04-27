use crate::Core;
use crate::dto::PlayUrl;
use crate::error::{CoreError, CoreResult};
use serde::Deserialize;

const URL_PLAYURL: &str = "https://app.bilibili.com/x/playurl";

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
    pub fn video_playurl(&self, aid: i64, cid: i64, qn: i64) -> CoreResult<PlayUrl> {
        let access_key = self.session.read().access_key()
            .ok_or(CoreError::AuthRequired)?;
        let params = vec![
            ("access_key".into(), access_key),
            ("aid".into(), aid.to_string()),
            ("build".into(), "2001100".into()),
            ("cid".into(), cid.to_string()),
            ("device".into(), "android".into()),
            ("fnval".into(), "0".into()), // request MP4 durl (single-file, AVPlayer-friendly)
            ("fnver".into(), "0".into()),
            ("mobi_app".into(), "android".into()),
            ("platform".into(), "android".into()),
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
