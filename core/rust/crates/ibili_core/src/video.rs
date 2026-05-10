use crate::Core;
use crate::cdn::rank_urls_for_selection;
use crate::dto::{OfflinePlayUrl, PlayUrl};
use crate::dto::{
    PgcEpisode, PgcSeason, PgcStat, RelatedVideoItem, UgcSeason, UgcSeasonEpisode,
    UgcSeasonSection, VideoDescNode, VideoHonor, VideoOwner, VideoPage, VideoStat, VideoView,
};
use crate::error::{CoreError, CoreResult};
use crate::signer::{WbiKey, WbiSigner};
use serde::{Deserialize, Deserializer};

const URL_PLAYURL_WEB: &str = "https://api.bilibili.com/x/player/wbi/playurl";
const URL_PLAYURL_PGC: &str = "https://api.bilibili.com/pgc/player/web/v2/playurl";
const URL_PLAYURL_TV: &str = "https://api.bilibili.com/x/tv/playurl";
const URL_NAV: &str = "https://api.bilibili.com/x/web-interface/nav";
const URL_PGC_INFO: &str = "https://api.bilibili.com/pgc/view/web/season";

#[derive(Deserialize)]
struct PlayUrlRoot {
    #[serde(default)] quality: i64,
    #[serde(default)] format: String,
    #[serde(default)] timelength: i64,
    #[serde(default, deserialize_with = "null_as_default")] durl: Vec<Durl>,
    #[serde(default, deserialize_with = "null_as_default")] accept_quality: Vec<i64>,
    #[serde(default, deserialize_with = "null_as_default")] accept_description: Vec<String>,
    #[serde(default)] dash: Option<Dash>,
    /// Bilibili-recorded resume position in milliseconds. Present
    /// for logged-in playback when the user previously watched this
    /// cid; absent / 0 otherwise.
    #[serde(default)] last_play_time: i64,
    #[serde(default)] last_play_cid: i64,
}

#[derive(Deserialize)]
struct PgcPlayUrlEnvelope {
    #[serde(default)] code: i64,
    #[serde(default)] message: String,
    #[serde(default)] result: Option<PgcPlayUrlResult>,
}

#[derive(Deserialize)]
struct PgcPlayUrlResult {
    video_info: PlayUrlRoot,
    #[serde(default)] play_view_business_info: Option<PgcPlayViewBusinessInfo>,
}

#[derive(Default, Deserialize)]
struct PgcPlayViewBusinessInfo {
    #[serde(default)] user_status: Option<PgcPlayUserStatus>,
}

#[derive(Default, Deserialize)]
struct PgcPlayUserStatus {
    #[serde(default, deserialize_with = "lenient_i64_value")] current_watch_progress: i64,
}

#[derive(Deserialize)]
struct PgcSeasonEnvelope {
    #[serde(default)] code: i64,
    #[serde(default)] message: String,
    #[serde(default)] result: Option<PgcSeasonWire>,
}

#[derive(Default, Deserialize)]
struct PgcSeasonWire {
    #[serde(default, deserialize_with = "lenient_i64_value")] season_id: i64,
    #[serde(default, deserialize_with = "lenient_i64_value")] media_id: i64,
    #[serde(default, deserialize_with = "null_as_default")] title: String,
    #[serde(default, deserialize_with = "null_as_default")] season_title: String,
    #[serde(default, deserialize_with = "null_as_default")] cover: String,
    #[serde(default, deserialize_with = "null_as_default")] evaluate: String,
    #[serde(default, deserialize_with = "null_as_default")] subtitle: String,
    #[serde(default, deserialize_with = "null_as_default")] areas: Vec<PgcAreaWire>,
    #[serde(default, deserialize_with = "null_as_default")] actors: String,
    #[serde(default)] rating: Option<PgcRatingWire>,
    #[serde(default)] new_ep: Option<PgcNewEpWire>,
    #[serde(default, rename = "type", deserialize_with = "lenient_i64_value")] season_type: i64,
    #[serde(default, deserialize_with = "null_as_default")] episodes: Vec<PgcEpisodeWire>,
    #[serde(default, deserialize_with = "null_as_default")] section: Vec<PgcSectionWire>,
    #[serde(default)] stat: Option<PgcStatWire>,
    #[serde(default)] up_info: Option<PgcUpInfoWire>,
}

#[derive(Default, Deserialize)]
struct PgcSectionWire {
    #[serde(default, deserialize_with = "null_as_default")] episodes: Vec<PgcEpisodeWire>,
}

#[derive(Default, Deserialize)]
struct PgcAreaWire {
    #[serde(default, deserialize_with = "null_as_default")] name: String,
}

#[derive(Default, Deserialize)]
struct PgcRatingWire {
    #[serde(default, deserialize_with = "lenient_score_string")]
    score: String,
}

#[derive(Default, Deserialize)]
struct PgcNewEpWire {
    #[serde(default, deserialize_with = "null_as_default")] desc: String,
}

#[derive(Clone, Default, Deserialize)]
struct PgcEpisodeWire {
    #[serde(default, deserialize_with = "lenient_i64_value")] aid: i64,
    #[serde(default, deserialize_with = "lenient_i64_value")] cid: i64,
    #[serde(default, deserialize_with = "null_as_default")] bvid: String,
    #[serde(default, deserialize_with = "null_as_default")] cover: String,
    #[serde(default, deserialize_with = "lenient_i64_value")] ep_id: i64,
    #[serde(default, deserialize_with = "lenient_i64_value")] id: i64,
    #[serde(default, deserialize_with = "null_as_default")] title: String,
    #[serde(default, deserialize_with = "null_as_default")] long_title: String,
    #[serde(default, deserialize_with = "null_as_default")] show_title: String,
    #[serde(default, deserialize_with = "lenient_i64_value")] duration: i64,
    #[serde(default, deserialize_with = "lenient_i64_value")] pub_time: i64,
    #[serde(default, alias = "release_date", deserialize_with = "lenient_i64_value")] release_date: i64,
    #[serde(default, deserialize_with = "null_as_default")] badge: String,
}

#[derive(Default, Deserialize)]
struct PgcStatWire {
    #[serde(default, alias = "views", deserialize_with = "lenient_i64_value")] view: i64,
    #[serde(default, alias = "danmakus", deserialize_with = "lenient_i64_value")] danmaku: i64,
    #[serde(default, deserialize_with = "lenient_i64_value")] reply: i64,
    #[serde(default, deserialize_with = "lenient_i64_value")] favorite: i64,
    #[serde(default, alias = "coins", deserialize_with = "lenient_i64_value")] coin: i64,
    #[serde(default, deserialize_with = "lenient_i64_value")] share: i64,
    #[serde(default, alias = "likes", deserialize_with = "lenient_i64_value")] like: i64,
}

#[derive(Default, Deserialize)]
struct PgcUpInfoWire {
    #[serde(default, deserialize_with = "lenient_i64_value")] mid: i64,
    #[serde(default, alias = "uname", deserialize_with = "null_as_default")] name: String,
}

#[derive(Clone, Deserialize)]
struct Durl {
    #[serde(default)] url: String,
    #[serde(default, deserialize_with = "null_as_default")] backup_url: Vec<String>,
}

#[derive(Deserialize)]
struct Dash {
    #[serde(default, deserialize_with = "null_as_default")] video: Vec<DashVideo>,
    #[serde(default, deserialize_with = "null_as_default")] audio: Vec<DashAudio>,
    #[serde(default)] flac: Option<FlacAudio>,
    #[serde(default)] dolby: Option<DolbyAudio>,
}

#[derive(Default, Deserialize)]
struct FlacAudio {
    #[serde(default)] audio: Option<DashAudio>,
}

#[derive(Default, Deserialize)]
struct DolbyAudio {
    #[serde(default, deserialize_with = "null_as_default")] audio: Vec<DashAudio>,
}

#[derive(Clone)]
struct DashVideo {
    id: i64,
    base_url: String,
    backup_url: Vec<String>,
    codecs: String,
    bandwidth: i64,
    width: i64,
    height: i64,
    frame_rate: String,
}

#[derive(Clone)]
struct DashAudio {
    id: i64,
    base_url: String,
    backup_url: Vec<String>,
    codecs: String,
    bandwidth: i64,
}

#[derive(Default, Deserialize)]
struct DashVideoWire {
    #[serde(default)] id: i64,
    #[serde(default)] base_url: String,
    #[serde(default, rename = "baseUrl")] base_url_camel: String,
    #[serde(default, deserialize_with = "null_as_default")] backup_url: Vec<String>,
    #[serde(default, rename = "backupUrl", deserialize_with = "null_as_default")] backup_url_camel: Vec<String>,
    #[serde(default)] codecs: String,
    #[serde(default)] bandwidth: i64,
    #[serde(default, rename = "bandWidth")] bandwidth_camel: i64,
    #[serde(default)] width: i64,
    #[serde(default)] height: i64,
    #[serde(default)] frame_rate: String,
    #[serde(default, rename = "frameRate")] frame_rate_camel: String,
}

#[derive(Default, Deserialize)]
struct DashAudioWire {
    #[serde(default)] id: i64,
    #[serde(default)] base_url: String,
    #[serde(default, rename = "baseUrl")] base_url_camel: String,
    #[serde(default, deserialize_with = "null_as_default")] backup_url: Vec<String>,
    #[serde(default, rename = "backupUrl", deserialize_with = "null_as_default")] backup_url_camel: Vec<String>,
    #[serde(default)] codecs: String,
    #[serde(default)] bandwidth: i64,
    #[serde(default, rename = "bandWidth")] bandwidth_camel: i64,
}

#[derive(Deserialize)]
struct NavData {
    wbi_img: NavWbiImage,
}

#[derive(Deserialize)]
struct NavWbiImage {
    img_url: String,
    sub_url: String,
}

fn null_as_default<'de, D, T>(de: D) -> Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Default + serde::Deserialize<'de>,
{
    Ok(Option::<T>::deserialize(de)?.unwrap_or_default())
}

fn lenient_i64_value<'de, D>(de: D) -> Result<i64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde_json::Value;
    let v = Option::<Value>::deserialize(de)?;
    Ok(match v {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        Some(Value::String(s)) => s.parse().unwrap_or(0),
        Some(Value::Bool(b)) => i64::from(b),
        _ => 0,
    })
}

fn lenient_score_string<'de, D>(de: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde_json::Value;
    let v = Option::<Value>::deserialize(de)?;
    Ok(match v {
        Some(Value::Number(n)) => {
            if let Some(i) = n.as_i64() {
                if i > 0 { i.to_string() } else { String::new() }
            } else if let Some(f) = n.as_f64() {
                if f > 0.0 {
                    let mut s = format!("{:.1}", f);
                    if s.ends_with(".0") {
                        s.truncate(s.len() - 2);
                    }
                    s
                } else {
                    String::new()
                }
            } else {
                String::new()
            }
        }
        Some(Value::String(s)) => {
            let trimmed = s.trim();
            if trimmed.is_empty() || trimmed == "0" || trimmed == "0.0" {
                String::new()
            } else {
                trimmed.to_string()
            }
        }
        _ => String::new(),
    })
}

fn prefer_non_empty(primary: String, secondary: String) -> String {
    if !primary.is_empty() { primary } else { secondary }
}

fn prefer_non_empty_vec<T>(primary: Vec<T>, secondary: Vec<T>) -> Vec<T> {
    if !primary.is_empty() { primary } else { secondary }
}

fn prefer_non_zero(primary: i64, secondary: i64) -> i64 {
    if primary != 0 { primary } else { secondary }
}

impl From<DashVideoWire> for DashVideo {
    fn from(wire: DashVideoWire) -> Self {
        Self {
            id: wire.id,
            base_url: prefer_non_empty(wire.base_url, wire.base_url_camel),
            backup_url: prefer_non_empty_vec(wire.backup_url, wire.backup_url_camel),
            codecs: wire.codecs,
            bandwidth: prefer_non_zero(wire.bandwidth, wire.bandwidth_camel),
            width: wire.width,
            height: wire.height,
            frame_rate: prefer_non_empty(wire.frame_rate, wire.frame_rate_camel),
        }
    }
}

impl From<DashAudioWire> for DashAudio {
    fn from(wire: DashAudioWire) -> Self {
        Self {
            id: wire.id,
            base_url: prefer_non_empty(wire.base_url, wire.base_url_camel),
            backup_url: prefer_non_empty_vec(wire.backup_url, wire.backup_url_camel),
            codecs: wire.codecs,
            bandwidth: prefer_non_zero(wire.bandwidth, wire.bandwidth_camel),
        }
    }
}

impl<'de> Deserialize<'de> for DashVideo {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        DashVideoWire::deserialize(deserializer).map(Into::into)
    }
}

impl<'de> Deserialize<'de> for DashAudio {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        DashAudioWire::deserialize(deserializer).map(Into::into)
    }
}

impl PgcSeasonWire {
    fn into_pgc_season(self) -> PgcSeason {
        let mut episodes = self
            .episodes
            .into_iter()
            .chain(self.section.into_iter().flat_map(|section| section.episodes))
            .map(PgcEpisodeWire::into_pgc_episode)
            .filter(|ep| ep.ep_id > 0 && ep.cid > 0)
            .collect::<Vec<_>>();
        episodes.sort_by_key(|ep| ep.ep_id);
        episodes.dedup_by_key(|ep| ep.ep_id);

        let stat = self.stat.unwrap_or_default();
        let up_info = self.up_info.unwrap_or_default();
        let rating_score = self.rating.map(|rating| rating.score).unwrap_or_default();
        let new_ep_desc = self.new_ep.map(|ep| ep.desc).unwrap_or_default();
        PgcSeason {
            season_id: self.season_id,
            media_id: self.media_id,
            title: self.title,
            season_title: self.season_title,
            cover: self.cover,
            evaluate: self.evaluate,
            subtitle: self.subtitle,
            areas: self
                .areas
                .into_iter()
                .map(|area| area.name)
                .filter(|name| !name.trim().is_empty())
                .collect(),
            actors: self.actors,
            rating_score,
            new_ep_desc,
            season_type: self.season_type,
            up_mid: up_info.mid,
            up_name: up_info.name,
            stat: PgcStat {
                view: stat.view,
                danmaku: stat.danmaku,
                reply: stat.reply,
                favorite: stat.favorite,
                coin: stat.coin,
                share: stat.share,
                like: stat.like,
            },
            episodes,
        }
    }
}

impl PgcEpisodeWire {
    fn into_pgc_episode(self) -> PgcEpisode {
        let title = if !self.show_title.is_empty() {
            self.show_title
        } else {
            self.title
        };
        PgcEpisode {
            ep_id: if self.ep_id > 0 { self.ep_id } else { self.id },
            aid: self.aid,
            bvid: self.bvid,
            cid: self.cid,
            title,
            long_title: self.long_title,
            cover: self.cover,
            duration_sec: normalize_pgc_duration_sec(self.duration),
            pub_time: if self.pub_time > 0 { self.pub_time } else { self.release_date },
            badge: self.badge,
        }
    }
}

fn normalize_pgc_duration_sec(duration: i64) -> i64 {
    if duration > 24 * 60 * 60 {
        duration / 1000
    } else {
        duration
    }
}

impl Core {
    /// Resolve the default page `cid` for a `bvid` via
    /// `/x/web-interface/view`. Used by callers that only have a bvid
    /// (e.g. the search results screen — `searchByType` does not return
    /// cids on video rows). Returns the cid of `pages[0]` which is what
    /// the playurl endpoint expects for a single-part video.
    pub fn video_view_cid(&self, bvid: &str) -> CoreResult<i64> {
        const URL_VIEW: &str = "https://api.bilibili.com/x/web-interface/view";

        #[derive(Deserialize)]
        struct ViewData {
            #[serde(default)] cid: i64,
            #[serde(default)] pages: Vec<ViewPage>,
        }
        #[derive(Deserialize)]
        struct ViewPage {
            #[serde(default)] cid: i64,
        }

        let data: ViewData = self
            .http
            .get_web(URL_VIEW, &[("bvid".to_string(), bvid.to_string())])?;
        if data.cid > 0 { return Ok(data.cid); }
        if let Some(p) = data.pages.first() {
            if p.cid > 0 { return Ok(p.cid); }
        }
        Err(CoreError::Internal(format!(
            "view returned no cid for bvid={bvid}"
        )))
    }

    pub fn video_playurl(&self, aid: i64, cid: i64, qn: i64) -> CoreResult<PlayUrl> {
        self.video_playurl_with_audio(aid, cid, qn, 0)
    }

    pub fn video_playurl_with_audio(&self, aid: i64, cid: i64, qn: i64, audio_qn: i64) -> CoreResult<PlayUrl> {
        self.video_playurl_with_audio_options(aid, cid, qn, audio_qn, "auto")
    }

    pub fn video_playurl_with_audio_options(
        &self,
        aid: i64,
        cid: i64,
        qn: i64,
        audio_qn: i64,
        cdn_selection: &str,
    ) -> CoreResult<PlayUrl> {
        match self.video_playurl_web_with_audio(aid, cid, qn, audio_qn, cdn_selection) {
            Ok(play) => Ok(play),
            Err(web_err) => {
                let web_msg = format!("wbi/playurl failed → fell back to tv_durl: {web_err}");
                eprintln!("[ibili_core] {web_msg}");
                match self.video_playurl_tv_with_options(aid, cid, qn, cdn_selection) {
                    Ok(mut play) => {
                        // Embed the web-path failure into the response so
                        // iOS log viewer can show the real cause without
                        // requiring an Xcode console attachment.
                        play.debug_message = Some(web_msg);
                        Ok(play)
                    }
                    Err(tv_err) => Err(CoreError::Internal(format!(
                        "web playurl failed: {web_err}; tv playurl failed: {tv_err}"
                    ))),
                }
            }
        }
    }

    pub fn video_offline_playurl(
        &self,
        aid: i64,
        cid: i64,
        qn: i64,
        audio_qn: i64,
        cdn_selection: &str,
    ) -> CoreResult<OfflinePlayUrl> {
        let play = self.video_playurl_with_audio_options(aid, cid, qn, audio_qn, cdn_selection)?;
        Ok(build_offline_playurl(play))
    }

    pub fn pgc_playurl_with_audio_options(
        &self,
        aid: i64,
        cid: i64,
        ep_id: i64,
        season_id: i64,
        qn: i64,
        audio_qn: i64,
        cdn_selection: &str,
    ) -> CoreResult<PlayUrl> {
        match self.pgc_playurl_web_with_audio(aid, cid, ep_id, season_id, qn, audio_qn, cdn_selection) {
            Ok(play) => Ok(play),
            Err(web_err) => {
                let web_msg = format!("pgc/player/web/v2/playurl failed → fell back to tv_durl: {web_err}");
                eprintln!("[ibili_core] {web_msg}");
                if ep_id <= 0 {
                    return Err(CoreError::Internal(web_msg));
                }
                match self.pgc_playurl_tv_with_options(ep_id, cid, qn, cdn_selection) {
                    Ok(mut play) => {
                        play.debug_message = Some(web_msg);
                        Ok(play)
                    }
                    Err(tv_err) => Err(CoreError::Internal(format!(
                        "pgc web playurl failed: {web_err}; pgc tv playurl failed: {tv_err}"
                    ))),
                }
            }
        }
    }

    pub fn pgc_offline_playurl(
        &self,
        aid: i64,
        cid: i64,
        ep_id: i64,
        season_id: i64,
        qn: i64,
        audio_qn: i64,
        cdn_selection: &str,
    ) -> CoreResult<OfflinePlayUrl> {
        let play = self.pgc_playurl_with_audio_options(
            aid,
            cid,
            ep_id,
            season_id,
            qn,
            audio_qn,
            cdn_selection,
        )?;
        Ok(build_offline_playurl(play))
    }

    pub fn video_playurl_tv_compat(&self, aid: i64, cid: i64, qn: i64) -> CoreResult<PlayUrl> {
        self.video_playurl_tv(aid, cid, qn)
    }

    pub fn pgc_season(&self, season_id: i64, ep_id: i64) -> CoreResult<PgcSeason> {
        if season_id <= 0 && ep_id <= 0 {
            return Err(CoreError::InvalidArgument("season_id or ep_id required".into()));
        }
        let mut params: Vec<(String, String)> = Vec::new();
        if season_id > 0 {
            params.push(("season_id".into(), season_id.to_string()));
        }
        if ep_id > 0 {
            params.push(("ep_id".into(), ep_id.to_string()));
        }
        let body = self
            .http
            .client
            .get(URL_PGC_INFO)
            .header("User-Agent", crate::http::UA_WEB)
            .header("Referer", "https://www.bilibili.com/")
            .query(&params)
            .send()
            .map_err(|e| CoreError::Network(e.to_string()))?
            .text()
            .map_err(|e| CoreError::Network(e.to_string()))?;
        let env: PgcSeasonEnvelope = serde_json::from_str(&body)
            .map_err(|e| CoreError::Decode(format!("{}: {}", e, body.chars().take(500).collect::<String>())))?;
        if env.code != 0 {
            return Err(CoreError::Api { code: env.code, msg: env.message });
        }
        let wire = env.result.ok_or_else(|| CoreError::Decode("missing pgc result".into()))?;
        Ok(wire.into_pgc_season())
    }

    fn video_playurl_web_with_audio(
        &self,
        aid: i64,
        cid: i64,
        qn: i64,
        audio_qn: i64,
        cdn_selection: &str,
    ) -> CoreResult<PlayUrl> {
        let qn = if qn <= 0 { 80 } else { qn };
        let wbi_key = self.fetch_wbi_key()?;
        let params = vec![
            ("avid".into(), aid.to_string()),
            ("cid".into(), cid.to_string()),
            ("qn".into(), qn.to_string()),
            ("fnval".into(), "4048".into()),
            ("fourk".into(), "1".into()),
            ("fnver".into(), "0".into()),
            ("voice_balance".into(), "1".into()),
            ("gaia_source".into(), "pre-load".into()),
            ("isGaiaAvoided".into(), "true".into()),
            ("web_location".into(), "1315873".into()),
        ];
        let response: PlayUrlRoot = self.http.get_signed_web(URL_PLAYURL_WEB, params, &wbi_key)?;
        build_playurl_from_web_response(response, qn, audio_qn, cdn_selection)
    }

    fn pgc_playurl_web_with_audio(
        &self,
        aid: i64,
        cid: i64,
        ep_id: i64,
        season_id: i64,
        qn: i64,
        audio_qn: i64,
        cdn_selection: &str,
    ) -> CoreResult<PlayUrl> {
        let qn = if qn <= 0 { 80 } else { qn };
        let wbi_key = self.fetch_wbi_key()?;
        let mut params = vec![
            ("cid".into(), cid.to_string()),
            ("qn".into(), qn.to_string()),
            ("fnval".into(), "4048".into()),
            ("fourk".into(), "1".into()),
            ("fnver".into(), "0".into()),
            ("voice_balance".into(), "1".into()),
            ("gaia_source".into(), "pre-load".into()),
            ("isGaiaAvoided".into(), "true".into()),
            ("web_location".into(), "1315873".into()),
        ];
        if aid > 0 {
            params.push(("avid".into(), aid.to_string()));
        }
        if ep_id > 0 {
            params.push(("ep_id".into(), ep_id.to_string()));
        }
        if season_id > 0 {
            params.push(("season_id".into(), season_id.to_string()));
        }
        WbiSigner::sign(&mut params, &wbi_key);
        let body = self
            .http
            .client
            .get(URL_PLAYURL_PGC)
            .header("User-Agent", crate::http::UA_WEB)
            .header("Referer", "https://www.bilibili.com/")
            .query(&params)
            .send()
            .map_err(|e| CoreError::Network(e.to_string()))?
            .text()
            .map_err(|e| CoreError::Network(e.to_string()))?;
        let env: PgcPlayUrlEnvelope = serde_json::from_str(&body)
            .map_err(|e| CoreError::Decode(format!("{}: {}", e, body.chars().take(500).collect::<String>())))?;
        if env.code != 0 {
            return Err(CoreError::Api { code: env.code, msg: env.message });
        }
        let result = env.result.ok_or_else(|| CoreError::Decode("missing pgc playurl result".into()))?;
        let resume_ms = result
            .play_view_business_info
            .and_then(|info| info.user_status)
            .map(|status| status.current_watch_progress)
            .unwrap_or(0);
        let mut play = build_playurl_from_web_response(result.video_info, qn, audio_qn, cdn_selection)?;
        play.last_play_time_ms = resume_ms;
        play.stream_type = format!("pgc_{}", play.stream_type);
        Ok(play)
    }

    /// Mirrors `VideoHttp.tvPlayUrl` from upstream PiliPlus.
    fn video_playurl_tv(&self, aid: i64, cid: i64, qn: i64) -> CoreResult<PlayUrl> {
        self.video_playurl_tv_with_options(aid, cid, qn, "auto")
    }

    fn video_playurl_tv_with_options(
        &self,
        aid: i64,
        cid: i64,
        qn: i64,
        cdn_selection: &str,
    ) -> CoreResult<PlayUrl> {
        let access_key = self.session.read().access_key()
            .ok_or(CoreError::AuthRequired)?;
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
        let r: PlayUrlRoot = self.http.get_signed_app(URL_PLAYURL_TV, params)?;
        let accept_quality = r.accept_quality.clone();
        let accept_description = r.accept_description.clone();
        let first = r.durl.into_iter().next()
            .ok_or_else(|| CoreError::Decode("empty durl".into()))?;
        let ranked = rank_urls_for_selection(
            &collect_candidates(&first.url, &first.backup_url),
            cdn_selection,
        );
        let url = ranked.first().cloned().unwrap_or(first.url);
        let backup_urls = ranked.into_iter().skip(1).collect::<Vec<_>>();
        Ok(PlayUrl {
            url,
            audio_url: None,
            format: r.format,
            stream_type: "tv_durl".into(),
            quality: r.quality,
            duration_ms: r.timelength,
            backup_urls,
            audio_backup_urls: Vec::new(),
            accept_quality,
            accept_description,
            video_codec: String::new(),
            audio_codec: String::new(),
            video_width: None,
            video_height: None,
            video_frame_rate: None,
            video_range: None,
            debug_message: None,
            audio_quality: 0,
            audio_quality_label: String::new(),
            accept_audio_quality: Vec::new(),
            accept_audio_description: Vec::new(),
            last_play_time_ms: r.last_play_time,
            last_play_cid: r.last_play_cid,
        })
    }

    fn pgc_playurl_tv_with_options(
        &self,
        ep_id: i64,
        cid: i64,
        qn: i64,
        cdn_selection: &str,
    ) -> CoreResult<PlayUrl> {
        let access_key = self.session.read().access_key()
            .ok_or(CoreError::AuthRequired)?;
        let qn = if qn <= 0 { 80 } else { qn };
        let params = vec![
            ("access_key".into(), access_key.clone()),
            ("actionKey".into(), "appkey".into()),
            ("cid".into(), cid.to_string()),
            ("fourk".into(), "1".into()),
            ("is_proj".into(), "1".into()),
            ("mobile_access_key".into(), access_key),
            ("mobi_app".into(), "android".into()),
            ("object_id".into(), ep_id.to_string()),
            ("platform".into(), "android".into()),
            ("playurl_type".into(), "2".into()),
            ("protocol".into(), "0".into()),
            ("qn".into(), qn.to_string()),
        ];
        let r: PlayUrlRoot = self.http.get_signed_app(URL_PLAYURL_TV, params)?;
        let accept_quality = r.accept_quality.clone();
        let accept_description = r.accept_description.clone();
        let first = r.durl.into_iter().next()
            .ok_or_else(|| CoreError::Decode("empty pgc tv durl".into()))?;
        let ranked = rank_urls_for_selection(
            &collect_candidates(&first.url, &first.backup_url),
            cdn_selection,
        );
        let url = ranked.first().cloned().unwrap_or(first.url);
        let backup_urls = ranked.into_iter().skip(1).collect::<Vec<_>>();
        Ok(PlayUrl {
            url,
            audio_url: None,
            format: r.format,
            stream_type: "pgc_tv_durl".into(),
            quality: r.quality,
            duration_ms: r.timelength,
            backup_urls,
            audio_backup_urls: Vec::new(),
            accept_quality,
            accept_description,
            video_codec: String::new(),
            audio_codec: String::new(),
            video_width: None,
            video_height: None,
            video_frame_rate: None,
            video_range: None,
            debug_message: None,
            audio_quality: 0,
            audio_quality_label: String::new(),
            accept_audio_quality: Vec::new(),
            accept_audio_description: Vec::new(),
            last_play_time_ms: r.last_play_time,
            last_play_cid: r.last_play_cid,
        })
    }

    fn fetch_wbi_key(&self) -> CoreResult<WbiKey> {
        let nav: NavData = self.http.get_web(URL_NAV, &[])?;
        Ok(WbiKey::from_urls(&nav.wbi_img.img_url, &nav.wbi_img.sub_url))
    }
}

fn build_offline_playurl(play: PlayUrl) -> OfflinePlayUrl {
    let video_codec = play.video_codec.to_ascii_lowercase();
    let audio_codec = play.audio_codec.to_ascii_lowercase();
    let is_dash = play.audio_url.is_some();
    let video_supported = video_codec.is_empty()
        || video_codec.starts_with("avc")
        || video_codec.starts_with("hev")
        || video_codec.starts_with("hvc")
        || video_codec.starts_with("dv");
    let audio_supported = audio_codec.is_empty()
        || audio_codec.starts_with("mp4a")
        || audio_codec.starts_with("ec-3")
        || audio_codec.starts_with("ac-3")
        || audio_codec.starts_with("fla");
    let mut candidates = vec!["mp4".to_string(), "m4v".to_string(), "mov".to_string()];
    if video_codec.starts_with("dv") || video_codec.contains("dvh") || video_codec.contains("dvh1") {
        candidates = vec!["mov".to_string(), "m4v".to_string(), "mp4".to_string()];
    }
    let can_lossless_remux = !is_dash || (video_supported && audio_supported);
    let lossless_note = if can_lossless_remux {
        if is_dash {
            "可尝试无损合并音视频流".to_string()
        } else {
            "单流可直接保存为原始文件".to_string()
        }
    } else {
        format!(
            "当前编码可能无法由系统无损封装为单文件: video={}, audio={}",
            if play.video_codec.is_empty() { "unknown" } else { &play.video_codec },
            if play.audio_codec.is_empty() { "unknown" } else { &play.audio_codec },
        )
    };
    OfflinePlayUrl {
        play,
        lossless_container_candidates: candidates,
        can_lossless_remux,
        lossless_note,
    }
}

impl Dash {
    fn all_audio(self) -> Vec<DashAudio> {
        let mut audio = Vec::new();
        if let Some(flac) = self.flac.and_then(|item| item.audio) {
            audio.push(flac);
        }
        if let Some(dolby) = self.dolby {
            audio.extend(dolby.audio);
        }
        audio.extend(self.audio);
        audio
    }
}

impl DashVideo {
    #[allow(dead_code)]
    fn play_url(&self) -> Option<String> {
        if !self.base_url.is_empty() {
            Some(self.base_url.clone())
        } else {
            self.backup_url.first().cloned()
        }
    }
}

impl DashAudio {
    #[allow(dead_code)]
    fn play_url(&self) -> Option<String> {
        if !self.base_url.is_empty() {
            Some(self.base_url.clone())
        } else {
            self.backup_url.first().cloned()
        }
    }
}

fn build_playurl_from_web_response(
    response: PlayUrlRoot,
    requested_qn: i64,
    audio_qn: i64,
    cdn_selection: &str,
) -> CoreResult<PlayUrl> {
    let accept_quality = if response.accept_quality.is_empty() {
        response.dash.as_ref()
            .map(|dash| collect_dash_qualities(&dash.video))
            .unwrap_or_default()
    } else {
        response.accept_quality.clone()
    };
    let accept_description = if response.accept_description.is_empty() {
        accept_quality.iter().map(|qn| quality_label(*qn)).collect()
    } else {
        response.accept_description.clone()
    };

    if let Some(dash) = response.dash {
        let target_qn = pick_target_quality(requested_qn, &accept_quality, &dash.video);
        if let Some(video) = pick_video_stream(&dash.video, target_qn) {
            let all_audio = dash.all_audio();
            let (accept_audio_quality, accept_audio_description) = collect_audio_qualities(&all_audio);
            let audio = pick_audio_stream_by_quality(&all_audio, audio_qn);
            let video_candidates = collect_candidates(&video.base_url, &video.backup_url);
            let video_ranked = rank_urls_for_selection(&video_candidates, cdn_selection);
            if let Some(video_url) = video_ranked.first().cloned() {
                let video_backups = video_ranked.into_iter().skip(1).collect::<Vec<_>>();
                let video_codec = video.codecs.clone();
                let video_width = positive_i64(video.width);
                let video_height = positive_i64(video.height);
                let video_frame_rate = normalize_frame_rate(&video.frame_rate);
                let video_range = playurl_video_range_hint(video.id, &video.codecs);
                let (audio_url, audio_backups, audio_codec, picked_audio_qn) = match audio {
                    Some(a) => {
                        let candidates = collect_candidates(&a.base_url, &a.backup_url);
                        let ranked = rank_urls_for_selection(&candidates, cdn_selection);
                        let primary = ranked.first().cloned();
                        let backups = ranked.into_iter().skip(1).collect::<Vec<_>>();
                        (primary, backups, a.codecs.clone(), a.id)
                    }
                    None => (None, Vec::new(), String::new(), 0),
                };
                return Ok(PlayUrl {
                    url: video_url,
                    audio_url,
                    format: response.format,
                    stream_type: "web_dash".into(),
                    quality: video.id,
                    duration_ms: response.timelength,
                    backup_urls: video_backups,
                    audio_backup_urls: audio_backups,
                    accept_quality,
                    accept_description,
                    video_codec,
                    audio_codec,
                    video_width,
                    video_height,
                    video_frame_rate,
                    video_range,
                    debug_message: None,
                    audio_quality: picked_audio_qn,
                    audio_quality_label: audio_quality_label(picked_audio_qn),
                    accept_audio_quality,
                    accept_audio_description,
                    last_play_time_ms: response.last_play_time,
                    last_play_cid: response.last_play_cid,
                });
            }
        }
    }

    let first = response.durl.into_iter().next()
        .ok_or_else(|| CoreError::Decode("missing playable stream".into()))?;
    let ranked = rank_urls_for_selection(
        &collect_candidates(&first.url, &first.backup_url),
        cdn_selection,
    );
    let url = ranked.first().cloned().unwrap_or(first.url);
    let backup_urls = ranked.into_iter().skip(1).collect::<Vec<_>>();
    Ok(PlayUrl {
        url,
        audio_url: None,
        format: response.format,
        stream_type: "web_durl".into(),
        quality: response.quality,
        duration_ms: response.timelength,
        backup_urls,
        audio_backup_urls: Vec::new(),
        accept_quality,
        accept_description,
        video_codec: String::new(),
        audio_codec: String::new(),
        video_width: None,
        video_height: None,
        video_frame_rate: None,
        video_range: None,
        debug_message: None,
        audio_quality: 0,
        audio_quality_label: String::new(),
        accept_audio_quality: Vec::new(),
        accept_audio_description: Vec::new(),
        last_play_time_ms: response.last_play_time,
        last_play_cid: response.last_play_cid,
    })
}

fn collect_candidates(primary: &str, backups: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(backups.len() + 1);
    if !primary.is_empty() {
        out.push(primary.to_string());
    }
    for u in backups {
        if u.is_empty() { continue; }
        if !out.iter().any(|x| x == u) {
            out.push(u.clone());
        }
    }
    out
}

fn positive_i64(value: i64) -> Option<i64> {
    (value > 0).then_some(value)
}

fn normalize_frame_rate(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some((numerator, denominator)) = trimmed.split_once('/') {
        let numerator = numerator.trim().parse::<f64>().ok()?;
        let denominator = denominator.trim().parse::<f64>().ok()?;
        if denominator <= 0.0 {
            return None;
        }
        return Some(format!("{:.3}", numerator / denominator));
    }
    trimmed
        .parse::<f64>()
        .ok()
        .filter(|value| *value > 0.0)
        .map(|value| format!("{value:.3}"))
}

fn playurl_video_range_hint(quality: i64, codec: &str) -> Option<String> {
    let codec = codec.to_ascii_lowercase();
    let is_hdr_capable_codec = codec.starts_with("hvc1")
        || codec.starts_with("hev1")
        || codec.starts_with("dvh1")
        || codec.starts_with("dvhe");
    if is_hdr_capable_codec && matches!(quality, 125 | 126) {
        Some("PQ".to_string())
    } else {
        None
    }
}

fn collect_dash_qualities(videos: &[DashVideo]) -> Vec<i64> {
    let mut items = videos.iter().map(|item| item.id).collect::<Vec<_>>();
    items.sort_unstable_by(|a, b| b.cmp(a));
    items.dedup();
    items
}

fn pick_target_quality(requested_qn: i64, accept_quality: &[i64], videos: &[DashVideo]) -> i64 {
    let mut candidates = if accept_quality.is_empty() {
        collect_dash_qualities(videos)
    } else {
        accept_quality.to_vec()
    };
    candidates.sort_unstable_by(|a, b| b.cmp(a));
    candidates.dedup();
    let highest = candidates.first().copied()
        .or_else(|| videos.iter().map(|item| item.id).max())
        .unwrap_or(64);
    if requested_qn <= 0 {
        return highest;
    }
    candidates.into_iter().find(|item| *item <= requested_qn).unwrap_or(highest)
}

fn pick_video_stream(videos: &[DashVideo], target_qn: i64) -> Option<DashVideo> {
    let resolved_qn = videos.iter()
        .map(|item| item.id)
        .filter(|item| *item <= target_qn)
        .max()
        .or_else(|| videos.iter().map(|item| item.id).max())?;
    videos.iter()
        .filter(|item| item.id == resolved_qn)
        .max_by_key(|item| (video_codec_score(&item.codecs), item.bandwidth))
        .cloned()
}

/// Map audio stream id to a quality tier for sorting/comparison.
/// Higher score = better quality. B站's ids are NOT monotonically
/// ordered by quality: 30280(192K) > 30251(Hi-Res) numerically,
/// but Hi-Res is higher quality.
fn audio_quality_rank(id: i64) -> i32 {
    match id {
        30251 => 500,          // Hi-Res无损
        30250 | 30255 => 400,  // 杜比全景声
        30280 => 300,          // 192K
        30232 => 200,          // 132K
        30216 => 100,          // 64K
        _ => 0,
    }
}

fn pick_audio_stream(audio: &[DashAudio]) -> Option<DashAudio> {
    audio.iter()
        .max_by_key(|item| (audio_quality_rank(item.id), audio_codec_score(&item.codecs), item.bandwidth))
        .cloned()
}

fn pick_audio_stream_by_quality(audio: &[DashAudio], preferred_id: i64) -> Option<DashAudio> {
    if preferred_id <= 0 {
        return pick_audio_stream(audio);
    }
    if let Some(exact) = audio.iter().find(|a| a.id == preferred_id) {
        return Some(exact.clone());
    }
    let preferred_rank = audio_quality_rank(preferred_id);
    let mut sorted: Vec<&DashAudio> = audio.iter().collect();
    sorted.sort_by(|a, b| audio_quality_rank(b.id).cmp(&audio_quality_rank(a.id)));
    sorted.into_iter()
        .find(|a| audio_quality_rank(a.id) <= preferred_rank)
        .or_else(|| audio.iter().min_by_key(|a| audio_quality_rank(a.id)))
        .cloned()
}

fn collect_audio_qualities(audio: &[DashAudio]) -> (Vec<i64>, Vec<String>) {
    let mut ids: Vec<i64> = audio.iter().map(|a| a.id).collect();
    ids.sort_unstable_by(|a, b| audio_quality_rank(*b).cmp(&audio_quality_rank(*a)));
    ids.dedup();
    let labels: Vec<String> = ids.iter().map(|id| audio_quality_label(*id)).collect();
    (ids, labels)
}

fn audio_quality_label(id: i64) -> String {
    match id {
        30251 => "Hi-Res无损".into(),
        30250 | 30255 => "杜比全景声".into(),
        30280 => "192K".into(),
        30232 => "132K".into(),
        30216 => "64K".into(),
        0 => String::new(),
        _ => format!("音质 {id}"),
    }
}

/// Codec preference score for picking the best video stream.
///
/// HEVC / Dolby Vision is always preferred on iOS: Apple Silicon has
/// dedicated hardware decoders and HEVC delivers better quality per bit
/// than H.264 at every resolution. For HDR quality levels (qn >= 125)
/// H.264 additionally cannot carry PQ/HLG transfer characteristics, so
/// picking it would produce an unplayable stream.
///
/// AV1 (`av01.*`) is scored below HEVC: while Apple Silicon decodes AV1
/// in hardware from A17 Pro onwards, AVPlayer's HLS byte-range fMP4
/// path has exhibited intermittent failures with AV1 content; HEVC is
/// the safer default.
fn video_codec_score(codecs: &str) -> i32 {
    if codecs.starts_with("hev1") || codecs.starts_with("hvc1")
        || codecs.starts_with("dvh1") || codecs.starts_with("dvhe") {
        400
    } else if codecs.starts_with("av01") {
        300
    } else if codecs.starts_with("avc1") {
        200
    } else {
        50
    }
}

fn audio_codec_score(codecs: &str) -> i32 {
    if codecs.starts_with("mp4a") { 200 }
    else if codecs.starts_with("ec-3") || codecs.starts_with("ac-3") { 100 }
    else { 0 }
}

fn quality_label(qn: i64) -> String {
    match qn {
        127 => "8K".into(),
        126 => "杜比".into(),
        125 => "HDR".into(),
        120 => "4K".into(),
        116 => "1080P60".into(),
        112 => "1080P+".into(),
        80 => "1080P".into(),
        74 => "720P60".into(),
        64 => "720P".into(),
        32 => "480P".into(),
        16 => "360P".into(),
        6 => "240P".into(),
        _ => format!("画质 {qn}"),
    }
}

// ============================================================================
// Video detail (view full) + related videos
// ============================================================================

const URL_VIEW_FULL: &str = "https://api.bilibili.com/x/web-interface/wbi/view";
const URL_RELATED: &str = "https://api.bilibili.com/x/web-interface/archive/related";

fn video_lookup_params(aid: i64, bvid: &str) -> CoreResult<Vec<(String, String)>> {
    if !bvid.is_empty() {
        return Ok(vec![("bvid".to_string(), bvid.to_string())]);
    }
    if aid > 0 {
        return Ok(vec![("aid".to_string(), aid.to_string())]);
    }
    Err(CoreError::InvalidArgument("aid and bvid empty".into()))
}

#[derive(Deserialize)]
struct ViewFullRoot {
    #[serde(default)] aid: i64,
    #[serde(default)] bvid: String,
    #[serde(default)] cid: i64,
    #[serde(default)] title: String,
    #[serde(default, alias = "pic")] cover: String,
    #[serde(default)] desc: String,
    #[serde(default, deserialize_with = "null_as_default")] desc_v2: Vec<DescV2Wire>,
    #[serde(default)] duration: i64,
    #[serde(default)] pubdate: i64,
    #[serde(default)] ctime: i64,
    #[serde(default)] videos: i32,
    #[serde(default)] stat: ViewStatWire,
    #[serde(default)] owner: ViewOwnerWire,
    #[serde(default, deserialize_with = "null_as_default")] pages: Vec<ViewPageWire>,
    #[serde(default, deserialize_with = "null_as_default")] honor_reply: HonorReplyWire,
    #[serde(default)] ugc_season: Option<UgcSeasonWire>,
    #[serde(default)] redirect_url: String,
}

#[derive(Default, Deserialize)]
struct ViewStatWire {
    #[serde(default)] view: i64,
    #[serde(default)] danmaku: i64,
    #[serde(default)] reply: i64,
    #[serde(default)] favorite: i64,
    #[serde(default)] coin: i64,
    #[serde(default)] share: i64,
    #[serde(default)] like: i64,
}

#[derive(Default, Deserialize)]
struct ViewOwnerWire {
    #[serde(default)] mid: i64,
    #[serde(default)] name: String,
    #[serde(default)] face: String,
}

#[derive(Deserialize)]
struct ViewPageWire {
    #[serde(default)] cid: i64,
    #[serde(default)] page: i32,
    #[serde(default)] part: String,
    #[serde(default)] duration: i64,
    #[serde(default)] first_frame: String,
}

#[derive(Deserialize)]
struct DescV2Wire {
    #[serde(default, alias = "type")] kind: i32,
    #[serde(default)] raw_text: String,
    #[serde(default)] biz_id: i64,
}

#[derive(Default, Deserialize)]
struct HonorReplyWire {
    #[serde(default, deserialize_with = "null_as_default")] honor: Vec<HonorEntryWire>,
}

#[derive(Deserialize)]
struct HonorEntryWire {
    #[serde(default, alias = "type")] kind: i32,
    #[serde(default)] desc: String,
}

#[derive(Deserialize)]
struct UgcSeasonWire {
    #[serde(default)] id: i64,
    #[serde(default)] title: String,
    #[serde(default)] cover: String,
    #[serde(default)] mid: i64,
    #[serde(default)] intro: String,
    #[serde(default)] ep_count: i32,
    #[serde(default, deserialize_with = "null_as_default")] sections: Vec<UgcSectionWire>,
}

#[derive(Deserialize)]
struct UgcSectionWire {
    #[serde(default)] id: i64,
    #[serde(default)] title: String,
    #[serde(default, deserialize_with = "null_as_default")] episodes: Vec<UgcEpisodeWire>,
}

#[derive(Deserialize)]
struct UgcEpisodeWire {
    #[serde(default)] id: i64,
    #[serde(default)] aid: i64,
    #[serde(default)] bvid: String,
    #[serde(default)] cid: i64,
    #[serde(default)] title: String,
    #[serde(default)] arc: UgcEpisodeArcWire,
}

#[derive(Default, Deserialize)]
struct UgcEpisodeArcWire {
    #[serde(default)] pic: String,
    #[serde(default)] duration: i64,
}

#[derive(Deserialize)]
struct RelatedItemWire {
    #[serde(default)] aid: i64,
    #[serde(default)] bvid: String,
    #[serde(default)] cid: i64,
    #[serde(default)] title: String,
    #[serde(default)] pic: String,
    #[serde(default)] duration: i64,
    #[serde(default)] pubdate: i64,
    #[serde(default)] owner: ViewOwnerWire,
    #[serde(default)] stat: ViewStatWire,
}

impl Core {
    /// Fetch the full video detail used by the player detail page.
    /// Mirrors `VideoHttp.videoIntro` (`/x/web-interface/wbi/view`).
    pub fn video_view_full(&self, aid: i64, bvid: &str) -> CoreResult<VideoView> {
        let key = self.fetch_wbi_key()?;
        let params = video_lookup_params(aid, bvid)?;
        let raw: ViewFullRoot = self.http.get_signed_web(URL_VIEW_FULL, params, &key)?;
        let tags = self.video_tags(raw.aid).unwrap_or_default();
        Ok(map_view_full(raw, tags))
    }

    /// Companion endpoint that returns the user-visible tag list. We
    /// fetch it lazily and tolerate failures (returning an empty list).
    fn video_tags(&self, aid: i64) -> CoreResult<Vec<String>> {
        const URL_TAG: &str = "https://api.bilibili.com/x/tag/archive/tags";
        if aid <= 0 { return Ok(Vec::new()); }
        #[derive(Deserialize)]
        struct TagItem { #[serde(default)] tag_name: String }
        let items: Vec<TagItem> = self.http.get_web(URL_TAG, &[("aid".to_string(), aid.to_string())])?;
        Ok(items.into_iter().map(|t| t.tag_name).filter(|s| !s.is_empty()).collect())
    }

    /// Mirrors `Api.relatedList` — list of related videos shown on the
    /// detail page "相关视频" tab.
    pub fn video_related(&self, aid: i64, bvid: &str) -> CoreResult<Vec<RelatedVideoItem>> {
        let params = video_lookup_params(aid, bvid)?;
        let raw: Vec<RelatedItemWire> = self.http.get_web(
            URL_RELATED,
            &params,
        )?;
        Ok(raw.into_iter().map(map_related_item).collect())
    }
}

fn map_view_full(r: ViewFullRoot, tags: Vec<String>) -> VideoView {
    VideoView {
        aid: r.aid,
        bvid: r.bvid,
        cid: r.cid,
        title: r.title,
        cover: r.cover,
        desc: r.desc,
        desc_v2: r.desc_v2.into_iter().map(|n| VideoDescNode {
            kind: n.kind,
            raw_text: n.raw_text,
            biz_id: n.biz_id,
        }).collect(),
        duration_sec: r.duration,
        pubdate: r.pubdate,
        ctime: r.ctime,
        videos: r.videos,
        stat: VideoStat {
            view: r.stat.view,
            danmaku: r.stat.danmaku,
            reply: r.stat.reply,
            favorite: r.stat.favorite,
            coin: r.stat.coin,
            share: r.stat.share,
            like: r.stat.like,
        },
        owner: VideoOwner {
            mid: r.owner.mid,
            name: r.owner.name,
            face: r.owner.face,
        },
        pages: r.pages.into_iter().map(|p| VideoPage {
            cid: p.cid,
            page: p.page,
            part: p.part,
            duration_sec: p.duration,
            first_frame: p.first_frame,
        }).collect(),
        tags,
        honor: r.honor_reply.honor.into_iter()
            .map(|h| VideoHonor { kind: h.kind, desc: h.desc })
            .collect(),
        ugc_season: r.ugc_season.map(|s| UgcSeason {
            id: s.id,
            title: s.title,
            cover: s.cover,
            mid: s.mid,
            intro: s.intro,
            ep_count: s.ep_count,
            sections: s.sections.into_iter().map(|sec| UgcSeasonSection {
                id: sec.id,
                title: sec.title,
                episodes: sec.episodes.into_iter().map(|ep| UgcSeasonEpisode {
                    id: ep.id,
                    aid: ep.aid,
                    bvid: ep.bvid,
                    cid: ep.cid,
                    title: ep.title,
                    cover: ep.arc.pic,
                    duration_sec: ep.arc.duration,
                }).collect(),
            }).collect(),
        }),
        redirect_url: r.redirect_url,
    }
}

fn map_related_item(r: RelatedItemWire) -> RelatedVideoItem {
    RelatedVideoItem {
        aid: r.aid,
        bvid: r.bvid,
        cid: r.cid,
        title: r.title,
        cover: r.pic,
        author: r.owner.name,
        face: r.owner.face,
        mid: r.owner.mid,
        duration_sec: r.duration,
        play: r.stat.view,
        danmaku: r.stat.danmaku,
        pubdate: r.pubdate,
    }
}

#[cfg(test)]
mod tests {
    use super::{DashAudio, DashVideo};

    #[test]
    fn dash_video_accepts_snake_and_camel_fields_together() {
        let video: DashVideo = serde_json::from_str(r#"{
            "id": 112,
            "baseUrl": "https://example.com/camel.mp4",
            "base_url": "https://example.com/snake.mp4",
            "backupUrl": ["https://example.com/camel-backup.mp4"],
            "backup_url": ["https://example.com/snake-backup.mp4"],
            "codecs": "avc1.640032",
            "bandWidth": 1000,
            "bandwidth": 2000
        }"#).expect("dash video should deserialize");

        assert_eq!(video.id, 112);
        assert_eq!(video.base_url, "https://example.com/snake.mp4");
        assert_eq!(video.backup_url, vec!["https://example.com/snake-backup.mp4"]);
        assert_eq!(video.bandwidth, 2000);
    }

    #[test]
    fn dash_audio_accepts_camel_only_fields() {
        let audio: DashAudio = serde_json::from_str(r#"{
            "id": 30280,
            "baseUrl": "https://example.com/audio.m4s",
            "backupUrl": ["https://example.com/audio-backup.m4s"],
            "codecs": "mp4a.40.2",
            "bandWidth": 192000
        }"#).expect("dash audio should deserialize");

        assert_eq!(audio.id, 30280);
        assert_eq!(audio.base_url, "https://example.com/audio.m4s");
        assert_eq!(audio.backup_url, vec!["https://example.com/audio-backup.m4s"]);
        assert_eq!(audio.bandwidth, 192000);
    }
}
