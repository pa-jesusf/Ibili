use crate::Core;
use crate::cdn::{rank_urls, DEFAULT_CDN_HOST};
use crate::dto::PlayUrl;
use crate::error::{CoreError, CoreResult};
use crate::signer::WbiKey;
use serde::{Deserialize, Deserializer};

const URL_PLAYURL_WEB: &str = "https://api.bilibili.com/x/player/wbi/playurl";
const URL_PLAYURL_TV: &str = "https://api.bilibili.com/x/tv/playurl";
const URL_NAV: &str = "https://api.bilibili.com/x/web-interface/nav";

#[derive(Deserialize)]
struct PlayUrlRoot {
    #[serde(default)] quality: i64,
    #[serde(default)] format: String,
    #[serde(default)] timelength: i64,
    #[serde(default, deserialize_with = "null_as_default")] durl: Vec<Durl>,
    #[serde(default, deserialize_with = "null_as_default")] accept_quality: Vec<i64>,
    #[serde(default, deserialize_with = "null_as_default")] accept_description: Vec<String>,
    #[serde(default)] dash: Option<Dash>,
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
        match self.video_playurl_web_with_audio(aid, cid, qn, audio_qn) {
            Ok(play) => Ok(play),
            Err(web_err) => {
                let web_msg = format!("wbi/playurl failed → fell back to tv_durl: {web_err}");
                eprintln!("[ibili_core] {web_msg}");
                match self.video_playurl_tv(aid, cid, qn) {
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

    pub fn video_playurl_tv_compat(&self, aid: i64, cid: i64, qn: i64) -> CoreResult<PlayUrl> {
        self.video_playurl_tv(aid, cid, qn)
    }

    fn video_playurl_web_with_audio(&self, aid: i64, cid: i64, qn: i64, audio_qn: i64) -> CoreResult<PlayUrl> {
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
        build_playurl_from_web_response(response, qn, audio_qn)
    }

    /// Mirrors `VideoHttp.tvPlayUrl` from upstream PiliPlus.
    fn video_playurl_tv(&self, aid: i64, cid: i64, qn: i64) -> CoreResult<PlayUrl> {
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
        Ok(PlayUrl {
            url: first.url,
            audio_url: None,
            format: r.format,
            stream_type: "tv_durl".into(),
            quality: r.quality,
            duration_ms: r.timelength,
            backup_urls: first.backup_url,
            audio_backup_urls: Vec::new(),
            accept_quality,
            accept_description,
            video_codec: String::new(),
            audio_codec: String::new(),
            debug_message: None,
            audio_quality: 0,
            audio_quality_label: String::new(),
            accept_audio_quality: Vec::new(),
            accept_audio_description: Vec::new(),
        })
    }

    fn fetch_wbi_key(&self) -> CoreResult<WbiKey> {
        let nav: NavData = self.http.get_web(URL_NAV, &[])?;
        Ok(WbiKey::from_urls(&nav.wbi_img.img_url, &nav.wbi_img.sub_url))
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

fn build_playurl_from_web_response(response: PlayUrlRoot, requested_qn: i64, audio_qn: i64) -> CoreResult<PlayUrl> {
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
            let video_ranked = rank_urls(&video_candidates, Some(DEFAULT_CDN_HOST), false, false);
            if let Some(video_url) = video_ranked.first().cloned() {
                let video_backups = video_ranked.into_iter().skip(1).collect::<Vec<_>>();
                let video_codec = video.codecs.clone();
                let (audio_url, audio_backups, audio_codec, picked_audio_qn) = match audio {
                    Some(a) => {
                        let candidates = collect_candidates(&a.base_url, &a.backup_url);
                        let ranked = rank_urls(&candidates, Some(DEFAULT_CDN_HOST), true, false);
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
                    debug_message: None,
                    audio_quality: picked_audio_qn,
                    audio_quality_label: audio_quality_label(picked_audio_qn),
                    accept_audio_quality,
                    accept_audio_description,
                });
            }
        }
    }

    let first = response.durl.into_iter().next()
        .ok_or_else(|| CoreError::Decode("missing playable stream".into()))?;
    Ok(PlayUrl {
        url: first.url,
        audio_url: None,
        format: response.format,
        stream_type: "web_durl".into(),
        quality: response.quality,
        duration_ms: response.timelength,
        backup_urls: first.backup_url,
        audio_backup_urls: Vec::new(),
        accept_quality,
        accept_description,
        video_codec: String::new(),
        audio_codec: String::new(),
        debug_message: None,
        audio_quality: 0,
        audio_quality_label: String::new(),
        accept_audio_quality: Vec::new(),
        accept_audio_description: Vec::new(),
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
