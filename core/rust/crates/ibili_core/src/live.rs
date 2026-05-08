//! Live room APIs. First version focuses on readable live cards and
//! HLS playback URLs that AVPlayer can consume directly.

use serde::Deserialize;

use crate::Core;
use crate::dto::{
    LiveDanmakuHistory, LiveDanmakuHost, LiveDanmakuInfo, LiveDanmakuMessage, LiveFeedItem,
    LiveFeedPage, LivePlayUrl, LiveQuality, LiveRoomInfo,
};
use crate::error::{CoreError, CoreResult};
use crate::signer::WbiKey;

const URL_LIVE_FEED: &str = "https://api.live.bilibili.com/xlive/app-interface/v2/index/feed";
const URL_LIVE_PLAY_INFO: &str = "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo";
const URL_LIVE_INFO_H5: &str = "https://api.live.bilibili.com/xlive/web-room/v1/index/getH5InfoByRoom";
const URL_LIVE_DM_INFO: &str = "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo";
const URL_LIVE_DM_HISTORY: &str = "https://api.live.bilibili.com/xlive/web-room/v1/dM/gethistory";
const URL_SEND_LIVE_MSG: &str = "https://api.live.bilibili.com/msg/send";
const URL_NAV: &str = "https://api.bilibili.com/x/web-interface/nav";
const STATISTICS_APP: &str = r#"{"appId":1,"platform":3,"version":"8.43.0","abtest":""}"#;

#[derive(Deserialize)]
struct NavData {
    wbi_img: NavWbiImage,
}

#[derive(Deserialize)]
struct NavWbiImage {
    img_url: String,
    sub_url: String,
}

#[derive(Default, Deserialize)]
struct LiveFeedWire {
    #[serde(default)] card_list: Vec<LiveCardListWire>,
    #[serde(default)] has_more: i64,
}

#[derive(Default, Deserialize)]
struct LiveCardListWire {
    #[serde(default)] card_type: String,
    #[serde(default)] card_data: Option<LiveCardDataWire>,
}

#[derive(Default, Deserialize)]
struct LiveCardDataWire {
    #[serde(default)] small_card_v1: Option<LiveFeedItemWire>,
}

#[derive(Default, Deserialize)]
struct LiveFeedItemWire {
    #[serde(default)] roomid: Option<i64>,
    #[serde(default)] id: Option<i64>,
    #[serde(default)] uid: Option<i64>,
    #[serde(default)] uname: Option<String>,
    #[serde(default)] face: Option<String>,
    #[serde(default)] cover: Option<String>,
    #[serde(default)] system_cover: Option<String>,
    #[serde(default)] title: Option<String>,
    #[serde(default)] area_name: Option<String>,
    #[serde(default)] watched_show: Option<WatchedShowWire>,
}

#[derive(Default, Deserialize, Clone)]
struct WatchedShowWire {
    #[serde(default)] text_large: Option<String>,
}

#[derive(Default, Deserialize)]
struct RoomInfoH5Wire {
    #[serde(default)] room_info: Option<RoomInfoWire>,
    #[serde(default)] anchor_info: Option<AnchorInfoWire>,
    #[serde(default)] watched_show: Option<WatchedShowWire>,
}

#[derive(Default, Deserialize)]
struct RoomInfoWire {
    #[serde(default)] room_id: Option<i64>,
    #[serde(default)] uid: Option<i64>,
    #[serde(default)] title: Option<String>,
    #[serde(default)] cover: Option<String>,
    #[serde(default)] live_status: Option<i64>,
    #[serde(default)] live_time: Option<i64>,
}

#[derive(Default, Deserialize)]
struct AnchorInfoWire {
    #[serde(default)] base_info: Option<AnchorBaseInfoWire>,
}

#[derive(Default, Deserialize)]
struct AnchorBaseInfoWire {
    #[serde(default)] uname: Option<String>,
    #[serde(default)] face: Option<String>,
}

#[derive(Default, Deserialize)]
struct RoomPlayInfoWire {
    #[serde(default)] live_status: i64,
    #[serde(default)] playurl_info: Option<PlayurlInfoWire>,
}

#[derive(Default, Deserialize)]
struct PlayurlInfoWire {
    #[serde(default)] playurl: Option<PlayurlWire>,
}

#[derive(Default, Deserialize)]
struct PlayurlWire {
    #[serde(default)] stream: Vec<LiveStreamWire>,
}

#[derive(Default, Deserialize)]
struct LiveStreamWire {
    #[serde(default)] protocol_name: String,
    #[serde(default)] format: Vec<LiveFormatWire>,
}

#[derive(Default, Deserialize)]
struct LiveFormatWire {
    #[serde(default)] format_name: String,
    #[serde(default)] codec: Vec<LiveCodecWire>,
}

#[derive(Default, Deserialize)]
struct LiveCodecWire {
    #[serde(default)] codec_name: String,
    #[serde(default)] current_qn: i64,
    #[serde(default)] accept_qn: Vec<i64>,
    #[serde(default)] base_url: String,
    #[serde(default)] url_info: Vec<LiveUrlInfoWire>,
}

#[derive(Default, Deserialize)]
struct LiveUrlInfoWire {
    #[serde(default)] host: String,
    #[serde(default)] extra: String,
}

#[derive(Default, Deserialize)]
struct LiveDanmakuInfoWire {
    #[serde(default)] token: String,
    #[serde(default)] host_list: Vec<LiveDanmakuHostWire>,
}

#[derive(Default, Deserialize)]
struct LiveDanmakuHostWire {
    #[serde(default)] host: String,
    #[serde(default)] port: i64,
    #[serde(default)] ws_port: i64,
    #[serde(default)] wss_port: i64,
}

#[derive(Default, Deserialize)]
struct LiveDanmakuHistoryWire {
    #[serde(default)] room: Vec<LiveHistoryDanmakuWire>,
}

#[derive(Default, Deserialize)]
struct LiveHistoryDanmakuWire {
    #[serde(default, deserialize_with = "lenient_string")] id_str: Option<String>,
    #[serde(default, deserialize_with = "lenient_i64")] id: Option<i64>,
    #[serde(default, deserialize_with = "lenient_string")] text: Option<String>,
    #[serde(default)] user: Option<LiveHistoryUserWire>,
}

#[derive(Default, Deserialize)]
struct LiveHistoryUserWire {
    #[serde(default, deserialize_with = "lenient_i64")] uid: Option<i64>,
    #[serde(default)] base: Option<LiveHistoryUserBaseWire>,
}

#[derive(Default, Deserialize)]
struct LiveHistoryUserBaseWire {
    #[serde(default, deserialize_with = "lenient_string")] name: Option<String>,
}

impl Core {
    pub fn live_feed(&self, page: i64) -> CoreResult<LiveFeedPage> {
        let access_key = self.session.read().access_key();
        let mut params = vec![
            ("channel".into(), "master".into()),
            ("actionKey".into(), "appkey".into()),
            ("build".into(), "8430300".into()),
            ("version".into(), "8.43.0".into()),
            ("c_locale".into(), "zh_CN".into()),
            ("device".into(), "android".into()),
            ("device_name".into(), "android".into()),
            ("device_type".into(), "0".into()),
            ("fnval".into(), "912".into()),
            ("disable_rcmd".into(), "0".into()),
            ("https_url_req".into(), "1".into()),
            ("mobi_app".into(), "android".into()),
            ("network".into(), "wifi".into()),
            ("page".into(), page.max(1).to_string()),
            ("platform".into(), "android".into()),
            ("s_locale".into(), "zh_CN".into()),
            ("scale".into(), "2".into()),
            ("statistics".into(), STATISTICS_APP.into()),
        ];
        if let Some(access_key) = access_key {
            params.push(("access_key".into(), access_key));
            params.push(("relation_page".into(), "1".into()));
        }
        let raw: LiveFeedWire = self.http.get_signed_android_app(URL_LIVE_FEED, params)?;
        let items = raw.card_list.into_iter()
            .filter(|card| card.card_type == "small_card_v1")
            .filter_map(|card| card.card_data.and_then(|d| d.small_card_v1))
            .filter_map(live_feed_item_from_wire)
            .collect();
        Ok(LiveFeedPage {
            items,
            has_more: raw.has_more != 0,
        })
    }

    pub fn live_room_info(&self, room_id: i64) -> CoreResult<LiveRoomInfo> {
        if room_id <= 0 {
            return Err(CoreError::InvalidArgument("room_id required".into()));
        }
        let params = vec![("room_id".into(), room_id.to_string())];
        let raw: RoomInfoH5Wire = self.http.get_web(URL_LIVE_INFO_H5, &params)?;
        Ok(live_room_info_from_wire(room_id, raw))
    }

    pub fn live_playurl(&self, room_id: i64, qn: i64) -> CoreResult<LivePlayUrl> {
        if room_id <= 0 {
            return Err(CoreError::InvalidArgument("room_id required".into()));
        }
        let key = self.fetch_wbi_key_for_live()?;
        let requested_qn = if qn > 0 { qn } else { 10_000 };
        let params = vec![
            ("room_id".into(), room_id.to_string()),
            ("protocol".into(), "0,1".into()),
            ("format".into(), "0,1,2".into()),
            ("codec".into(), "0,1,2".into()),
            ("qn".into(), requested_qn.to_string()),
            ("platform".into(), "web".into()),
            ("ptype".into(), "8".into()),
            ("dolby".into(), "5".into()),
            ("panorama".into(), "1".into()),
            ("web_location".into(), "444.8".into()),
        ];
        let raw: RoomPlayInfoWire = self.http.get_signed_web_with_headers(
            URL_LIVE_PLAY_INFO,
            params,
            &key,
            &[("Referer", format!("https://live.bilibili.com/{room_id}"))],
        )?;
        if raw.live_status != 1 {
            return Err(CoreError::Api { code: -404, msg: "当前直播间未开播".into() });
        }
        select_hls_playurl(raw)
    }

    pub fn live_danmaku_info(&self, room_id: i64) -> CoreResult<LiveDanmakuInfo> {
        if room_id <= 0 {
            return Err(CoreError::InvalidArgument("room_id required".into()));
        }
        let key = self.fetch_wbi_key_for_live()?;
        let raw: LiveDanmakuInfoWire = self.http.get_signed_web_with_headers(
            URL_LIVE_DM_INFO,
            vec![
                ("id".into(), room_id.to_string()),
                ("web_location".into(), "444.8".into()),
            ],
            &key,
            &[("Referer", format!("https://live.bilibili.com/{room_id}"))],
        )?;
        Ok(LiveDanmakuInfo {
            token: raw.token,
            host_list: raw.host_list
                .into_iter()
                .filter(|h| !h.host.is_empty())
                .map(|h| LiveDanmakuHost {
                    host: h.host,
                    port: h.port,
                    ws_port: h.ws_port,
                    wss_port: h.wss_port,
                })
                .collect(),
        })
    }

    pub fn live_danmaku_history(&self, room_id: i64) -> CoreResult<LiveDanmakuHistory> {
        if room_id <= 0 {
            return Err(CoreError::InvalidArgument("room_id required".into()));
        }
        let raw: LiveDanmakuHistoryWire = self.http.get_web_with_headers(
            URL_LIVE_DM_HISTORY,
            &[("roomid".into(), room_id.to_string())],
            &[("Referer", format!("https://live.bilibili.com/{room_id}"))],
        )?;
        let self_mid = self.session.read().snapshot().mid;
        let mut items = Vec::with_capacity(raw.room.len());
        for (idx, item) in raw.room.into_iter().enumerate() {
            let text = item.text.unwrap_or_default().trim().to_string();
            if text.is_empty() {
                continue;
            }
            let user = item.user.unwrap_or_default();
            let uid = user.uid.unwrap_or(0);
            let name = user
                .base
                .and_then(|base| base.name)
                .unwrap_or_default()
                .trim()
                .to_string();
            let id = item
                .id_str
                .filter(|s| !s.is_empty())
                .or_else(|| item.id.filter(|id| *id > 0).map(|id| id.to_string()))
                .unwrap_or_else(|| format!("history-{room_id}-{idx}"));
            items.push(LiveDanmakuMessage {
                id,
                uid,
                name,
                text,
                is_self: self_mid > 0 && uid == self_mid,
            });
        }
        Ok(LiveDanmakuHistory { items })
    }

    pub fn send_live_danmaku(
        &self,
        room_id: i64,
        msg: &str,
        mode: i32,
        color: i32,
        fontsize: i32,
    ) -> CoreResult<()> {
        if room_id <= 0 {
            return Err(CoreError::InvalidArgument("room_id required".into()));
        }
        let trimmed = msg.trim();
        if trimmed.is_empty() {
            return Err(CoreError::InvalidArgument("msg required".into()));
        }
        let csrf = self.http.csrf_token().ok_or(CoreError::AuthRequired)?;
        let key = self.fetch_wbi_key_for_live()?;
        let mut query = vec![("web_location".into(), "444.8".into())];
        crate::signer::WbiSigner::sign(&mut query, &key);
        let rnd = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let params: Vec<(String, String)> = vec![
            ("bubble".into(), "0".into()),
            ("msg".into(), trimmed.to_string()),
            ("color".into(), color.to_string()),
            ("mode".into(), mode.to_string()),
            ("room_type".into(), "0".into()),
            ("jumpfrom".into(), "0".into()),
            ("reply_mid".into(), "0".into()),
            ("reply_attr".into(), "0".into()),
            ("replay_dmid".into(), String::new()),
            ("statistics".into(), r#"{"appId":100,"platform":5}"#.into()),
            ("reply_type".into(), "0".into()),
            ("reply_uname".into(), String::new()),
            ("fontsize".into(), fontsize.to_string()),
            ("rnd".into(), rnd.to_string()),
            ("roomid".into(), room_id.to_string()),
            ("csrf".into(), csrf.clone()),
            ("csrf_token".into(), csrf),
        ];
        let _: serde_json::Value = self.http.post_form_web_with_headers(
            URL_SEND_LIVE_MSG,
            &query,
            &params,
            &[("Referer", format!("https://live.bilibili.com/{room_id}"))],
        )?;
        Ok(())
    }

    fn fetch_wbi_key_for_live(&self) -> CoreResult<WbiKey> {
        let nav: NavData = self.http.get_web(URL_NAV, &[])?;
        Ok(WbiKey::from_urls(&nav.wbi_img.img_url, &nav.wbi_img.sub_url))
    }
}

fn live_feed_item_from_wire(w: LiveFeedItemWire) -> Option<LiveFeedItem> {
    let room_id = w.roomid.or(w.id).unwrap_or(0);
    if room_id <= 0 {
        return None;
    }
    let cover = ensure_https(w.cover.unwrap_or_default());
    let system_cover = ensure_https(w.system_cover.unwrap_or_else(|| cover.clone()));
    Some(LiveFeedItem {
        room_id,
        uid: w.uid.unwrap_or(0),
        title: w.title.unwrap_or_default(),
        cover,
        system_cover,
        uname: w.uname.unwrap_or_default(),
        face: ensure_https(w.face.unwrap_or_default()),
        area_name: w.area_name.unwrap_or_default(),
        watched_label: w.watched_show.and_then(|s| s.text_large).unwrap_or_default(),
    })
}

fn live_room_info_from_wire(room_id: i64, raw: RoomInfoH5Wire) -> LiveRoomInfo {
    let room = raw.room_info.unwrap_or_default();
    let base = raw.anchor_info.and_then(|a| a.base_info).unwrap_or_default();
    LiveRoomInfo {
        room_id: room.room_id.unwrap_or(room_id),
        uid: room.uid.unwrap_or(0),
        title: room.title.unwrap_or_default(),
        cover: ensure_https(room.cover.unwrap_or_default()),
        anchor_name: base.uname.unwrap_or_default(),
        anchor_face: ensure_https(base.face.unwrap_or_default()),
        watched_label: raw.watched_show.and_then(|s| s.text_large).unwrap_or_default(),
        live_status: room.live_status.unwrap_or(0),
        live_time: room.live_time.unwrap_or(0),
    }
}

fn select_hls_playurl(raw: RoomPlayInfoWire) -> CoreResult<LivePlayUrl> {
    let streams = raw.playurl_info
        .and_then(|i| i.playurl)
        .map(|p| p.stream)
        .unwrap_or_default();
    let mut best: Option<(i32, String, i64, Vec<i64>)> = None;
    for stream in streams {
        let protocol_score = match stream.protocol_name.as_str() {
            "http_hls" => 0,
            _ => 50,
        };
        for format in stream.format {
            let format_score = match format.format_name.as_str() {
                "fmp4" => 0,
                "ts" => 1,
                _ => 50,
            };
            for codec in format.codec {
                let codec_score = match codec.codec_name.as_str() {
                    "avc" => 0,
                    "hevc" => 6,
                    _ => 10,
                };
                let Some(url) = codec.url_info.first().map(|u| {
                    let host = if u.host.is_empty() { "" } else { &u.host };
                    format!("{host}{}{}", codec.base_url, u.extra)
                }) else {
                    continue;
                };
                if !is_hls_candidate(&url, protocol_score, format_score) {
                    continue;
                }
                let score = protocol_score + format_score + codec_score;
                let replace = best
                    .as_ref()
                    .map(|(best_score, _, _, _)| score < *best_score)
                    .unwrap_or(true);
                if replace {
                    best = Some((score, ensure_https(url), codec.current_qn, codec.accept_qn));
                }
            }
        }
    }
    let Some((_, url, quality, accept_qn)) = best else {
        return Err(CoreError::Api { code: -415, msg: "暂不支持该直播流格式".into() });
    };
    let accept_quality = accept_qn.into_iter()
        .map(|qn| LiveQuality { qn, label: live_quality_label(qn).into() })
        .collect();
    Ok(LivePlayUrl {
        url,
        quality,
        accept_quality,
        live_status: raw.live_status,
    })
}

fn is_hls_candidate(url: &str, protocol_score: i32, format_score: i32) -> bool {
    protocol_score == 0
        && format_score < 50
        && (url.contains(".m3u8") || url.contains("/hls/") || url.contains("format=ts") || url.contains("format=fmp4"))
}

fn live_quality_label(qn: i64) -> &'static str {
    match qn {
        30_000 => "杜比",
        20_000 => "4K",
        10_000 => "原画",
        400 => "蓝光",
        250 => "超清",
        150 => "高清",
        80 => "流畅",
        _ => "清晰度",
    }
}

fn ensure_https(raw: String) -> String {
    if raw.starts_with("//") {
        format!("https:{}", raw)
    } else if let Some(rest) = raw.strip_prefix("http://") {
        format!("https://{}", rest)
    } else {
        raw
    }
}

fn lenient_string<'de, D>(de: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde_json::Value;
    let v = Option::<Value>::deserialize(de)?;
    Ok(match v {
        Some(Value::String(s)) => Some(s),
        Some(Value::Number(n)) => Some(n.to_string()),
        Some(Value::Bool(b)) => Some(b.to_string()),
        _ => None,
    })
}

fn lenient_i64<'de, D>(de: D) -> Result<Option<i64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde_json::Value;
    let v = Option::<Value>::deserialize(de)?;
    Ok(match v {
        Some(Value::Number(n)) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Some(Value::String(s)) => s.parse().ok(),
        _ => None,
    })
}
