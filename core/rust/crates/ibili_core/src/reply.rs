//! Comment list endpoints. Mirrors PiliPlus `lib/http/reply.dart`.
//!
//! Two flavours are supported:
//!
//! - `reply.main` (`/x/v2/reply/main`): top-level comments. Used both
//!   when logged-in and anonymous; we always go through `/main` because
//!   it returns the cursor-based `pagination_str` we need for infinite
//!   scrolling, and embeds `top_replies` (置顶) + `upper.mid` (UP 主) so
//!   we can highlight UP / 置顶 rows.
//! - `reply.detail` (`/x/v2/reply/reply`): ordinary page-based thread loading.
//! - `reply.detail_target` (Reply gRPC `DetailList`): server-side positioning
//!   around a specific nested reply, used by message notifications.

use crate::dto::{ReplyEmote, ReplyItem, ReplyJumpUrl, ReplyPage};
use crate::error::{CoreError, CoreResult};
use crate::Core;
use serde::Deserialize;
use std::collections::HashMap;

const URL_REPLY_MAIN: &str = "https://api.bilibili.com/x/v2/reply/main";
const URL_REPLY_DETAIL: &str = "https://api.bilibili.com/x/v2/reply/reply";
const GRPC_REPLY_DETAIL: &str = "/bilibili.main.community.reply.v1.Reply/DetailList";

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcDetailListRequest {
    #[prost(int64, tag = "1")]
    oid: i64,
    #[prost(int64, tag = "2")]
    kind: i64,
    #[prost(int64, tag = "3")]
    root: i64,
    #[prost(int64, tag = "4")]
    rpid: i64,
    #[prost(enumeration = "GrpcDetailListScene", tag = "6")]
    scene: i32,
    #[prost(enumeration = "GrpcReplyMode", tag = "7")]
    mode: i32,
    #[prost(message, optional, tag = "8")]
    pagination: Option<GrpcFeedPagination>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, prost::Enumeration)]
#[repr(i32)]
enum GrpcDetailListScene {
    Reply = 0,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, prost::Enumeration)]
#[repr(i32)]
enum GrpcReplyMode {
    Default = 0,
    Time = 2,
    Hot = 3,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcFeedPagination {
    #[prost(int32, tag = "1")]
    page_size: i32,
    #[prost(string, tag = "2")]
    offset: String,
    #[prost(bool, tag = "3")]
    is_refresh: bool,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcFeedPaginationReply {
    #[prost(string, tag = "1")]
    next_offset: String,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcDetailListReply {
    #[prost(message, optional, tag = "1")]
    cursor: Option<GrpcCursorReply>,
    #[prost(message, optional, tag = "2")]
    subject_control: Option<GrpcSubjectControl>,
    #[prost(message, optional, tag = "3")]
    root: Option<GrpcReplyInfo>,
    #[prost(message, optional, tag = "8")]
    pagination_reply: Option<GrpcFeedPaginationReply>,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcCursorReply {
    #[prost(bool, tag = "4")]
    is_end: bool,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcSubjectControl {
    #[prost(int64, tag = "1")]
    up_mid: i64,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcReplyInfo {
    #[prost(message, repeated, tag = "1")]
    replies: Vec<GrpcReplyInfo>,
    #[prost(int64, tag = "2")]
    id: i64,
    #[prost(int64, tag = "3")]
    oid: i64,
    #[prost(int64, tag = "5")]
    mid: i64,
    #[prost(int64, tag = "6")]
    root: i64,
    #[prost(int64, tag = "7")]
    parent: i64,
    #[prost(int64, tag = "9")]
    like: i64,
    #[prost(int64, tag = "10")]
    ctime: i64,
    #[prost(int64, tag = "11")]
    count: i64,
    #[prost(message, optional, tag = "12")]
    content: Option<GrpcContent>,
    #[prost(message, optional, tag = "13")]
    member: Option<GrpcMember>,
    #[prost(message, optional, tag = "14")]
    reply_control: Option<GrpcReplyControl>,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcContent {
    #[prost(string, tag = "1")]
    message: String,
    #[prost(map = "string, message", tag = "3")]
    emotes: HashMap<String, GrpcEmote>,
    #[prost(map = "string, message", tag = "5")]
    urls: HashMap<String, GrpcUrl>,
    #[prost(message, repeated, tag = "9")]
    pictures: Vec<GrpcPicture>,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcEmote {
    #[prost(int64, tag = "1")]
    size: i64,
    #[prost(string, tag = "2")]
    url: String,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcPicture {
    #[prost(string, tag = "1")]
    img_src: String,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcUrl {
    #[prost(string, tag = "1")]
    title: String,
    #[prost(string, tag = "3")]
    prefix_icon: String,
    #[prost(string, tag = "4")]
    app_url_schema: String,
    #[prost(string, tag = "13")]
    pc_url: String,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcMember {
    #[prost(int64, tag = "1")]
    mid: i64,
    #[prost(string, tag = "2")]
    name: String,
    #[prost(string, tag = "4")]
    face: String,
    #[prost(int64, tag = "5")]
    level: i64,
    #[prost(int64, tag = "8")]
    vip_status: i64,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcReplyControl {
    #[prost(int64, tag = "1")]
    action: i64,
    #[prost(bool, tag = "2")]
    up_like: bool,
    #[prost(bool, tag = "3")]
    up_reply: bool,
    #[prost(string, tag = "25")]
    location: String,
}

fn grpc_detail_list_request(
    oid: i64,
    kind: i32,
    root: i64,
    target_rpid: i64,
    next_offset: &str,
) -> GrpcDetailListRequest {
    GrpcDetailListRequest {
        oid,
        kind: i64::from(kind),
        root,
        rpid: target_rpid.max(0),
        scene: GrpcDetailListScene::Reply as i32,
        mode: GrpcReplyMode::Hot as i32,
        pagination: (!next_offset.is_empty()).then(|| GrpcFeedPagination {
            page_size: 0,
            offset: next_offset.to_string(),
            is_refresh: false,
        }),
    }
}

#[derive(Deserialize)]
struct ReplyMainRoot {
    #[serde(default)]
    cursor: Option<CursorWire>,
    #[serde(default, deserialize_with = "null_as_default")]
    replies: Vec<ReplyWire>,
    #[serde(default, deserialize_with = "null_as_default")]
    top_replies: Vec<ReplyWire>,
    #[serde(default)]
    upper: Option<UpperWire>,
}

#[derive(Deserialize)]
struct ReplyDetailRoot {
    #[serde(default)]
    page: Option<DetailPageWire>,
    #[serde(default, deserialize_with = "null_as_default")]
    replies: Vec<ReplyWire>,
    #[serde(default)]
    root: Option<ReplyWire>,
    #[serde(default)]
    upper: Option<UpperWire>,
}

#[derive(Deserialize)]
struct DetailPageWire {
    #[serde(default)]
    num: i32,
    #[serde(default)]
    size: i32,
    #[serde(default)]
    count: i64,
}

#[derive(Deserialize)]
struct CursorWire {
    #[serde(default)]
    is_end: bool,
    #[serde(default)]
    all_count: i64,
    #[serde(default)]
    pagination_reply: Option<PaginationReplyWire>,
}

#[derive(Deserialize)]
struct PaginationReplyWire {
    #[serde(default)]
    next_offset: String,
}

#[derive(Default, Deserialize)]
struct UpperWire {
    #[serde(default)]
    mid: i64,
}

#[derive(Deserialize)]
struct ReplyWire {
    #[serde(default)]
    rpid: i64,
    #[serde(default)]
    oid: i64,
    #[serde(default)]
    root: i64,
    #[serde(default)]
    parent: i64,
    #[serde(default)]
    mid: i64,
    #[serde(default)]
    member: MemberWire,
    #[serde(default)]
    content: ContentWire,
    #[serde(default)]
    ctime: i64,
    #[serde(default)]
    like: i64,
    #[serde(default)]
    action: i32,
    #[serde(default)]
    reply_control: ReplyControlWire,
    #[serde(default)]
    rcount: i32,
    #[serde(default, deserialize_with = "null_as_default")]
    replies: Vec<ReplyWire>,
}

#[derive(Default, Deserialize)]
struct MemberWire {
    #[serde(default)]
    uname: String,
    #[serde(default)]
    avatar: String,
    #[serde(default, deserialize_with = "string_or_int")]
    level_info: LevelWire,
    #[serde(default)]
    vip: VipWire,
}

#[derive(Default, Deserialize)]
struct VipWire {
    #[serde(default)]
    vip_status: i32,
}

#[derive(Default, Deserialize)]
struct LevelWire {
    #[serde(default)]
    current_level: i32,
}

fn string_or_int<'de, D: serde::Deserializer<'de>>(de: D) -> Result<LevelWire, D::Error> {
    LevelWire::deserialize(de).or(Ok(LevelWire::default()))
}

#[derive(Default, Deserialize)]
struct ContentWire {
    #[serde(default)]
    message: String,
    /// Bilibili ships emote metadata as `{ "[doge]": { url, meta:{size} } }`.
    /// We deserialise into a map so the iOS layer doesn’t need a JSON parser.
    #[serde(default, deserialize_with = "emote_map_or_empty")]
    emote: HashMap<String, EmoteWire>,
    /// Inline picture attachments — always wrapped in objects with `img_src`.
    #[serde(default, deserialize_with = "null_as_default")]
    pictures: Vec<PictureWire>,
    /// Server-tagged jump targets: `"BV1xx": { title, pc_url, prefix_icon, … }`.
    #[serde(default, deserialize_with = "jump_map_or_empty")]
    jump_url: HashMap<String, JumpUrlWire>,
}

#[derive(Default, Deserialize)]
struct EmoteWire {
    #[serde(default)]
    url: String,
    #[serde(default)]
    meta: EmoteMetaWire,
}

#[derive(Default, Deserialize)]
struct EmoteMetaWire {
    #[serde(default)]
    size: i32,
}

#[derive(Default, Deserialize)]
struct PictureWire {
    #[serde(default)]
    img_src: String,
}

#[derive(Default, Deserialize)]
struct JumpUrlWire {
    #[serde(default)]
    title: String,
    #[serde(default)]
    pc_url: String,
    #[serde(default)]
    prefix_icon: String,
}

fn emote_map_or_empty<'de, D: serde::Deserializer<'de>>(
    de: D,
) -> Result<HashMap<String, EmoteWire>, D::Error> {
    Ok(Option::<HashMap<String, EmoteWire>>::deserialize(de)
        .ok()
        .flatten()
        .unwrap_or_default())
}

fn jump_map_or_empty<'de, D: serde::Deserializer<'de>>(
    de: D,
) -> Result<HashMap<String, JumpUrlWire>, D::Error> {
    Ok(Option::<HashMap<String, JumpUrlWire>>::deserialize(de)
        .ok()
        .flatten()
        .unwrap_or_default())
}

#[derive(Default, Deserialize)]
struct ReplyControlWire {
    #[serde(default)]
    up_action: UpActionWire,
    #[serde(default)]
    location: String,
}

#[derive(Default, Deserialize)]
struct UpActionWire {
    #[serde(default)]
    like: bool,
    #[serde(default)]
    reply: bool,
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
    pub fn reply_main(
        &self,
        oid: i64,
        kind: i32,
        sort: i32,
        next_offset: &str,
    ) -> CoreResult<ReplyPage> {
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

    /// Fetch the server-selected reply window containing `target_rpid`.
    /// Subsequent calls pass the returned `cursor_next` with `target_rpid=0`.
    pub fn reply_detail_target(
        &self,
        oid: i64,
        kind: i32,
        root: i64,
        target_rpid: i64,
        next_offset: &str,
    ) -> CoreResult<ReplyPage> {
        if oid <= 0 || root <= 0 {
            return Err(CoreError::InvalidArgument("oid/root invalid".into()));
        }
        let request = grpc_detail_list_request(oid, kind, root, target_rpid, next_offset);
        let response: GrpcDetailListReply =
            self.grpc_request(GRPC_REPLY_DETAIL, &request, false)?;
        let mut root = response.root.ok_or(CoreError::NotFound)?;
        let total = root.count;
        let replies = std::mem::take(&mut root.replies);
        let cursor_next = response
            .pagination_reply
            .map(|pagination| pagination.next_offset)
            .unwrap_or_default();
        let is_end =
            response.cursor.map(|cursor| cursor.is_end).unwrap_or(false) || cursor_next.is_empty();
        Ok(ReplyPage {
            items: replies.into_iter().map(map_grpc_reply).collect(),
            top: Some(map_grpc_reply(root)),
            upper_mid: response
                .subject_control
                .map(|control| control.up_mid)
                .unwrap_or_default(),
            cursor_next,
            is_end,
            total,
        })
    }
}

fn map_reply(r: ReplyWire) -> ReplyItem {
    let emotes: Vec<ReplyEmote> = r
        .content
        .emote
        .into_iter()
        .map(|(name, w)| ReplyEmote {
            name,
            url: w.url,
            size: w.meta.size.max(1),
        })
        .collect();
    let pictures: Vec<String> = r
        .content
        .pictures
        .into_iter()
        .map(|p| p.img_src)
        .filter(|s| !s.is_empty())
        .collect();
    let jump_urls: Vec<ReplyJumpUrl> = r
        .content
        .jump_url
        .into_iter()
        .map(|(keyword, j)| ReplyJumpUrl {
            keyword,
            title: j.title,
            url: j.pc_url,
            prefix_icon: j.prefix_icon,
        })
        .collect();
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
        emotes,
        pictures,
        jump_urls,
    }
}

fn map_grpc_reply(reply: GrpcReplyInfo) -> ReplyItem {
    let content = reply.content.unwrap_or_default();
    let member = reply.member.unwrap_or_default();
    let control = reply.reply_control.unwrap_or_default();
    ReplyItem {
        rpid: reply.id,
        oid: reply.oid,
        root: reply.root,
        parent: reply.parent,
        mid: if reply.mid > 0 { reply.mid } else { member.mid },
        uname: member.name,
        face: member.face,
        level: member.level as i32,
        vip_status: member.vip_status as i32,
        message: content.message,
        ctime: reply.ctime,
        like: reply.like,
        action: control.action as i32,
        reply_count: reply.count as i32,
        up_action_like: control.up_like,
        up_action_reply: control.up_reply,
        location: control.location,
        preview_replies: reply.replies.into_iter().map(map_grpc_reply).collect(),
        emotes: content
            .emotes
            .into_iter()
            .map(|(name, emote)| ReplyEmote {
                name,
                url: emote.url,
                size: (emote.size as i32).max(1),
            })
            .collect(),
        pictures: content
            .pictures
            .into_iter()
            .map(|picture| picture.img_src)
            .filter(|url| !url.is_empty())
            .collect(),
        jump_urls: content
            .urls
            .into_iter()
            .map(|(keyword, url)| ReplyJumpUrl {
                keyword,
                title: url.title,
                url: if url.pc_url.is_empty() {
                    url.app_url_schema
                } else {
                    url.pc_url
                },
                prefix_icon: url.prefix_icon,
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::grpc_detail_list_request;

    #[test]
    fn detail_target_uses_rpid_only_for_the_server_positioned_first_window() {
        let initial = grpc_detail_list_request(123, 1, 456, 789, "");
        assert_eq!(initial.rpid, 789);
        assert!(initial.pagination.is_none());

        let continuation = grpc_detail_list_request(123, 1, 456, 0, "opaque-offset");
        assert_eq!(continuation.rpid, 0);
        let pagination = continuation.pagination.expect("continuation cursor");
        assert_eq!(pagination.offset, "opaque-offset");
        assert!(!pagination.is_refresh);
    }
}
