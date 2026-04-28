use crate::Core;
use crate::dto::{FeedItem, FeedPage};
use crate::error::{CoreError, CoreResult};
use serde::Deserialize;

const URL_FEED_INDEX: &str = "https://app.bilibili.com/x/v2/feed/index";
/// `Constants.statistics` from upstream PiliPlus.
const STATISTICS: &str = r#"{"appId":5,"platform":3,"version":"2.0.1","abtest":""}"#;

#[derive(Deserialize)]
struct FeedRoot {
    #[serde(default)]
    items: Vec<FeedRawItem>,
}

#[derive(Deserialize)]
struct FeedRawItem {
    #[serde(default)] card_goto: String,
    #[serde(default)] goto: String,
    #[serde(default)] bvid: String,
    #[serde(default)] title: String,
    #[serde(default)] cover: String,
    #[serde(default)] cover_left_text_1: String,
    #[serde(default)] cover_left_text_2: String,
    #[serde(default)] args: FeedArgs,
    #[serde(default)] mask: Option<MaskWrap>,
    #[serde(default)] player_args: Option<PlayerArgs>,
    #[serde(default)] ad_info: Option<serde_json::Value>,
}

#[derive(Deserialize, Default)]
struct FeedArgs {
    #[serde(default)] up_name: String,
}

#[derive(Deserialize, Default)]
struct MaskWrap {
    #[serde(default)] avatar: Option<Avatar>,
}
#[derive(Deserialize, Default)]
struct Avatar { #[serde(default)] text: String }

#[derive(Deserialize, Default)]
struct PlayerArgs {
    #[serde(default)] aid: i64,
    #[serde(default)] cid: i64,
    #[serde(default)] duration: i64,
}

fn parse_stat_text(raw: &str) -> i64 {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed == "-" {
        return 0;
    }

    let mut numeric = String::new();
    let mut unit = None;
    for ch in trimmed.chars() {
        if ch.is_ascii_digit() || ch == '.' {
            numeric.push(ch);
            continue;
        }
        if matches!(ch, '千' | '万' | '亿') {
            unit = Some(ch);
        }
        if !numeric.is_empty() {
            break;
        }
    }

    let Ok(base) = numeric.parse::<f64>() else {
        return 0;
    };
    let multiplier = match unit {
        Some('千') => 1_000.0,
        Some('万') => 10_000.0,
        Some('亿') => 100_000_000.0,
        _ => 1.0,
    };
    (base * multiplier) as i64
}

impl Core {
    /// Mirrors `VideoHttp.rcmdVideoListApp` from upstream PiliPlus
    /// (`lib/http/video.dart`).
    pub fn feed_home(&self, fresh_idx: i64, _ps: i64) -> CoreResult<FeedPage> {
        let access_key = self.session.read().access_key()
            .ok_or(CoreError::AuthRequired)?;
        let pull = if fresh_idx == 0 { "true" } else { "false" };
        let params = vec![
            ("access_key".into(), access_key),
            ("build".into(), "2001100".into()),
            ("c_locale".into(), "zh_CN".into()),
            ("channel".into(), "master".into()),
            ("column".into(), "4".into()),
            ("device".into(), "pad".into()),
            ("device_name".into(), "android".into()),
            ("device_type".into(), "0".into()),
            ("disable_rcmd".into(), "0".into()),
            ("flush".into(), "5".into()),
            ("fnval".into(), "976".into()),
            ("fnver".into(), "0".into()),
            ("force_host".into(), "2".into()),
            ("fourk".into(), "1".into()),
            ("guidance".into(), "0".into()),
            ("https_url_req".into(), "0".into()),
            ("idx".into(), fresh_idx.to_string()),
            ("mobi_app".into(), "android_hd".into()),
            ("network".into(), "wifi".into()),
            ("platform".into(), "android".into()),
            ("player_net".into(), "1".into()),
            ("pull".into(), pull.into()),
            ("qn".into(), "32".into()),
            ("recsys_mode".into(), "0".into()),
            ("s_locale".into(), "zh_CN".into()),
            ("splash_id".into(), "".into()),
            ("statistics".into(), STATISTICS.into()),
            ("voice_balance".into(), "0".into()),
        ];
        let raw: FeedRoot = self.http.get_signed_app(URL_FEED_INDEX, params)?;
        let items = raw.items.into_iter()
            // Match PiliPlus filtering: drop ads + non-video cards.
            .filter(|i| i.ad_info.is_none())
            .filter(|i| !matches!(i.card_goto.as_str(), "ad_av" | "ad_web_s" | "ad" | "banner"))
            .filter(|i| matches!(i.goto.as_str(), "av" | "bangumi") || i.card_goto == "av")
            .filter_map(|i| {
                let pa = i.player_args.as_ref()?;
                if pa.aid == 0 { return None; }
                Some(FeedItem {
                    aid: pa.aid,
                    bvid: i.bvid,
                    cid: pa.cid,
                    title: i.title,
                    cover: i.cover,
                    author: i.mask.as_ref().and_then(|m| m.avatar.as_ref()).map(|a| a.text.clone())
                        .unwrap_or_else(|| i.args.up_name.clone()),
                    duration_sec: pa.duration,
                    play: parse_stat_text(&i.cover_left_text_1),
                    danmaku: parse_stat_text(&i.cover_left_text_2),
                })
            })
            .collect();
        Ok(FeedPage { items })
    }
}
