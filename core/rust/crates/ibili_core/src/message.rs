//! Bilibili message-center endpoints.
//!
//! The upstream PiliPlus message page is split between Web msgfeed
//! endpoints (reply / @ / like / system) and IM session APIs. This module
//! keeps the iOS-facing DTOs flat so SwiftUI can render one native list
//! without mirroring every upstream wire shape.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::CoreResult;
use crate::signer::WbiKey;
use crate::Core;

const URL_NAV: &str = "https://api.bilibili.com/x/web-interface/nav";
const URL_MSG_UNREAD: &str = "https://api.bilibili.com/x/msgfeed/unread";
const URL_SINGLE_UNREAD: &str =
    "https://api.vc.bilibili.com/session_svr/v1/session_svr/single_unread";
const URL_MSG_REPLY: &str = "https://api.bilibili.com/x/msgfeed/reply";
const URL_MSG_AT: &str = "https://api.bilibili.com/x/msgfeed/at";
const URL_MSG_LIKE: &str = "https://api.bilibili.com/x/msgfeed/like";
const URL_MSG_SYS: &str = "https://message.bilibili.com/x/sys-msg/query_notify_list";
const URL_SESSION_LIST: &str =
    "https://api.vc.bilibili.com/session_svr/v1/session_svr/get_sessions";
const URL_SESSION_ACCOUNTS: &str = "https://api.vc.bilibili.com/account/v1/user/cards";

#[derive(Debug, Serialize, Clone, Default)]
pub struct MessageUnreadSummary {
    pub reply: i64,
    pub at: i64,
    pub like: i64,
    pub sys_msg: i64,
    pub whisper: i64,
    pub total: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct MessageItem {
    pub id: String,
    pub kind: String,
    pub user_mid: i64,
    pub user_name: String,
    pub user_avatar: String,
    pub action: String,
    pub title: String,
    pub content: String,
    pub secondary_content: String,
    pub image: String,
    pub native_uri: String,
    pub timestamp: i64,
    pub time_text: String,
    pub count: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct MessagePage {
    pub items: Vec<MessageItem>,
    pub next_cursor_id: i64,
    pub next_cursor_time: i64,
    pub has_more: bool,
}

#[derive(Debug, Serialize, Clone)]
pub struct MessageSession {
    pub talker_id: i64,
    pub name: String,
    pub avatar: String,
    pub last_message: String,
    pub timestamp: i64,
    pub unread: i64,
    pub is_pinned: bool,
    pub is_muted: bool,
}

#[derive(Debug, Serialize, Clone)]
pub struct MessageSessionPage {
    pub items: Vec<MessageSession>,
    pub has_more: bool,
}

impl Core {
    pub fn message_unread_summary(&self) -> CoreResult<MessageUnreadSummary> {
        if self.session.read().access_key().is_none() {
            return Ok(MessageUnreadSummary::default());
        }

        let feed = self
            .http
            .get_web::<MsgFeedUnreadWire>(URL_MSG_UNREAD, &web_location_params("333.1365"))
            .unwrap_or_default();
        let single = self
            .http
            .get_web::<SingleUnreadWire>(
                URL_SINGLE_UNREAD,
                &[
                    ("build".into(), "0".into()),
                    ("mobi_app".into(), "web".into()),
                    ("unread_type".into(), "0".into()),
                    ("web_location".into(), "333.1365".into()),
                ],
            )
            .unwrap_or_default();
        let whisper = single.follow_unread.unwrap_or(0)
            + single.unfollow_unread.unwrap_or(0)
            + single.biz_msg_follow_unread.unwrap_or(0)
            + single.biz_msg_unfollow_unread.unwrap_or(0)
            + single.unfollow_push_msg.unwrap_or(0)
            + single.custom_unread.unwrap_or(0);
        let total = feed.reply.unwrap_or(0)
            + feed.at.unwrap_or(0)
            + feed.like.unwrap_or(0)
            + feed.sys_msg.unwrap_or(0)
            + whisper;
        Ok(MessageUnreadSummary {
            reply: feed.reply.unwrap_or(0),
            at: feed.at.unwrap_or(0),
            like: feed.like.unwrap_or(0),
            sys_msg: feed.sys_msg.unwrap_or(0),
            whisper,
            total,
        })
    }

    pub fn message_feed(
        &self,
        kind: &str,
        cursor_id: i64,
        cursor_time: i64,
    ) -> CoreResult<MessagePage> {
        if self.session.read().access_key().is_none() {
            return Ok(MessagePage {
                items: vec![],
                next_cursor_id: 0,
                next_cursor_time: 0,
                has_more: false,
            });
        }
        match kind {
            "reply" => self.message_reply_feed(cursor_id, cursor_time),
            "at" => self.message_at_feed(cursor_id, cursor_time),
            "like" => self.message_like_feed(cursor_id, cursor_time),
            "system" => self.message_system_feed(cursor_id),
            _ => Ok(MessagePage {
                items: vec![],
                next_cursor_id: 0,
                next_cursor_time: 0,
                has_more: false,
            }),
        }
    }

    pub fn message_sessions(&self) -> CoreResult<MessageSessionPage> {
        if self.session.read().access_key().is_none() {
            return Ok(MessageSessionPage {
                items: vec![],
                has_more: false,
            });
        }
        let key = self.fetch_wbi_key_for_message()?;
        let params = vec![
            ("session_type".into(), "1".into()),
            ("group_fold".into(), "1".into()),
            ("unfollow_fold".into(), "0".into()),
            ("sort_rule".into(), "2".into()),
            ("build".into(), "0".into()),
            ("mobi_app".into(), "web".into()),
            ("web_location".into(), "333.1296".into()),
        ];
        let raw: SessionListWire = self.http.get_signed_web(URL_SESSION_LIST, params, &key)?;
        let mids: Vec<i64> = raw
            .session_list
            .iter()
            .filter_map(|s| s.talker_id)
            .filter(|mid| *mid > 0)
            .collect();
        let users = self.message_user_cards(&mids).unwrap_or_default();
        let items = raw
            .session_list
            .into_iter()
            .map(|s| session_from_wire(s, &users))
            .collect();
        Ok(MessageSessionPage {
            items,
            has_more: loose_bool(raw.has_more).unwrap_or(false),
        })
    }

    fn message_reply_feed(&self, cursor_id: i64, cursor_time: i64) -> CoreResult<MessagePage> {
        let mut params = web_location_params("333.40164");
        if cursor_id > 0 {
            params.push(("id".into(), cursor_id.to_string()));
        }
        if cursor_time > 0 {
            params.push(("reply_time".into(), cursor_time.to_string()));
        }
        let raw: ReplyFeedWire = self.http.get_web(URL_MSG_REPLY, &params)?;
        let cursor = raw.cursor.unwrap_or_default();
        let next_cursor_id = cursor.id.unwrap_or(0);
        let next_cursor_time = cursor.time.unwrap_or(0);
        Ok(MessagePage {
            items: raw.items.into_iter().map(message_item_from_reply).collect(),
            has_more: !cursor.is_end.unwrap_or(false),
            next_cursor_id,
            next_cursor_time,
        })
    }

    fn message_at_feed(&self, cursor_id: i64, cursor_time: i64) -> CoreResult<MessagePage> {
        let mut params = web_location_params("333.40164");
        if cursor_id > 0 {
            params.push(("id".into(), cursor_id.to_string()));
        }
        if cursor_time > 0 {
            params.push(("at_time".into(), cursor_time.to_string()));
        }
        let raw: AtFeedWire = self.http.get_web(URL_MSG_AT, &params)?;
        let cursor = raw.cursor.unwrap_or_default();
        let next_cursor_id = cursor.id.unwrap_or(0);
        let next_cursor_time = cursor.time.unwrap_or(0);
        Ok(MessagePage {
            items: raw.items.into_iter().map(message_item_from_at).collect(),
            has_more: !cursor.is_end.unwrap_or(false),
            next_cursor_id,
            next_cursor_time,
        })
    }

    fn message_like_feed(&self, cursor_id: i64, cursor_time: i64) -> CoreResult<MessagePage> {
        let mut params = web_location_params("333.40164");
        if cursor_id > 0 {
            params.push(("id".into(), cursor_id.to_string()));
        }
        if cursor_time > 0 {
            params.push(("like_time".into(), cursor_time.to_string()));
        }
        let raw: LikeFeedWire = self.http.get_web(URL_MSG_LIKE, &params)?;
        let total = raw.total.unwrap_or_default();
        let cursor = total.cursor.unwrap_or_default();
        let mut seen = HashSet::new();
        let mut items = Vec::new();
        if cursor_id <= 0 {
            if let Some(latest) = raw.latest {
                for item in latest.items {
                    let id = item.id.unwrap_or(0);
                    if seen.insert(id) {
                        items.push(message_item_from_like(item));
                    }
                }
            }
        }
        for item in total.items {
            let id = item.id.unwrap_or(0);
            if seen.insert(id) {
                items.push(message_item_from_like(item));
            }
        }
        Ok(MessagePage {
            items,
            has_more: !cursor.is_end.unwrap_or(false),
            next_cursor_id: cursor.id.unwrap_or(0),
            next_cursor_time: cursor.time.unwrap_or(0),
        })
    }

    fn message_system_feed(&self, cursor: i64) -> CoreResult<MessagePage> {
        let mut params = vec![
            ("page_size".into(), "20".into()),
            ("mobi_app".into(), "web".into()),
            ("build".into(), "0".into()),
            ("web_location".into(), "333.40164".into()),
        ];
        if cursor > 0 {
            params.push(("cursor".into(), cursor.to_string()));
        }
        let raw: Vec<SystemMessageWire> = self.http.get_web(URL_MSG_SYS, &params)?;
        let next_cursor = raw.last().and_then(|item| item.cursor).unwrap_or(0);
        let has_more = raw.len() >= 20 && next_cursor > 0;
        Ok(MessagePage {
            items: raw.into_iter().map(message_item_from_system).collect(),
            next_cursor_id: next_cursor,
            next_cursor_time: 0,
            has_more,
        })
    }

    fn message_user_cards(&self, mids: &[i64]) -> CoreResult<HashMap<i64, MessageUserCardWire>> {
        let mut mids: Vec<i64> = mids.iter().copied().filter(|mid| *mid > 0).collect();
        mids.sort_unstable();
        mids.dedup();
        if mids.is_empty() {
            return Ok(HashMap::new());
        }
        let raw: Value = self.http.get_web(
            URL_SESSION_ACCOUNTS,
            &[
                (
                    "uids".into(),
                    mids.iter()
                        .map(|mid| mid.to_string())
                        .collect::<Vec<_>>()
                        .join(","),
                ),
                ("build".into(), "0".into()),
                ("mobi_app".into(), "web".into()),
            ],
        )?;
        let mut users = HashMap::new();
        match raw {
            Value::Object(map) => {
                for (key, value) in map {
                    if let Ok(card) = serde_json::from_value::<MessageUserCardWire>(value) {
                        let mid = card.mid.or_else(|| key.parse().ok()).unwrap_or(0);
                        if mid > 0 {
                            users.insert(mid, card);
                        }
                    }
                }
            }
            Value::Array(list) => {
                for value in list {
                    if let Ok(card) = serde_json::from_value::<MessageUserCardWire>(value) {
                        if let Some(mid) = card.mid.filter(|mid| *mid > 0) {
                            users.insert(mid, card);
                        }
                    }
                }
            }
            _ => {}
        }
        Ok(users)
    }

    fn fetch_wbi_key_for_message(&self) -> CoreResult<WbiKey> {
        let nav: NavWire = self.http.get_web(URL_NAV, &[])?;
        Ok(WbiKey::from_urls(
            &nav.wbi_img.img_url,
            &nav.wbi_img.sub_url,
        ))
    }
}

fn web_location_params(location: &str) -> Vec<(String, String)> {
    vec![
        ("platform".into(), "web".into()),
        ("mobi_app".into(), "web".into()),
        ("build".into(), "0".into()),
        ("web_location".into(), location.into()),
    ]
}

fn message_item_from_reply(raw: ReplyItemWire) -> MessageItem {
    let user = raw.user.unwrap_or_default();
    let item = raw.item.unwrap_or_default();
    let business = item.business.unwrap_or_else(|| "内容".into());
    let counts = raw.counts.unwrap_or(0);
    MessageItem {
        id: raw.id.unwrap_or(0).to_string(),
        kind: "reply".into(),
        user_mid: user.mid.unwrap_or(0),
        user_name: user.nickname.unwrap_or_default(),
        user_avatar: user.avatar.unwrap_or_default(),
        action: format!("对我的{business}发布了{counts}条评论"),
        title: item.source_content.unwrap_or_default(),
        content: item.target_reply_content.unwrap_or_default(),
        secondary_content: item.root_reply_content.unwrap_or_default(),
        image: String::new(),
        native_uri: item.native_uri.unwrap_or_default(),
        timestamp: raw.reply_time.unwrap_or(0),
        time_text: String::new(),
        count: counts,
    }
}

fn message_item_from_at(raw: AtItemWire) -> MessageItem {
    let user = raw.user.unwrap_or_default();
    let item = raw.item.unwrap_or_default();
    let business = item.business.unwrap_or_else(|| "内容".into());
    MessageItem {
        id: raw.id.unwrap_or(0).to_string(),
        kind: "at".into(),
        user_mid: user.mid.unwrap_or(0),
        user_name: user.nickname.unwrap_or_default(),
        user_avatar: user.avatar.unwrap_or_default(),
        action: format!("在{business}中@了我"),
        title: item.source_content.unwrap_or_default(),
        content: String::new(),
        secondary_content: String::new(),
        image: item.image.unwrap_or_default(),
        native_uri: item.native_uri.unwrap_or_default(),
        timestamp: raw.at_time.unwrap_or(0),
        time_text: String::new(),
        count: 0,
    }
}

fn message_item_from_like(raw: LikeItemWire) -> MessageItem {
    let item = raw.item.unwrap_or_default();
    let first_user = raw.users.first().cloned().unwrap_or_default();
    let count = raw.counts.unwrap_or(0);
    let name = if count > 1 {
        format!("{} 等人", first_user.nickname.unwrap_or_default())
    } else {
        first_user.nickname.unwrap_or_default()
    };
    MessageItem {
        id: raw.id.unwrap_or(0).to_string(),
        kind: "like".into(),
        user_mid: first_user.mid.unwrap_or(0),
        user_name: name,
        user_avatar: first_user.avatar.unwrap_or_default(),
        action: "赞了我".into(),
        title: item.title.unwrap_or_default(),
        content: item.business.unwrap_or_default(),
        secondary_content: String::new(),
        image: item.image.unwrap_or_default(),
        native_uri: item.native_uri.unwrap_or_default(),
        timestamp: raw.like_time.unwrap_or(0),
        time_text: String::new(),
        count,
    }
}

fn message_item_from_system(raw: SystemMessageWire) -> MessageItem {
    let content = raw.content.map(decode_system_content).unwrap_or_default();
    MessageItem {
        id: raw.id.unwrap_or(0).to_string(),
        kind: "system".into(),
        user_mid: 0,
        user_name: String::new(),
        user_avatar: String::new(),
        action: "系统通知".into(),
        title: raw.title.unwrap_or_default(),
        content,
        secondary_content: String::new(),
        image: String::new(),
        native_uri: String::new(),
        timestamp: 0,
        time_text: raw.time_at.unwrap_or_default(),
        count: 0,
    }
}

fn session_from_wire(
    raw: SessionWire,
    users: &HashMap<i64, MessageUserCardWire>,
) -> MessageSession {
    let talker_id = raw.talker_id.unwrap_or(0);
    let user = users.get(&talker_id);
    let last = raw.last_msg.unwrap_or_default();
    MessageSession {
        talker_id,
        name: user
            .and_then(|u| u.name.clone())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| format!("UID {talker_id}")),
        avatar: user.and_then(|u| u.face.clone()).unwrap_or_default(),
        last_message: decode_im_message(last.content.unwrap_or_default()),
        timestamp: last.timestamp.unwrap_or(raw.session_ts.unwrap_or(0)),
        unread: raw.unread_count.unwrap_or(0),
        is_pinned: raw.top_ts.unwrap_or(0) > 0,
        is_muted: loose_bool(raw.is_dnd).unwrap_or(false),
    }
}

fn decode_system_content(raw: String) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        if let Some(web) = value.get("web").and_then(Value::as_str) {
            return web.to_string();
        }
    }
    trimmed.to_string()
}

fn decode_im_message(raw: String) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        if let Some(content) = value.get("content").and_then(Value::as_str) {
            return content.to_string();
        }
        if let Some(text) = value.get("text").and_then(Value::as_str) {
            return text.to_string();
        }
    }
    trimmed.to_string()
}

fn loose_bool(value: Option<Value>) -> Option<bool> {
    match value {
        Some(Value::Bool(v)) => Some(v),
        Some(Value::Number(n)) => n.as_i64().map(|v| v != 0),
        Some(Value::String(s)) => match s.as_str() {
            "1" | "true" => Some(true),
            "0" | "false" => Some(false),
            _ => None,
        },
        _ => None,
    }
}

#[derive(Default, Deserialize)]
struct MsgFeedUnreadWire {
    reply: Option<i64>,
    at: Option<i64>,
    like: Option<i64>,
    sys_msg: Option<i64>,
}

#[derive(Default, Deserialize)]
struct SingleUnreadWire {
    follow_unread: Option<i64>,
    unfollow_unread: Option<i64>,
    unfollow_push_msg: Option<i64>,
    biz_msg_follow_unread: Option<i64>,
    biz_msg_unfollow_unread: Option<i64>,
    custom_unread: Option<i64>,
}

#[derive(Default, Deserialize)]
struct FeedCursorWire {
    is_end: Option<bool>,
    id: Option<i64>,
    time: Option<i64>,
}

#[derive(Default, Deserialize)]
struct ReplyFeedWire {
    #[serde(default)]
    cursor: Option<FeedCursorWire>,
    #[serde(default)]
    items: Vec<ReplyItemWire>,
}

#[derive(Default, Deserialize)]
struct AtFeedWire {
    #[serde(default)]
    cursor: Option<FeedCursorWire>,
    #[serde(default)]
    items: Vec<AtItemWire>,
}

#[derive(Clone, Default, Deserialize)]
struct MessageUserWire {
    mid: Option<i64>,
    nickname: Option<String>,
    avatar: Option<String>,
}

#[derive(Default, Deserialize)]
struct ReplyItemWire {
    id: Option<i64>,
    user: Option<MessageUserWire>,
    item: Option<ReplyContentWire>,
    counts: Option<i64>,
    reply_time: Option<i64>,
}

#[derive(Default, Deserialize)]
struct ReplyContentWire {
    business: Option<String>,
    native_uri: Option<String>,
    root_reply_content: Option<String>,
    source_content: Option<String>,
    target_reply_content: Option<String>,
}

#[derive(Default, Deserialize)]
struct AtItemWire {
    id: Option<i64>,
    user: Option<MessageUserWire>,
    item: Option<AtContentWire>,
    at_time: Option<i64>,
}

#[derive(Default, Deserialize)]
struct AtContentWire {
    business: Option<String>,
    image: Option<String>,
    source_content: Option<String>,
    native_uri: Option<String>,
}

#[derive(Default, Deserialize)]
struct LikeFeedWire {
    latest: Option<LikeBucketWire>,
    total: Option<LikeBucketWire>,
}

#[derive(Default, Deserialize)]
struct LikeBucketWire {
    cursor: Option<FeedCursorWire>,
    #[serde(default)]
    items: Vec<LikeItemWire>,
}

#[derive(Default, Deserialize)]
struct LikeItemWire {
    id: Option<i64>,
    #[serde(default)]
    users: Vec<MessageUserWire>,
    item: Option<LikeContentWire>,
    counts: Option<i64>,
    like_time: Option<i64>,
}

#[derive(Default, Deserialize)]
struct LikeContentWire {
    business: Option<String>,
    title: Option<String>,
    image: Option<String>,
    native_uri: Option<String>,
}

#[derive(Default, Deserialize)]
struct SystemMessageWire {
    id: Option<i64>,
    cursor: Option<i64>,
    title: Option<String>,
    content: Option<String>,
    time_at: Option<String>,
}

#[derive(Default, Deserialize)]
struct SessionListWire {
    #[serde(default)]
    session_list: Vec<SessionWire>,
    #[serde(default)]
    has_more: Option<Value>,
}

#[derive(Default, Deserialize)]
struct SessionWire {
    talker_id: Option<i64>,
    session_ts: Option<i64>,
    top_ts: Option<i64>,
    unread_count: Option<i64>,
    last_msg: Option<SessionLastMessageWire>,
    #[serde(default)]
    is_dnd: Option<Value>,
}

#[derive(Default, Deserialize)]
struct SessionLastMessageWire {
    content: Option<String>,
    timestamp: Option<i64>,
}

#[derive(Default, Deserialize)]
struct MessageUserCardWire {
    mid: Option<i64>,
    name: Option<String>,
    face: Option<String>,
}

#[derive(Default, Deserialize)]
struct NavWire {
    #[serde(default)]
    wbi_img: NavWbiImageWire,
}

#[derive(Default, Deserialize)]
struct NavWbiImageWire {
    #[serde(default)]
    img_url: String,
    #[serde(default)]
    sub_url: String,
}
