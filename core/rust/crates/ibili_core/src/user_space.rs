//! User-space endpoints: account card, history, favourites, bangumi
//! follow list, watch-later list, followings/followers. Each method
//! is a thin wrapper around the matching Bilibili web endpoint that
//! returns a flat, FFI-friendly DTO so the iOS layer can render it
//! directly without re-modelling.
//!
//! All methods that read account-scoped data require an authenticated
//! session (the `SESSDATA` cookie that lives in the shared cookie jar
//! after `restore_session`); they short-circuit to an empty response
//! for anonymous calls so the UI can render gracefully without
//! throwing.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::Core;
use crate::error::{CoreError, CoreResult};
use crate::signer::WbiKey;

const URL_USER_CARD: &str = "https://api.bilibili.com/x/web-interface/card";
const URL_HISTORY_CURSOR: &str = "https://api.bilibili.com/x/web-interface/history/cursor";
const URL_FAV_RESOURCE_LIST: &str = "https://api.bilibili.com/x/v3/fav/resource/list";
const URL_FAV_PGC_LIST: &str = "https://api.bilibili.com/x/space/bangumi/follow/list";
const URL_WATCHLATER_LIST: &str = "https://api.bilibili.com/x/v2/history/toview/web";
const URL_FOLLOWINGS: &str = "https://api.bilibili.com/x/relation/followings";
const URL_FOLLOWERS: &str = "https://api.bilibili.com/x/relation/followers";
const URL_SPACE_ARC_SEARCH: &str = "https://api.bilibili.com/x/space/wbi/arc/search";
const URL_NAV: &str = "https://api.bilibili.com/x/web-interface/nav";

// MARK: - Public DTOs (serialised to JSON for the FFI hop)

/// Compact "user card" payload. Fans/following counts are pulled out
/// to top-level fields so the iOS layer doesn't need to descend into
/// the nested wire object.
#[derive(Debug, Serialize, Clone, Default)]
pub struct UserCard {
    pub mid: i64,
    pub name: String,
    pub face: String,
    pub sign: String,
    /// 粉丝数
    pub follower: i64,
    /// 关注数
    pub following: i64,
    /// 视频投稿数
    pub archive_count: i64,
    /// 0 = 普通; 1+ = 大会员等级 (vip.type)
    pub vip_type: i64,
    /// VIP 状态：0 = 非会员; 1 = 大会员
    pub vip_status: i64,
    /// 大会员标签文案，如 "年度大会员"。空字符串表示无。
    pub vip_label: String,
}

/// A single watch-history entry. We only keep video-type entries
/// (`business == "archive"`), the only kind that maps cleanly onto
/// the player view.
#[derive(Debug, Serialize, Clone)]
pub struct HistoryItem {
    pub aid: i64,
    pub bvid: String,
    pub cid: i64,
    pub title: String,
    pub cover: String,
    pub author: String,
    pub duration_sec: i64,
    /// Last playhead position in seconds. -1 means "watched to end".
    pub progress_sec: i64,
    /// Unix-seconds timestamp of the last view.
    pub view_at: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct HistoryPage {
    pub items: Vec<HistoryItem>,
    /// Cursor for the next page; pass back into `history_cursor` as
    /// `max`. Zero means there are no more entries.
    pub next_max: i64,
    pub next_view_at: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct FavResourceItem {
    pub aid: i64,
    pub bvid: String,
    pub cid: i64,
    pub title: String,
    pub cover: String,
    pub author: String,
    pub duration_sec: i64,
    pub play: i64,
    pub danmaku: i64,
    pub pubdate: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct FavResourcePage {
    pub items: Vec<FavResourceItem>,
    pub has_more: bool,
}

#[derive(Debug, Serialize, Clone)]
pub struct BangumiFollowItem {
    pub season_id: i64,
    pub media_id: i64,
    pub title: String,
    pub cover: String,
    /// e.g. "看到第 5 话"
    pub progress: String,
    pub evaluate: String,
    pub total_count: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct BangumiFollowPage {
    pub items: Vec<BangumiFollowItem>,
    pub has_more: bool,
}

#[derive(Debug, Serialize, Clone)]
pub struct WatchLaterItem {
    pub aid: i64,
    pub bvid: String,
    pub cid: i64,
    pub title: String,
    pub cover: String,
    pub author: String,
    pub duration_sec: i64,
    /// Resume position in seconds. -1 = watched to end, 0 = unwatched.
    pub progress_sec: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct RelationUser {
    pub mid: i64,
    pub name: String,
    pub face: String,
    pub sign: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct RelationPage {
    pub items: Vec<RelationUser>,
    pub total: i64,
}

/// One per-user archive entry returned by `/x/space/wbi/arc/search`.
/// Keep the shape close to `FeedItem` so the iOS layer can reuse the
/// same video card component.
#[derive(Debug, Serialize, Clone)]
pub struct SpaceArcItem {
    pub aid: i64,
    pub bvid: String,
    pub title: String,
    pub cover: String,
    pub author: String,
    /// "01:32" / "1:23:45" — Bilibili returns this pre-formatted.
    pub duration_label: String,
    pub play: i64,
    pub danmaku: i64,
    pub comment: i64,
    /// Unix-seconds publish timestamp.
    pub created: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct SpaceArcSearchPage {
    pub items: Vec<SpaceArcItem>,
    pub count: i64,
    pub page: i64,
    pub page_size: i64,
}

// MARK: - Implementation

impl Core {
    /// `/x/web-interface/card?mid=&photo=false`. Public endpoint —
    /// works for any mid, even when the caller is anonymous, which is
    /// what we want for the player's uploader chip.
    pub fn user_card(&self, mid: i64) -> CoreResult<UserCard> {
        if mid <= 0 {
            return Err(CoreError::InvalidArgument("mid required".into()));
        }
        let params: Vec<(String, String)> = vec![
            ("mid".into(), mid.to_string()),
            ("photo".into(), "false".into()),
        ];
        let raw: UserCardWire = self.http.get_web(URL_USER_CARD, &params)?;
        let card = raw.card.unwrap_or_default();
        let parsed_mid = card.mid.as_deref().and_then(|s| s.parse::<i64>().ok()).unwrap_or(mid);
        let following = card.attention.unwrap_or(0);
        let vip = card.vip.unwrap_or_default();
        Ok(UserCard {
            mid: parsed_mid,
            name: card.name.unwrap_or_default(),
            face: card.face.unwrap_or_default(),
            sign: card.sign.unwrap_or_default(),
            follower: raw.follower.unwrap_or(card.fans.unwrap_or(0)),
            following,
            archive_count: raw.archive_count.unwrap_or(0),
            vip_type: vip.kind.unwrap_or(0),
            vip_status: vip.status.unwrap_or(0),
            vip_label: vip.label.and_then(|l| l.text).unwrap_or_default(),
        })
    }

    /// `/x/web-interface/history/cursor`. Cookie-authenticated.
    /// `max` and `view_at` are the cursor returned by the previous
    /// page; pass `0` for both on the first call.
    pub fn history_cursor(&self, max: i64, view_at: i64) -> CoreResult<HistoryPage> {
        if self.session.read().access_key().is_none() {
            return Ok(HistoryPage { items: vec![], next_max: 0, next_view_at: 0 });
        }
        let mut params: Vec<(String, String)> = vec![
            ("ps".into(), "20".into()),
            ("business".into(), "archive".into()),
        ];
        if max > 0 { params.push(("max".into(), max.to_string())); }
        if view_at > 0 { params.push(("view_at".into(), view_at.to_string())); }
        let raw: HistoryWire = self.http.get_web(URL_HISTORY_CURSOR, &params)?;
        let cursor = raw.cursor.unwrap_or_default();
        let items: Vec<HistoryItem> = raw.list.into_iter()
            // Drop non-video rows (live, articles, etc.) so the screen
            // doesn't try to push the player for unsupported types.
            .filter(|r| r.history.as_ref().map(|h| h.business.as_deref() == Some("archive")).unwrap_or(false))
            .filter_map(|r| {
                let h = r.history.as_ref()?;
                let aid = h.oid.unwrap_or(0);
                if aid <= 0 { return None; }
                Some(HistoryItem {
                    aid,
                    bvid: h.bvid.clone().unwrap_or_default(),
                    cid: h.cid.unwrap_or(0),
                    title: r.title.unwrap_or_default(),
                    cover: r.cover.unwrap_or_default(),
                    author: r.author_name.unwrap_or_default(),
                    duration_sec: r.duration.unwrap_or(0),
                    progress_sec: r.progress.unwrap_or(0),
                    view_at: r.view_at.unwrap_or(0),
                })
            })
            .collect();
        Ok(HistoryPage {
            items,
            next_max: cursor.max.unwrap_or(0),
            next_view_at: cursor.view_at.unwrap_or(0),
        })
    }

    /// `/x/v3/fav/resource/list`. Lists video resources inside a
    /// favourite folder. `pn` is 1-based.
    pub fn fav_resource_list(&self, media_id: i64, pn: i64) -> CoreResult<FavResourcePage> {
        if self.session.read().access_key().is_none() {
            return Ok(FavResourcePage { items: vec![], has_more: false });
        }
        let params: Vec<(String, String)> = vec![
            ("media_id".into(), media_id.to_string()),
            ("pn".into(), pn.max(1).to_string()),
            ("ps".into(), "20".into()),
            ("order".into(), "mtime".into()),
            ("type".into(), "0".into()),
            ("platform".into(), "web".into()),
        ];
        let raw: FavListWire = self.http.get_web(URL_FAV_RESOURCE_LIST, &params)?;
        let items: Vec<FavResourceItem> = raw.medias.into_iter()
            .filter(|m| m.kind.unwrap_or(0) == 2 || m.kind.is_none()) // 2 = video; ignore audio etc.
            .map(|m| {
                let upper = m.upper.unwrap_or_default();
                let cnt = m.cnt_info.unwrap_or_default();
                FavResourceItem {
                    aid: m.id.unwrap_or(0),
                    bvid: m.bvid.unwrap_or_default(),
                    cid: 0, // not provided here; player will resolve via video.view_cid
                    title: m.title.unwrap_or_default(),
                    cover: m.cover.unwrap_or_default(),
                    author: upper.name.unwrap_or_default(),
                    duration_sec: m.duration.unwrap_or(0),
                    play: cnt.play.unwrap_or(0),
                    danmaku: cnt.danmaku.unwrap_or(0),
                    pubdate: m.pubtime.unwrap_or(0),
                }
            })
            .collect();
        Ok(FavResourcePage { items, has_more: raw.has_more.unwrap_or(false) })
    }

    /// `/x/space/bangumi/follow/list`. `kind` 1 = bangumi, 2 = cinema.
    /// `status` 0 = all, 1 = watching, 2 = finished, 3 = planned.
    pub fn bangumi_follow_list(&self, vmid: i64, kind: i32, status: i32, pn: i64) -> CoreResult<BangumiFollowPage> {
        if vmid <= 0 || self.session.read().access_key().is_none() {
            return Ok(BangumiFollowPage { items: vec![], has_more: false });
        }
        let params: Vec<(String, String)> = vec![
            ("vmid".into(), vmid.to_string()),
            ("type".into(), kind.to_string()),
            ("follow_status".into(), status.to_string()),
            ("pn".into(), pn.max(1).to_string()),
            ("ps".into(), "20".into()),
        ];
        let raw: BangumiListWire = self.http.get_web(URL_FAV_PGC_LIST, &params)?;
        let items: Vec<BangumiFollowItem> = raw.list.into_iter().map(|b| BangumiFollowItem {
            season_id: b.season_id.unwrap_or(0),
            media_id: b.media_id.unwrap_or(0),
            title: b.title.unwrap_or_default(),
            cover: b.cover.unwrap_or_default(),
            progress: b.progress.unwrap_or_default(),
            evaluate: b.evaluate.unwrap_or_default(),
            total_count: b.total_count.unwrap_or(0),
        }).collect();
        // The endpoint's `total` is total entries across all pages;
        // `has_more` isn't returned, so we infer.
        let total = raw.total.unwrap_or(0);
        let has_more = (pn.max(1) as i64) * 20 < total;
        Ok(BangumiFollowPage { items, has_more })
    }

    /// Fetch the rich watch-later list (not just aids). Cookie-auth.
    pub fn watchlater_list(&self) -> CoreResult<Vec<WatchLaterItem>> {
        if self.session.read().access_key().is_none() {
            return Ok(Vec::new());
        }
        let raw: WatchLaterFullWire = self.http.get_web(URL_WATCHLATER_LIST, &[])?;
        Ok(raw.list.into_iter().map(|w| {
            let owner = w.owner.unwrap_or_default();
            WatchLaterItem {
                aid: w.aid.unwrap_or(0),
                bvid: w.bvid.unwrap_or_default(),
                cid: w.cid.unwrap_or(0),
                title: w.title.unwrap_or_default(),
                cover: w.pic.unwrap_or_default(),
                author: owner.name.unwrap_or_default(),
                duration_sec: w.duration.unwrap_or(0),
                progress_sec: w.progress.unwrap_or(0),
            }
        }).collect())
    }

    /// `/x/relation/followings?vmid=&pn=&ps=20`. The list is only
    /// public when the target user has not hidden it; on a permission
    /// error we surface an empty page rather than throwing so the UI
    /// can render an empty-state row.
    pub fn relation_followings(&self, vmid: i64, pn: i64) -> CoreResult<RelationPage> {
        self.relation_list(URL_FOLLOWINGS, vmid, pn)
    }

    /// `/x/relation/followers?vmid=&pn=&ps=20`. Same caveat as
    /// `relation_followings` — privacy settings can mask the list.
    pub fn relation_followers(&self, vmid: i64, pn: i64) -> CoreResult<RelationPage> {
        self.relation_list(URL_FOLLOWERS, vmid, pn)
    }

    fn relation_list(&self, url: &str, vmid: i64, pn: i64) -> CoreResult<RelationPage> {
        if vmid <= 0 {
            return Err(CoreError::InvalidArgument("vmid required".into()));
        }
        let params: Vec<(String, String)> = vec![
            ("vmid".into(), vmid.to_string()),
            ("pn".into(), pn.max(1).to_string()),
            ("ps".into(), "20".into()),
            ("order".into(), "desc".into()),
        ];
        // Privacy / non-mutual responses come back as code != 0 with
        // an empty `data`. `unwrap_envelope` raises that as an error;
        // catch and downgrade to an empty page.
        match self.http.get_web::<RelationWire>(url, &params) {
            Ok(raw) => {
                let items = raw.list.into_iter().map(|u| RelationUser {
                    mid: u.mid.unwrap_or(0),
                    name: u.uname.unwrap_or_default(),
                    face: u.face.unwrap_or_default(),
                    sign: u.sign.unwrap_or_default(),
                }).collect();
                Ok(RelationPage { items, total: raw.total.unwrap_or(0) })
            }
            Err(_) => Ok(RelationPage { items: vec![], total: 0 }),
        }
    }

    /// `/x/space/wbi/arc/search`. Per-uploader video archive search.
    /// `keyword` may be empty (lists everything paginated). `order`
    /// accepts upstream values: "pubdate" (default) | "click" (播放) |
    /// "stow" (收藏). The endpoint requires WBI signing even when
    /// the caller is anonymous.
    pub fn space_arc_search(
        &self,
        mid: i64,
        keyword: &str,
        order: &str,
        page: i64,
    ) -> CoreResult<SpaceArcSearchPage> {
        if mid <= 0 {
            return Err(CoreError::InvalidArgument("mid required".into()));
        }
        let key = self.fetch_wbi_key_for_space()?;
        let order_val = match order {
            "click" | "stow" | "pubdate" => order,
            _ => "pubdate",
        };
        let params: Vec<(String, String)> = vec![
            ("mid".into(), mid.to_string()),
            ("ps".into(), "30".into()),
            ("tid".into(), "0".into()),
            ("pn".into(), page.max(1).to_string()),
            ("keyword".into(), keyword.to_string()),
            ("order".into(), order_val.into()),
            ("platform".into(), "web".into()),
            ("web_location".into(), "1550101".into()),
            ("order_avoided".into(), "true".into()),
        ];
        let raw: SpaceArcSearchRoot = self.http.get_signed_web(URL_SPACE_ARC_SEARCH, params, &key)?;
        let vlist = raw.list.and_then(|l| l.vlist).unwrap_or_default();
        let items = vlist.into_iter().map(|v| SpaceArcItem {
            aid: v.aid.unwrap_or(0),
            bvid: v.bvid.unwrap_or_default(),
            title: v.title.unwrap_or_default(),
            cover: v.pic.unwrap_or_default(),
            author: v.author.unwrap_or_default(),
            duration_label: v.length.unwrap_or_default(),
            play: v.play.unwrap_or(0),
            danmaku: v.video_review.unwrap_or(0),
            comment: v.comment.unwrap_or(0),
            created: v.created.unwrap_or(0),
        }).collect();
        let page_info = raw.page.unwrap_or_default();
        Ok(SpaceArcSearchPage {
            items,
            count: page_info.count.unwrap_or(0),
            page: page_info.pn.unwrap_or(1),
            page_size: page_info.ps.unwrap_or(30),
        })
    }

    fn fetch_wbi_key_for_space(&self) -> CoreResult<WbiKey> {
        let nav: NavWire = self.http.get_web(URL_NAV, &[])?;
        Ok(WbiKey::from_urls(&nav.wbi_img.img_url, &nav.wbi_img.sub_url))
    }
}

// MARK: - Wire (Bilibili JSON) shapes

#[derive(Default, Deserialize)]
struct UserCardWire {
    #[serde(default)] card: Option<UserCardInner>,
    #[serde(default)] follower: Option<i64>,
    #[serde(default)] archive_count: Option<i64>,
}

#[derive(Default, Deserialize)]
struct UserCardInner {
    #[serde(default)] mid: Option<String>,
    #[serde(default)] name: Option<String>,
    #[serde(default)] face: Option<String>,
    /// Bio. Sometimes returned as `sign`, sometimes nested elsewhere;
    /// the card endpoint emits it inline.
    #[serde(default)] sign: Option<String>,
    /// Some response variants put fans inside `card.fans` instead of
    /// the top-level `follower` field.
    #[serde(default)] fans: Option<i64>,
    /// 关注数 (following).
    #[serde(default)] attention: Option<i64>,
    #[serde(default)] vip: Option<UserCardVip>,
}

#[derive(Default, Deserialize)]
struct UserCardVip {
    #[serde(default, rename = "type")] kind: Option<i64>,
    #[serde(default)] status: Option<i64>,
    #[serde(default)] label: Option<UserCardVipLabel>,
}

#[derive(Default, Deserialize)]
struct UserCardVipLabel {
    #[serde(default)] text: Option<String>,
}

#[derive(Default, Deserialize)]
struct HistoryWire {
    #[serde(default, deserialize_with = "null_as_empty_vec")] list: Vec<HistoryItemWire>,
    #[serde(default)] cursor: Option<HistoryCursorWire>,
}

#[derive(Default, Deserialize)]
struct HistoryCursorWire {
    #[serde(default)] max: Option<i64>,
    #[serde(default)] view_at: Option<i64>,
}

#[derive(Default, Deserialize)]
struct HistoryItemWire {
    #[serde(default)] title: Option<String>,
    #[serde(default)] cover: Option<String>,
    #[serde(default)] author_name: Option<String>,
    #[serde(default)] duration: Option<i64>,
    #[serde(default)] progress: Option<i64>,
    #[serde(default)] view_at: Option<i64>,
    #[serde(default)] history: Option<HistoryRefWire>,
}

#[derive(Default, Deserialize)]
struct HistoryRefWire {
    #[serde(default)] oid: Option<i64>,
    #[serde(default)] cid: Option<i64>,
    #[serde(default)] bvid: Option<String>,
    #[serde(default)] business: Option<String>,
}

#[derive(Default, Deserialize)]
struct FavListWire {
    #[serde(default, deserialize_with = "null_as_empty_vec")] medias: Vec<FavMediaWire>,
    #[serde(default)] has_more: Option<bool>,
}

#[derive(Default, Deserialize)]
struct FavMediaWire {
    #[serde(default)] id: Option<i64>,           // aid
    #[serde(default)] bvid: Option<String>,
    #[serde(default)] title: Option<String>,
    #[serde(default)] cover: Option<String>,
    #[serde(default)] duration: Option<i64>,
    #[serde(default)] pubtime: Option<i64>,
    #[serde(default, rename = "type")] kind: Option<i64>,
    #[serde(default)] upper: Option<FavUpperWire>,
    #[serde(default)] cnt_info: Option<FavCntWire>,
}

#[derive(Default, Deserialize)]
struct FavUpperWire {
    #[serde(default)] name: Option<String>,
}

#[derive(Default, Deserialize)]
struct FavCntWire {
    #[serde(default)] play: Option<i64>,
    #[serde(default)] danmaku: Option<i64>,
}

#[derive(Default, Deserialize)]
struct BangumiListWire {
    #[serde(default, deserialize_with = "null_as_empty_vec")] list: Vec<BangumiItemWire>,
    #[serde(default)] total: Option<i64>,
}

#[derive(Default, Deserialize)]
struct BangumiItemWire {
    #[serde(default)] season_id: Option<i64>,
    #[serde(default)] media_id: Option<i64>,
    #[serde(default)] title: Option<String>,
    #[serde(default)] cover: Option<String>,
    #[serde(default)] progress: Option<String>,
    #[serde(default)] evaluate: Option<String>,
    #[serde(default)] total_count: Option<i64>,
}

#[derive(Default, Deserialize)]
struct WatchLaterFullWire {
    #[serde(default, deserialize_with = "null_as_empty_vec")] list: Vec<WatchLaterFullItemWire>,
}

#[derive(Default, Deserialize)]
struct WatchLaterFullItemWire {
    #[serde(default)] aid: Option<i64>,
    #[serde(default)] bvid: Option<String>,
    #[serde(default)] cid: Option<i64>,
    #[serde(default)] title: Option<String>,
    #[serde(default)] pic: Option<String>,
    #[serde(default)] duration: Option<i64>,
    #[serde(default)] progress: Option<i64>,
    #[serde(default)] owner: Option<WatchLaterOwnerWire>,
}

#[derive(Default, Deserialize)]
struct WatchLaterOwnerWire {
    #[serde(default)] name: Option<String>,
}

#[derive(Default, Deserialize)]
struct RelationWire {
    #[serde(default, deserialize_with = "null_as_empty_vec")] list: Vec<RelationUserWire>,
    #[serde(default)] total: Option<i64>,
}

#[derive(Default, Deserialize)]
struct RelationUserWire {
    #[serde(default)] mid: Option<i64>,
    #[serde(default)] uname: Option<String>,
    #[serde(default)] face: Option<String>,
    #[serde(default)] sign: Option<String>,
}

fn null_as_empty_vec<'de, D, T>(de: D) -> Result<Vec<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::Deserialize<'de>,
{
    Ok(Option::<Vec<T>>::deserialize(de)?.unwrap_or_default())
}

// `_value_unused` keeps clippy from flagging the unused import when
// new endpoints are added in the future and need to fall back on
// untyped JSON shapes.
#[allow(dead_code)]
fn _value_unused() -> Value { Value::Null }

#[derive(Default, Deserialize)]
struct NavWire {
    #[serde(default)] wbi_img: NavWbiImageWire,
}
#[derive(Default, Deserialize)]
struct NavWbiImageWire {
    #[serde(default)] img_url: String,
    #[serde(default)] sub_url: String,
}

#[derive(Default, Deserialize)]
struct SpaceArcSearchRoot {
    #[serde(default)] list: Option<SpaceArcListWire>,
    #[serde(default)] page: Option<SpaceArcPageWire>,
}
#[derive(Default, Deserialize)]
struct SpaceArcListWire {
    #[serde(default)] vlist: Option<Vec<SpaceArcItemWire>>,
}
#[derive(Default, Deserialize)]
struct SpaceArcItemWire {
    #[serde(default)] aid: Option<i64>,
    #[serde(default)] bvid: Option<String>,
    #[serde(default)] title: Option<String>,
    #[serde(default)] pic: Option<String>,
    #[serde(default)] author: Option<String>,
    #[serde(default)] length: Option<String>,
    #[serde(default, deserialize_with = "lenient_count_opt")] play: Option<i64>,
    #[serde(default)] video_review: Option<i64>,
    #[serde(default)] comment: Option<i64>,
    #[serde(default)] created: Option<i64>,
}
#[derive(Default, Deserialize)]
struct SpaceArcPageWire {
    #[serde(default)] count: Option<i64>,
    #[serde(default)] pn: Option<i64>,
    #[serde(default)] ps: Option<i64>,
}

/// Bilibili recently started returning `play` as either a bare number
/// (legacy) or an object `{view, vt}` on newer responses. Coerce both
/// shapes to `i64`.
fn lenient_count_opt<'de, D>(de: D) -> Result<Option<i64>, D::Error>
where D: serde::Deserializer<'de> {
    use serde_json::Value;
    let v = Option::<Value>::deserialize(de)?;
    Ok(match v {
        Some(Value::Number(n)) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Some(Value::String(s)) => s.parse().ok(),
        Some(Value::Object(map)) => {
            map.get("view").or_else(|| map.get("vt"))
                .and_then(|x| x.as_i64())
        }
        _ => None,
    })
}
