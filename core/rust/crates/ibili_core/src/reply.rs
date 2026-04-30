//! Comment list endpoints. Mirrors PiliPlus `lib/http/reply.dart`.
//!
//! Two flavours are supported:
//!
//! - `reply.main` (`/x/v2/reply/main`): top-level comments. Used both
//!   when logged-in and anonymous; we always go through `/main` because
//!   it returns the cursor-based `pagination_str` we need for infinite
//!   scrolling, and embeds `top_replies` (置顶) + `upper.mid` (UP 主) so
//!   we can highlight UP / 置顶 rows.
//! - `reply.detail` (`/x/v2/reply/reply`): replies to a single root
//!   comment, page-based.

use crate::Core;
use crate::dto::{ReplyItem, ReplyPage};
use crate::error::{CoreError, CoreResult};
use serde::Deserialize;

const URL_REPLY_MAIN: &str = "https://api.bilibili.com/x/v2/reply/main";
const URL_REPLY_DETAIL: &str = "https://api.bilibili.com/x/v2/reply/reply";

#[derive(Deserialize)]
struct ReplyMainRoot {
    #[serde(default)] cursor: Option<CursorWire>,
    #[serde(default, deserialize_with = "null_as_default")] replies: Vec<ReplyWire>,
    #[serde(default, deserialize_with = "null_as_default")] top_replies: Vec<ReplyWire>,
    #[serde(default)] upper: Option<UpperWire>,
}

#[derive(Deserialize)]
struct ReplyDetailRoot {
    #[serde(default)] page: Option<DetailPageWire>,
    #[serde(default, deserialize_with = "null_as_default")] replies: Vec<ReplyWire>,
    #[serde(default)] root: Option<ReplyWire>,
    #[serde(default)] upper: Option<UpperWire>,
}

#[derive(Deserialize)]
struct DetailPageWire {
    #[serde(default)] num: i32,
    #[serde(default)] size: i32,
    #[serde(default)] count: i64,
}

#[derive(Deserialize)]
struct CursorWire {
    #[serde(default)] is_end: bool,
    #[serde(default)] all_count: i64,
    #[serde(default)] pagination_reply: Option<PaginationReplyWire>,
}

#[derive(Deserialize)]
struct PaginationReplyWire {
    #[serde(default)] next_offset: String,
}

#[derive(Default, Deserialize)]
struct UpperWire { #[serde(default)] mid: i64 }

#[derive(Deserialize)]
struct ReplyWire {
    #[serde(default)] rpid: i64,
    #[serde(default)] oid: i64,
    #[serde(default)] root: i64,
    #[serde(default)] parent: i64,
    #[serde(default)] mid: i64,
    #[serde(default)] member: MemberWire,
    #[serde(default)] content: ContentWire,
    #[serde(default)] ctime: i64,
    #[serde(default)] like: i64,
    #[serde(default)] action: i32,
    #[serde(default)] reply_control: ReplyControlWire,
    #[serde(default)] rcount: i32,
    #[serde(default, deserialize_with = "null_as_default")] replies: Vec<ReplyWire>,
}

#[derive(Default, Deserialize)]
struct MemberWire {
    #[serde(default)] uname: String,
    #[serde(default)] avatar: String,
    #[serde(default, deserialize_with = "string_or_int")] level_info: LevelWire,
    #[serde(default)] vip: VipWire,
}

#[derive(Default, Deserialize)]
struct VipWire { #[serde(default)] vip_status: i32 }

#[derive(Default, Deserialize)]
struct LevelWire { #[serde(default)] current_level: i32 }

fn string_or_int<'de, D: serde::Deserializer<'de>>(de: D) -> Result<LevelWire, D::Error> {
    LevelWire::deserialize(de).or(Ok(LevelWire::default()))
}

#[derive(Default, Deserialize)]
struct ContentWire { #[serde(default)] message: String }

#[derive(Default, Deserialize)]
struct ReplyControlWire {
    #[serde(default)] up_action: UpActionWire,
    #[serde(default)] location: String,
}

#[derive(Default, Deserialize)]
struct UpActionWire {
    #[serde(default)] like: bool,
    #[serde(default)] reply: bool,
}

fn null_as_default<'de, D, T>(de: D) -> Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Default + serde::Deserialize<'de>,
{
    Ok(Option::<T>::deserialize(de)?.unwrap_or_default())
}

impl Core {
    /// Fetch top-level comments. `sort` is 1 (热门) or 2 (时间).
    /// `next_offset` is the cursor returned by the previous call (`""` for first page).
    pub fn reply_main(&self, oid: i64, kind: i32, sort: i32, next_offset: &str) -> CoreResult<ReplyPage> {
        if oid <= 0 {
            return Err(CoreError::InvalidArgument("oid invalid".into()));
        }
        let mode = if sort == 2 { 2 } else { 3 };
        let pagination = format!("{{\"offset\":\"{}\"}}", next_offset.replace('"', "\\\""));
        let params: Vec<(String, String)> = vec![
            ("oid".into(), oid.to_string()),
            ("type".into(), kind.to_string()),
            ("mode".into(), mode.to_string()),
            ("plat".into(), "1".into()),
            ("pagination_str".into(), pagination),
            ("seek_rpid".into(), "0".into()),
        ];
        let root: ReplyMainRoot = self.http.get_web(URL_REPLY_MAIN, &params)?;
        let upper_mid = root.upper.as_ref().map(|u| u.mid).unwrap_or_default();
        let cursor = root.cursor.as_ref();
        let cursor_next = cursor
            .and_then(|c| c.pagination_reply.as_ref())
            .map(|p| p.next_offset.clone())
            .unwrap_or_default();
        let is_end = cursor.map(|c| c.is_end).unwrap_or(true);
        let total = cursor.map(|c| c.all_count).unwrap_or_default();
        let top = root.top_replies.into_iter().next().map(|r| map_reply(r));
        Ok(ReplyPage {
            items: root.replies.into_iter().map(map_reply).collect(),
            top,
            upper_mid,
            cursor_next,
            is_end,
            total,
        })
    }

    /// Fetch replies to a single root comment. Page-based (1-indexed).
    pub fn reply_detail(&self, oid: i64, kind: i32, root: i64, page: i64) -> CoreResult<ReplyPage> {
        if oid <= 0 || root <= 0 {
            return Err(CoreError::InvalidArgument("oid/root invalid".into()));
        }
        let params: Vec<(String, String)> = vec![
            ("oid".into(), oid.to_string()),
            ("type".into(), kind.to_string()),
            ("root".into(), root.to_string()),
            ("pn".into(), page.max(1).to_string()),
            ("ps".into(), "20".into()),
            ("sort".into(), "1".into()),
        ];
        let raw: ReplyDetailRoot = self.http.get_web(URL_REPLY_DETAIL, &params)?;
        let total = raw.page.as_ref().map(|p| p.count).unwrap_or_default();
        let size = raw.page.as_ref().map(|p| p.size as i64).unwrap_or(20);
        let num = raw.page.as_ref().map(|p| p.num as i64).unwrap_or(1);
        let upper_mid = raw.upper.as_ref().map(|u| u.mid).unwrap_or_default();
        let is_end = num * size >= total;
        Ok(ReplyPage {
            items: raw.replies.into_iter().map(map_reply).collect(),
            top: raw.root.map(map_reply),
            upper_mid,
            cursor_next: String::new(),
            is_end,
            total,
        })
    }
}

fn map_reply(r: ReplyWire) -> ReplyItem {
    ReplyItem {
        rpid: r.rpid,
        oid: r.oid,
        root: r.root,
        parent: r.parent,
        mid: r.mid,
        uname: r.member.uname,
        face: r.member.avatar,
        level: r.member.level_info.current_level,
        vip_status: r.member.vip.vip_status,
        message: r.content.message,
        ctime: r.ctime,
        like: r.like,
        action: r.action,
        reply_count: r.rcount,
        up_action_like: r.reply_control.up_action.like,
        up_action_reply: r.reply_control.up_action.reply,
        location: r.reply_control.location,
        preview_replies: r.replies.into_iter().map(map_reply).collect(),
    }
}
