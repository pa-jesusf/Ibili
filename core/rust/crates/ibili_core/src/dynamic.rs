//! Dynamic feed (`/x/polymer/web-dynamic/v1/feed/all`). Bilibili's
//! dynamic surface is heterogeneous — videos, image posts, text
//! posts, forwards, anime updates — so we flatten the wire shape
//! into a single tagged DTO and let the iOS layer switch on `kind`.

use serde::{Deserialize, Serialize};

use crate::Core;
use crate::error::{CoreError, CoreResult};

const URL_DYNAMIC_FEED: &str = "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all";
const URL_SPACE_DYN_FEED: &str = "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space";
const URL_DYNAMIC_THUMB: &str = "https://api.bilibili.com/x/dynamic/feed/dyn/thumb";

// MARK: - Public DTOs

/// Discriminator for dynamic items. Anything we don't recognise is
/// surfaced as `unsupported` and the iOS layer renders a "暂不支持
/// 此类动态" placeholder rather than dropping the row entirely
/// (which would break the chronological flow).
#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "snake_case")]
pub enum DynamicKind {
    /// 视频投稿
    Video,
    /// 图文（pictures + text）
    Draw,
    /// 纯文字
    Word,
    /// 转发
    Forward,
    /// 番剧 / 影视更新
    Pgc,
    /// 文章 / 长图文 (opus)
    Article,
    /// 直播
    Live,
    Unsupported,
}

#[derive(Debug, Serialize, Clone)]
pub struct DynamicAuthor {
    pub mid: i64,
    pub name: String,
    pub face: String,
    /// "5 分钟前", "今天 12:34" etc.
    pub pub_label: String,
    pub pub_ts: i64,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct DynamicStat {
    pub like: i64,
    pub comment: i64,
    pub forward: i64,
}

/// Embedded video card (used for both standalone video dynamics and
/// when a forward wraps a video).
#[derive(Debug, Serialize, Clone)]
pub struct DynamicVideo {
    pub aid: i64,
    pub bvid: String,
    pub title: String,
    pub cover: String,
    pub duration_label: String,
    pub stat_label: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct DynamicLive {
    pub room_id: i64,
    pub title: String,
    pub cover: String,
    pub area_name: String,
    pub watched_label: String,
    pub live_status: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct DynamicImage {
    pub url: String,
    pub width: i64,
    pub height: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct DynamicItem {
    pub id_str: String,
    pub kind: DynamicKind,
    pub author: DynamicAuthor,
    pub stat: DynamicStat,
    /// Body text. For video / pgc dynamics the upstream "desc" is
    /// usually empty and we lean on the embedded card's title.
    #[serde(default)]
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video: Option<DynamicVideo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub live: Option<DynamicLive>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<DynamicImage>,
    /// `oid` to pass to the comment API for this dynamic. Comes from
    /// `basic.comment_id_str` on the wire. Zero for items where the
    /// upstream didn't surface a comment thread (rare).
    pub comment_id: i64,
    /// `type` arg for the comment API — 11 for image / draw posts,
    /// 17 for word / forward posts, 1 for embedded video archives, etc.
    /// Mirrors `basic.comment_type` from the wire.
    pub comment_type: i32,
    /// For forwards: the original item the user is forwarding.
    /// Boxed to keep the recursive type sized. We only carry one
    /// level of nesting — Bilibili's API doesn't really nest deeper
    /// than that in practice (a forward of a forward shows only the
    /// most recent forward's text + the deepest non-forward item).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub orig: Option<Box<DynamicItem>>,
}

#[derive(Debug, Serialize, Clone)]
pub struct DynamicFeedPage {
    pub items: Vec<DynamicItem>,
    pub offset: String,
    pub has_more: bool,
    pub update_baseline: String,
    pub update_num: i64,
}

// MARK: - Implementation

impl Core {
    /// Fetch one page of the unified dynamic feed.
    /// `feed_type` mirrors PiliPlus: "all" | "video" | "pgc" | "article".
    /// `offset` is empty on the first call; subsequent calls pass the
    /// `offset` returned in the previous page.
    pub fn dynamic_feed(&self, feed_type: &str, page: i64, offset: &str) -> CoreResult<DynamicFeedPage> {
        if self.session.read().access_key().is_none() {
            return Ok(DynamicFeedPage {
                items: vec![],
                offset: String::new(),
                has_more: false,
                update_baseline: String::new(),
                update_num: 0,
            });
        }
        let kind = match feed_type {
            "video" | "pgc" | "article" => feed_type,
            _ => "all",
        };
        let params: Vec<(String, String)> = vec![
            ("timezone_offset".into(), "-480".into()),
            ("type".into(), kind.into()),
            ("page".into(), page.max(1).to_string()),
            ("offset".into(), offset.into()),
            ("features".into(), "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote,decorationCard,onlyfansAssetsV2,ugcDelete,onlyfansQaCard,editable".into()),
            ("web_location".into(), "333.1365".into()),
        ];
        let raw: DynamicFeedWire = self.http.get_web(URL_DYNAMIC_FEED, &params)?;
        let items = raw.items.into_iter()
            .filter_map(|w| flatten_dynamic_item(w))
            .collect();
        Ok(DynamicFeedPage {
            items,
            offset: raw.offset.unwrap_or_default(),
            has_more: raw.has_more.unwrap_or(false),
            update_baseline: raw.update_baseline.unwrap_or_default(),
            update_num: raw.update_num.unwrap_or(0),
        })
    }

    /// Per-user dynamic feed (个人空间 动态 页签). Returns the same
    /// flattened DTOs as `dynamic_feed`. `offset` is empty on first
    /// call and propagated from the previous response on subsequent
    /// pages — mirrors PiliPlus.
    pub fn space_dynamic_feed(&self, host_mid: i64, offset: &str) -> CoreResult<DynamicFeedPage> {
        let params: Vec<(String, String)> = vec![
            ("timezone_offset".into(), "-480".into()),
            ("host_mid".into(), host_mid.to_string()),
            ("offset".into(), offset.into()),
            ("features".into(), "itemOpusStyle,opusBigCover,onlyfansVote,onlyfansAssetsV2,decorationCard".into()),
            ("web_location".into(), "333.999".into()),
        ];
        let raw: DynamicFeedWire = self.http.get_web(URL_SPACE_DYN_FEED, &params)?;
        let items = raw.items.into_iter()
            .filter_map(|w| flatten_dynamic_item(w))
            .collect();
        Ok(DynamicFeedPage {
            items,
            offset: raw.offset.unwrap_or_default(),
            has_more: raw.has_more.unwrap_or(false),
            update_baseline: raw.update_baseline.unwrap_or_default(),
            update_num: raw.update_num.unwrap_or(0),
        })
    }

    /// Like / un-like a dynamic. `action` is 1 (点赞) or 2 (取消).
    /// Mirrors `/x/dynamic/feed/dyn/thumb` with `up=1|2`.
    pub fn dynamic_like(&self, dynamic_id: &str, action: i32) -> CoreResult<()> {
        let csrf = self.http.csrf_token().ok_or(CoreError::AuthRequired)?;
        let up = if action == 2 { "2" } else { "1" };
        // Bilibili keeps `csrf` on the query string and the rest in
        // the form body for this endpoint. Our `post_form_web`
        // helper concatenates everything into the body — that works
        // here too because the server tolerates a body-side csrf.
        let params: Vec<(String, String)> = vec![
            ("dyn_id_str".into(), dynamic_id.to_string()),
            ("up".into(), up.into()),
            ("spmid".into(), "333.1365.0.0".into()),
            ("csrf".into(), csrf),
        ];
        let _: serde_json::Value = self.http.post_form_web(URL_DYNAMIC_THUMB, &params)?;
        Ok(())
    }
}

fn flatten_dynamic_item(w: DynItemWire) -> Option<DynamicItem> {
    let modules = w.modules?;
    let author_mod = modules.module_author.unwrap_or_default();
    let dynamic_mod = modules.module_dynamic.unwrap_or_default();
    let stat_mod = modules.module_stat.unwrap_or_default();

    let kind = match w.kind.as_deref() {
        Some("DYNAMIC_TYPE_AV") => DynamicKind::Video,
        Some("DYNAMIC_TYPE_DRAW") => DynamicKind::Draw,
        Some("DYNAMIC_TYPE_WORD") => DynamicKind::Word,
        Some("DYNAMIC_TYPE_FORWARD") => DynamicKind::Forward,
        Some("DYNAMIC_TYPE_PGC") | Some("DYNAMIC_TYPE_PGC_UNION") => DynamicKind::Pgc,
        Some("DYNAMIC_TYPE_ARTICLE") => DynamicKind::Article,
        Some("DYNAMIC_TYPE_LIVE") | Some("DYNAMIC_TYPE_LIVE_RCMD") => DynamicKind::Live,
        _ => DynamicKind::Unsupported,
    };

    let author = DynamicAuthor {
        mid: author_mod.mid.unwrap_or(0),
        name: author_mod.name.unwrap_or_default(),
        face: author_mod.face.unwrap_or_default(),
        pub_label: author_mod.pub_action.clone()
            .or(author_mod.pub_time)
            .unwrap_or_default(),
        pub_ts: author_mod.pub_ts.unwrap_or(0),
    };

    let stat = DynamicStat {
        like: stat_mod.like.as_ref().and_then(|c| c.count).unwrap_or(0),
        comment: stat_mod.comment.as_ref().and_then(|c| c.count).unwrap_or(0),
        forward: stat_mod.forward.as_ref().and_then(|c| c.count).unwrap_or(0),
    };

    let major = dynamic_mod.major.unwrap_or_default();
    let mut text = dynamic_mod.desc.as_ref().and_then(|d| d.text.clone()).unwrap_or_default();
    let mut video: Option<DynamicVideo> = None;
    let mut live_item: Option<DynamicLive> = None;
    let mut images: Vec<DynamicImage> = Vec::new();

    // Order matters: opus → archive → draw → article fallbacks.
    if let Some(opus) = major.opus {
        if let Some(s) = opus.summary.and_then(|s| s.text) {
            if text.is_empty() { text = s; }
        }
        if let Some(pics) = opus.pics {
            for p in pics {
                images.push(DynamicImage {
                    url: p.url.unwrap_or_default(),
                    width: p.width.unwrap_or(0),
                    height: p.height.unwrap_or(0),
                });
            }
        }
    }
    if let Some(arc) = major.archive {
        let stat_label = arc.stat.unwrap_or_default();
        video = Some(DynamicVideo {
            aid: arc.aid.as_deref().and_then(|s| s.parse().ok()).unwrap_or(0),
            bvid: arc.bvid.unwrap_or_default(),
            title: arc.title.unwrap_or_default(),
            cover: arc.cover.unwrap_or_default(),
            duration_label: arc.duration_text.unwrap_or_default(),
            stat_label,
        });
    }
    if let Some(draw) = major.draw {
        if let Some(items) = draw.items {
            for p in items {
                images.push(DynamicImage {
                    url: p.src.unwrap_or_default(),
                    width: p.width.unwrap_or(0),
                    height: p.height.unwrap_or(0),
                });
            }
        }
    }
    if let Some(art) = major.article {
        if text.is_empty() { text = art.title.unwrap_or_default(); }
        if let Some(covers) = art.covers {
            for url in covers {
                images.push(DynamicImage { url, width: 0, height: 0 });
            }
        }
    }
    if let Some(pgc) = major.pgc {
        video = Some(DynamicVideo {
            aid: 0,
            bvid: String::new(),
            title: pgc.title.unwrap_or_default(),
            cover: pgc.cover.unwrap_or_default(),
            duration_label: pgc.sub_type.unwrap_or_default(),
            stat_label: pgc.stat.unwrap_or_default(),
        });
    }
    if let Some(live) = major.live_rcmd.or(major.live) {
        live_item = live.into_dynamic_live();
    }

    let orig = w.orig.and_then(|b| flatten_dynamic_item(*b)).map(Box::new);

    let basic = w.basic.unwrap_or_default();
    let comment_id = basic
        .comment_id_str
        .as_deref()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let comment_type = basic.comment_type.unwrap_or(0);

    Some(DynamicItem {
        id_str: w.id_str.unwrap_or_default(),
        kind,
        author,
        stat,
        text,
        video,
        live: live_item,
        images,
        comment_id,
        comment_type,
        orig,
    })
}

// MARK: - Wire (lifted, narrowed)

#[derive(Default, Deserialize)]
struct DynamicFeedWire {
    #[serde(default, deserialize_with = "null_as_empty_vec")] items: Vec<DynItemWire>,
    #[serde(default, deserialize_with = "lenient_string")] offset: Option<String>,
    #[serde(default)] has_more: Option<bool>,
    #[serde(default, deserialize_with = "lenient_string")] update_baseline: Option<String>,
    #[serde(default, deserialize_with = "lenient_i64")] update_num: Option<i64>,
}

#[derive(Default, Deserialize)]
struct DynItemWire {
    #[serde(default, deserialize_with = "lenient_string")] id_str: Option<String>,
    #[serde(default, rename = "type", deserialize_with = "lenient_string")] kind: Option<String>,
    #[serde(default)] modules: Option<DynModulesWire>,
    #[serde(default)] basic: Option<DynBasicWire>,
    /// Forwarded original item (1-level recursion). Use `Box` so
    /// the recursive type is sized.
    #[serde(default)] orig: Option<Box<DynItemWire>>,
}

#[derive(Default, Deserialize)]
struct DynBasicWire {
    #[serde(default, deserialize_with = "lenient_string")] comment_id_str: Option<String>,
    #[serde(default, deserialize_with = "lenient_i32")] comment_type: Option<i32>,
}

#[derive(Default, Deserialize)]
struct DynModulesWire {
    #[serde(default)] module_author: Option<DynAuthorWire>,
    #[serde(default)] module_dynamic: Option<DynDynamicWire>,
    #[serde(default)] module_stat: Option<DynStatWire>,
}

#[derive(Default, Deserialize, Clone)]
struct DynAuthorWire {
    #[serde(default, deserialize_with = "lenient_i64")] mid: Option<i64>,
    #[serde(default, deserialize_with = "lenient_string")] name: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] face: Option<String>,
    /// Localized "投稿了视频", "发布了动态" etc.
    #[serde(default, deserialize_with = "lenient_string")] pub_action: Option<String>,
    /// "5 分钟前", "12-25" etc.
    #[serde(default, deserialize_with = "lenient_string")] pub_time: Option<String>,
    #[serde(default, deserialize_with = "lenient_i64")] pub_ts: Option<i64>,
}

#[derive(Default, Deserialize)]
struct DynDynamicWire {
    #[serde(default)] desc: Option<DynDescWire>,
    #[serde(default)] major: Option<DynMajorWire>,
}

#[derive(Default, Deserialize)]
struct DynDescWire { #[serde(default, deserialize_with = "lenient_string")] text: Option<String> }

#[derive(Default, Deserialize)]
struct DynMajorWire {
    #[serde(default)] archive: Option<DynArchiveWire>,
    #[serde(default)] draw: Option<DynDrawWire>,
    #[serde(default)] opus: Option<DynOpusWire>,
    #[serde(default)] article: Option<DynArticleWire>,
    #[serde(default)] pgc: Option<DynPgcWire>,
    #[serde(default)] live_rcmd: Option<DynLiveWire>,
    #[serde(default)] live: Option<DynLiveWire>,
}

#[derive(Default, Deserialize)]
struct DynArchiveWire {
    #[serde(default, deserialize_with = "lenient_string")] aid: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] bvid: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] title: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] cover: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] duration_text: Option<String>,
    /// e.g. "3.2 万 观看 · 12 弹幕"
    #[serde(default, deserialize_with = "lenient_string")] stat: Option<String>,
}

#[derive(Default, Deserialize)]
struct DynDrawWire { #[serde(default)] items: Option<Vec<DynDrawItemWire>> }

#[derive(Default, Deserialize)]
struct DynDrawItemWire {
    #[serde(default, deserialize_with = "lenient_string")] src: Option<String>,
    #[serde(default, deserialize_with = "lenient_i64")] width: Option<i64>,
    #[serde(default, deserialize_with = "lenient_i64")] height: Option<i64>,
}

#[derive(Default, Deserialize)]
struct DynOpusWire {
    #[serde(default)] summary: Option<DynOpusSummaryWire>,
    #[serde(default)] pics: Option<Vec<DynOpusPicWire>>,
}
#[derive(Default, Deserialize)]
struct DynOpusSummaryWire { #[serde(default, deserialize_with = "lenient_string")] text: Option<String> }
#[derive(Default, Deserialize)]
struct DynOpusPicWire {
    #[serde(default, deserialize_with = "lenient_string")] url: Option<String>,
    #[serde(default, deserialize_with = "lenient_i64")] width: Option<i64>,
    #[serde(default, deserialize_with = "lenient_i64")] height: Option<i64>,
}

#[derive(Default, Deserialize)]
struct DynArticleWire {
    #[serde(default, deserialize_with = "lenient_string")] title: Option<String>,
    #[serde(default)] covers: Option<Vec<String>>,
}

#[derive(Default, Deserialize)]
struct DynPgcWire {
    #[serde(default, deserialize_with = "lenient_string")] title: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] cover: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] sub_type: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] stat: Option<String>,
}

#[derive(Default, Deserialize)]
struct DynLiveWire {
    #[serde(default, deserialize_with = "lenient_i64")] id: Option<i64>,
    #[serde(default, deserialize_with = "lenient_i64")] live_state: Option<i64>,
    #[serde(default, deserialize_with = "lenient_string")] title: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] cover: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] desc_first: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] content: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] area: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] area_name: Option<String>,
    #[serde(default, deserialize_with = "lenient_i64")] room_id: Option<i64>,
    #[serde(default, deserialize_with = "lenient_i64")] live_status: Option<i64>,
    #[serde(default)] watched_show: Option<DynWatchedShowWire>,
}

impl DynLiveWire {
    fn into_dynamic_live(self) -> Option<DynamicLive> {
        if let Some(content) = self.content.as_deref() {
            if let Ok(root) = serde_json::from_str::<DynLiveContentWire>(content) {
                if let Some(info) = root.live_play_info {
                    let room_id = info.room_id.unwrap_or(0);
                    if room_id > 0 {
                        return Some(DynamicLive {
                            room_id,
                            title: info.title.unwrap_or_default(),
                            cover: info.cover.unwrap_or_default(),
                            area_name: info.area_name.unwrap_or_default(),
                            watched_label: info.watched_show.and_then(|w| w.text_large).unwrap_or_default(),
                            live_status: info.live_status.unwrap_or(0),
                        });
                    }
                }
            }
        }
        let room_id = self.room_id.or(self.id).unwrap_or(0);
        if room_id <= 0 {
            return None;
        }
        Some(DynamicLive {
            room_id,
            title: self.title.unwrap_or_default(),
            cover: self.cover.unwrap_or_default(),
            area_name: self.area_name.or(self.area).or(self.desc_first).unwrap_or_default(),
            watched_label: self.watched_show.and_then(|w| w.text_large).unwrap_or_default(),
            live_status: self.live_status.or(self.live_state).unwrap_or(0),
        })
    }
}

#[derive(Default, Deserialize)]
struct DynLiveContentWire {
    #[serde(default)] live_play_info: Option<DynLivePlayInfoWire>,
}

#[derive(Default, Deserialize)]
struct DynLivePlayInfoWire {
    #[serde(default, deserialize_with = "lenient_i64")] room_id: Option<i64>,
    #[serde(default, deserialize_with = "lenient_i64")] live_status: Option<i64>,
    #[serde(default, deserialize_with = "lenient_string")] title: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] cover: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] area_name: Option<String>,
    #[serde(default)] watched_show: Option<DynWatchedShowWire>,
}

#[derive(Default, Deserialize)]
struct DynWatchedShowWire {
    #[serde(default, deserialize_with = "lenient_string")] text_large: Option<String>,
}

#[derive(Default, Deserialize)]
struct DynStatWire {
    #[serde(default)] like: Option<DynCountWire>,
    #[serde(default)] comment: Option<DynCountWire>,
    #[serde(default)] forward: Option<DynCountWire>,
}

#[derive(Default, Deserialize)]
struct DynCountWire { #[serde(default, deserialize_with = "lenient_i64")] count: Option<i64> }

fn null_as_empty_vec<'de, D, T>(de: D) -> Result<Vec<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::Deserialize<'de>,
{
    Ok(Option::<Vec<T>>::deserialize(de)?.unwrap_or_default())
}

/// Tolerant string deserializer. Bilibili occasionally swaps
/// "leaf" string fields for richer object payloads (e.g. moving
/// `pub_action` from a flat localized string to a nested rich-text
/// object) without bumping the API version. Rather than failing the
/// whole feed page when one row carries the new shape, we accept
/// strings, integers, or booleans and downgrade anything else to
/// `None`.
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

fn lenient_i32<'de, D>(de: D) -> Result<Option<i32>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(lenient_i64(de)?.map(|v| v as i32))
}
