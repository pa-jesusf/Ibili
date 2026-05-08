use crate::Core;
use crate::dto::{FeedItem, FeedPage};
use crate::error::{CoreError, CoreResult};
use crate::signer::WbiKey;
use serde::Deserialize;

const URL_FEED_INDEX: &str = "https://app.bilibili.com/x/v2/feed/index";
const URL_FEED_RCMD_WEB: &str = "https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd";
const URL_FEED_POPULAR: &str = "https://api.bilibili.com/x/web-interface/popular";
const URL_NAV: &str = "https://api.bilibili.com/x/web-interface/nav";
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
    /// Unix seconds. Some recommendation card variants include this;
    /// when absent we fall back to 0 and the iOS layer just hides the
    /// "投稿时间" line.
    #[serde(default)] pubdate: i64,
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

#[derive(Deserialize)]
struct WebFeedRoot {
    #[serde(default)]
    item: Vec<WebFeedRawItem>,
}

#[derive(Deserialize)]
struct WebFeedRawItem {
    #[serde(default)] id: i64,
    #[serde(default)] bvid: String,
    #[serde(default)] cid: i64,
    #[serde(default)] goto: String,
    #[serde(default)] pic: String,
    #[serde(default)] title: String,
    #[serde(default)] duration: i64,
    #[serde(default)] pubdate: i64,
    #[serde(default)] owner: Option<WebFeedOwner>,
    #[serde(default)] stat: WebFeedStat,
}

#[derive(Deserialize, Default)]
struct WebFeedOwner {
    #[serde(default)]
    name: String,
}

#[derive(Deserialize, Default)]
struct WebFeedStat {
    #[serde(default)]
    view: i64,
    #[serde(default)]
    danmaku: i64,
}

#[derive(Deserialize)]
struct PopularRoot {
    #[serde(default)]
    list: Vec<PopularRawItem>,
}

#[derive(Deserialize)]
struct PopularRawItem {
    #[serde(default)] aid: i64,
    #[serde(default)] cid: i64,
    #[serde(default)] bvid: String,
    #[serde(default)] title: String,
    #[serde(default)] pic: String,
    #[serde(default)] duration: i64,
    #[serde(default)] pubdate: i64,
    #[serde(default)] owner: PopularOwner,
    #[serde(default)] stat: PopularStat,
}

#[derive(Deserialize, Default)]
struct PopularOwner {
    #[serde(default)]
    name: String,
}

#[derive(Deserialize, Default)]
struct PopularStat {
    #[serde(default)]
    view: i64,
    #[serde(default)]
    danmaku: i64,
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

#[derive(Deserialize)]
struct NavData {
    wbi_img: NavWbiImage,
}

#[derive(Deserialize)]
struct NavWbiImage {
    img_url: String,
    sub_url: String,
}

/// Bilibili sometimes returns covers as `//i0.hdslb.com/...` (scheme-relative)
/// or with `http://`; force HTTPS so the iOS image loader stays on ATS-safe URLs.
fn ensure_https(raw: String) -> String {
    if raw.starts_with("//") {
        format!("https:{}", raw)
    } else if let Some(rest) = raw.strip_prefix("http://") {
        format!("https://{}", rest)
    } else {
        raw
    }
}

impl Core {
    /// Default to upstream PiliPlus's web recommendation path
    /// (`VideoHttp.rcmdVideoList`).
    pub fn feed_home(&self, fresh_idx: i64, ps: i64) -> CoreResult<FeedPage> {
        self.feed_home_with_source(fresh_idx, ps, "web")
    }

    pub fn feed_home_with_source(&self, fresh_idx: i64, ps: i64, source: &str) -> CoreResult<FeedPage> {
        match source {
            "app" => self.feed_home_app(fresh_idx, ps),
            _ => self.feed_home_web(fresh_idx, ps),
        }
    }

    /// Mirrors `VideoHttp.rcmdVideoList` from upstream PiliPlus
    /// (`/x/web-interface/wbi/index/top/feed/rcmd`).
    fn feed_home_web(&self, fresh_idx: i64, ps: i64) -> CoreResult<FeedPage> {
        let key = self.fetch_wbi_key_for_feed()?;
        let fresh_idx = fresh_idx.max(0);
        let ps = ps.max(1);
        let params = vec![
            ("version".into(), "1".into()),
            ("feed_version".into(), "V8".into()),
            ("homepage_ver".into(), "1".into()),
            ("ps".into(), ps.to_string()),
            ("fresh_idx".into(), fresh_idx.to_string()),
            ("brush".into(), fresh_idx.to_string()),
            ("fresh_type".into(), "4".into()),
        ];
        let raw: WebFeedRoot = self.http.get_signed_web(URL_FEED_RCMD_WEB, params, &key)?;
        let items = raw.item.into_iter()
            .filter(|i| i.goto == "av")
            .filter(|i| i.id != 0)
            .map(|i| {
                let author = i.owner.map(|owner| owner.name).unwrap_or_default();
                FeedItem {
                    aid: i.id,
                    bvid: i.bvid,
                    cid: i.cid,
                    title: i.title,
                    cover: ensure_https(i.pic),
                    author,
                    duration_sec: i.duration,
                    play: i.stat.view,
                    danmaku: i.stat.danmaku,
                    pubdate: i.pubdate,
                }
            })
            .collect();
        Ok(FeedPage { items })
    }

    /// Mirrors `VideoHttp.rcmdVideoListApp` from upstream PiliPlus
    /// (`/x/v2/feed/index`).
    fn feed_home_app(&self, fresh_idx: i64, _ps: i64) -> CoreResult<FeedPage> {
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
                    pubdate: i.args.pubdate,
                })
            })
            .collect();
        Ok(FeedPage { items })
    }

    fn fetch_wbi_key_for_feed(&self) -> CoreResult<WbiKey> {
        let nav: NavData = self.http.get_web(URL_NAV, &[])?;
        Ok(WbiKey::from_urls(&nav.wbi_img.img_url, &nav.wbi_img.sub_url))
    }

    /// Mirrors PiliPlus `VideoHttp.hotVideoList`
    /// (`lib/http/video.dart`) against `/x/web-interface/popular`.
    pub fn feed_popular(&self, pn: i64, ps: i64) -> CoreResult<FeedPage> {
        let params = vec![
            ("pn".into(), pn.max(1).to_string()),
            ("ps".into(), ps.max(1).to_string()),
        ];
        let raw: PopularRoot = self.http.get_web(URL_FEED_POPULAR, &params)?;
        let items = raw.list.into_iter()
            .filter(|item| item.aid != 0)
            .map(|item| FeedItem {
                aid: item.aid,
                bvid: item.bvid,
                cid: item.cid,
                title: item.title,
                cover: item.pic,
                author: item.owner.name,
                duration_sec: item.duration,
                play: item.stat.view,
                danmaku: item.stat.danmaku,
                pubdate: item.pubdate,
            })
            .collect();
        Ok(FeedPage { items })
    }
}
