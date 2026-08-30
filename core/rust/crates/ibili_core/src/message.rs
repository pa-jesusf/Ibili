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
const URL_MSG_REPLY: &str = "https://api.bilibili.com/x/msgfeed/reply";
const URL_MSG_AT: &str = "https://api.bilibili.com/x/msgfeed/at";
const URL_MSG_LIKE: &str = "https://api.bilibili.com/x/msgfeed/like";
const URL_MSG_SYS: &str = "https://message.bilibili.com/x/sys-msg/query_notify_list";
const URL_SESSION_LIST: &str =
    "https://api.vc.bilibili.com/session_svr/v1/session_svr/get_sessions";
const URL_SESSION_ACCOUNTS: &str = "https://api.vc.bilibili.com/account/v1/user/cards";
const URL_SESSION_MESSAGES: &str =
    "https://api.vc.bilibili.com/svr_sync/v1/svr_sync/fetch_session_msgs";
const URL_SESSION_ACK: &str = "https://api.vc.bilibili.com/session_svr/v1/session_svr/update_ack";
const GRPC_SEND_MESSAGE: &str = "/bilibili.im.interface.v1.ImInterface/SendMsg";

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcSendMessageRequest {
    #[prost(message, optional, tag = "1")]
    message: Option<GrpcIMMessage>,
    #[prost(string, tag = "5")]
    device_id: String,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcIMMessage {
    #[prost(int64, tag = "1")]
    sender_uid: i64,
    #[prost(int32, tag = "2")]
    receiver_type: i32,
    #[prost(int64, tag = "3")]
    receiver_id: i64,
    #[prost(int32, tag = "5")]
    message_type: i32,
    #[prost(string, tag = "6")]
    content: String,
    #[prost(int64, tag = "8")]
    timestamp: i64,
    #[prost(int32, tag = "12")]
    message_status: i32,
    #[prost(int32, tag = "16")]
    new_face_version: i32,
}

#[derive(Clone, PartialEq, prost::Message)]
struct GrpcSendMessageReply {
    #[prost(int64, tag = "1")]
    message_key: i64,
    #[prost(string, tag = "3")]
    message_content: String,
    #[prost(int64, tag = "6")]
    sequence: i64,
}

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
    pub subject_id: i64,
    pub business_id: i64,
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

#[derive(Debug, Serialize, Clone)]
pub struct MessageChatItem {
    pub id: String,
    pub sender_id: i64,
    pub is_self: bool,
    pub kind: String,
    pub text: String,
    pub image: String,
    pub timestamp: i64,
    pub sequence: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct MessageConversationPage {
    pub items: Vec<MessageChatItem>,
    pub next_sequence: i64,
    pub ack_sequence: i64,
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
        let total = feed.reply.unwrap_or(0)
            + feed.at.unwrap_or(0)
            + feed.like.unwrap_or(0)
            + feed.sys_msg.unwrap_or(0);
        Ok(MessageUnreadSummary {
            reply: feed.reply.unwrap_or(0),
            at: feed.at.unwrap_or(0),
            like: feed.like.unwrap_or(0),
            sys_msg: feed.sys_msg.unwrap_or(0),
            whisper: 0,
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

    pub fn message_conversation(
        &self,
        talker_id: i64,
        end_sequence: i64,
    ) -> CoreResult<MessageConversationPage> {
        if talker_id <= 0 {
            return Ok(MessageConversationPage {
                items: vec![],
                next_sequence: 0,
                ack_sequence: 0,
                has_more: false,
            });
        }
        let self_mid = self.session.read().snapshot().mid;
        if self_mid <= 0 {
            return Ok(MessageConversationPage {
                items: vec![],
                next_sequence: 0,
                ack_sequence: 0,
                has_more: false,
            });
        }

        let key = self.fetch_wbi_key_for_message()?;
        let mut params = vec![
            ("talker_id".into(), talker_id.to_string()),
            ("session_type".into(), "1".into()),
            ("size".into(), "30".into()),
            ("sender_device_id".into(), "1".into()),
            ("build".into(), "0".into()),
            ("mobi_app".into(), "web".into()),
            ("web_location".into(), "333.1296".into()),
        ];
        if end_sequence > 0 {
            params.push(("end_seqno".into(), end_sequence.to_string()));
        }
        let raw: SessionMessagesWire =
            self.http
                .get_signed_web(URL_SESSION_MESSAGES, params, &key)?;
        let ack_sequence = raw.max_seqno.unwrap_or_else(|| {
            raw.messages
                .iter()
                .filter_map(|item| item.msg_seqno)
                .max()
                .unwrap_or(0)
        });
        let next_sequence = raw.min_seqno.unwrap_or_else(|| {
            raw.messages
                .iter()
                .filter_map(|item| item.msg_seqno)
                .min()
                .unwrap_or(0)
        });
        let items = raw
            .messages
            .into_iter()
            .filter(|item| item.msg_type.unwrap_or(0) != 5)
            .map(|item| message_chat_item_from_wire(item, self_mid))
            .collect();
        Ok(MessageConversationPage {
            items,
            next_sequence,
            ack_sequence,
            has_more: loose_bool(raw.has_more).unwrap_or(false),
        })
    }

    pub fn message_ack_conversation(&self, talker_id: i64, ack_sequence: i64) -> CoreResult<()> {
        if talker_id <= 0 || ack_sequence <= 0 {
            return Ok(());
        }
        let key = self.fetch_wbi_key_for_message()?;
        let csrf = self.http.csrf_token().unwrap_or_default();
        let params = vec![
            ("talker_id".into(), talker_id.to_string()),
            ("session_type".into(), "1".into()),
            ("ack_seqno".into(), ack_sequence.to_string()),
            ("build".into(), "0".into()),
            ("mobi_app".into(), "web".into()),
            ("csrf_token".into(), csrf.clone()),
            ("csrf".into(), csrf),
        ];
        let _: Value = self.http.get_signed_web(URL_SESSION_ACK, params, &key)?;
        Ok(())
    }

    pub fn message_send_text(&self, talker_id: i64, message: &str) -> CoreResult<MessageChatItem> {
        let text = message.trim();
        if talker_id <= 0 {
            return Err(crate::error::CoreError::InvalidArgument(
                "talker_id invalid".into(),
            ));
        }
        if text.is_empty() {
            return Err(crate::error::CoreError::InvalidArgument(
                "message is empty".into(),
            ));
        }
        let sender_id = self.session.read().snapshot().mid;
        if sender_id <= 0 {
            return Err(crate::error::CoreError::AuthRequired);
        }
        let timestamp = unix_timestamp();
        let encoded_content = serde_json::json!({ "content": text }).to_string();
        let request = GrpcSendMessageRequest {
            message: Some(GrpcIMMessage {
                sender_uid: sender_id,
                receiver_type: 1,
                receiver_id: talker_id,
                message_type: 1,
                content: encoded_content,
                timestamp,
                message_status: 0,
                new_face_version: 1,
            }),
            device_id: message_device_id(),
        };
        let response: GrpcSendMessageReply =
            self.grpc_request(GRPC_SEND_MESSAGE, &request, true)?;
        let response_text = if response.message_content.is_empty() {
            text.to_string()
        } else {
            decode_im_content(&response.message_content, 1).text
        };
        Ok(MessageChatItem {
            id: if response.message_key > 0 {
                response.message_key.to_string()
            } else {
                format!("sent-{timestamp}-{}", response.sequence)
            },
            sender_id,
            is_self: true,
            kind: "text".into(),
            text: if response_text.is_empty() {
                text.to_string()
            } else {
                response_text
            },
            image: String::new(),
            timestamp,
            sequence: response.sequence,
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
        subject_id: item.subject_id.unwrap_or(0),
        business_id: item.business_id.unwrap_or(0),
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
        subject_id: 0,
        business_id: 0,
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
        subject_id: 0,
        business_id: 0,
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
        subject_id: 0,
        business_id: 0,
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

fn message_chat_item_from_wire(raw: SessionMessageWire, self_mid: i64) -> MessageChatItem {
    let message_type = raw.msg_type.unwrap_or_default();
    let content = decode_im_content(&raw.content.unwrap_or_default(), message_type);
    let sequence = raw.msg_seqno.unwrap_or_default();
    let message_key = raw.msg_key.unwrap_or_default();
    let sender_id = raw.sender_uid.unwrap_or_default();
    MessageChatItem {
        id: if message_key > 0 {
            message_key.to_string()
        } else {
            sequence.to_string()
        },
        sender_id,
        is_self: sender_id == self_mid,
        kind: content.kind,
        text: content.text,
        image: content.image,
        timestamp: raw.timestamp.unwrap_or_default(),
        sequence,
    }
}

#[derive(Default)]
struct DecodedImContent {
    kind: String,
    text: String,
    image: String,
}

fn decode_im_content(raw: &str, message_type: i32) -> DecodedImContent {
    let trimmed = raw.trim();
    let value = serde_json::from_str::<Value>(trimmed).unwrap_or(Value::Null);
    let string = |names: &[&str]| -> String {
        names
            .iter()
            .find_map(|name| value.get(*name).and_then(Value::as_str))
            .unwrap_or_default()
            .to_string()
    };

    match message_type {
        1 => DecodedImContent {
            kind: "text".into(),
            text: string(&["content", "text"]),
            image: String::new(),
        },
        2 | 6 => DecodedImContent {
            kind: "image".into(),
            text: String::new(),
            image: string(&["url", "image_url", "original"]),
        },
        18 => DecodedImContent {
            kind: "notice".into(),
            text: decode_im_notice(&value),
            image: String::new(),
        },
        _ => {
            let title = string(&["title", "headline", "source"]);
            let description = string(&["desc", "description", "content", "text"]);
            let text = [title, description]
                .into_iter()
                .filter(|part| !part.is_empty())
                .collect::<Vec<_>>()
                .join("\n");
            DecodedImContent {
                kind: "card".into(),
                text: if text.is_empty() {
                    decode_im_message(trimmed.to_string())
                } else {
                    text
                },
                image: string(&["cover", "image", "thumb", "url"]),
            }
        }
    }
}

fn decode_im_notice(value: &Value) -> String {
    let content = value.get("content").unwrap_or(value);
    decode_im_notice_value(content)
}

fn decode_im_notice_value(value: &Value) -> String {
    match value {
        Value::Array(items) => items
            .iter()
            .map(decode_im_notice_value)
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>()
            .join("\n"),
        Value::Object(object) => object
            .get("text")
            .or_else(|| object.get("content"))
            .map(decode_im_notice_value)
            .unwrap_or_default(),
        Value::String(text) => serde_json::from_str::<Value>(text)
            .ok()
            .map(|nested| decode_im_notice_value(&nested))
            .filter(|decoded| !decoded.is_empty())
            .unwrap_or_else(|| text.clone()),
        _ => String::new(),
    }
}

fn unix_timestamp() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}

fn message_device_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let mut seed = (unix_timestamp() as u64)
        ^ COUNTER.fetch_add(1, Ordering::Relaxed)
        ^ (std::process::id() as u64).rotate_left(17);
    let mut bytes = [0u8; 16];
    for byte in &mut bytes {
        seed = seed
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        *byte = (seed >> 32) as u8;
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    )
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

fn null_as_default<'de, D, T>(de: D) -> Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Default + Deserialize<'de>,
{
    Ok(Option::<T>::deserialize(de)?.unwrap_or_default())
}

#[derive(Default, Deserialize)]
struct MsgFeedUnreadWire {
    reply: Option<i64>,
    at: Option<i64>,
    like: Option<i64>,
    sys_msg: Option<i64>,
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
    subject_id: Option<i64>,
    business_id: Option<i64>,
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
struct SessionMessagesWire {
    #[serde(default, deserialize_with = "null_as_default")]
    messages: Vec<SessionMessageWire>,
    #[serde(default)]
    has_more: Option<Value>,
    min_seqno: Option<i64>,
    max_seqno: Option<i64>,
}

#[derive(Default, Deserialize)]
struct SessionMessageWire {
    sender_uid: Option<i64>,
    msg_type: Option<i32>,
    content: Option<String>,
    msg_seqno: Option<i64>,
    timestamp: Option<i64>,
    msg_key: Option<i64>,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reply_notification_preserves_navigation_ids() {
        let raw: ReplyItemWire = serde_json::from_value(serde_json::json!({
            "id": 7,
            "item": {
                "subject_id": 123,
                "business_id": 1,
                "native_uri": "bilibili://video/123?comment_root_id=456"
            }
        }))
        .unwrap();

        let item = message_item_from_reply(raw);
        assert_eq!(item.subject_id, 123);
        assert_eq!(item.business_id, 1);
        assert_eq!(item.native_uri, "bilibili://video/123?comment_root_id=456");
    }

    #[test]
    fn conversation_content_decodes_text_image_and_notice() {
        let text = decode_im_content(r#"{"content":"hello"}"#, 1);
        let image = decode_im_content(r#"{"url":"https://example.com/a.jpg"}"#, 2);
        let notice = decode_im_content(r#"{"content":[{"text":"one"},{"text":"two"}]}"#, 18);
        let encoded_notice = decode_im_content(
            r##"{"content":"[{\"text\":\"first\",\"color_day\":\"#9499A0\"},{\"text\":\"second\"}]"}"##,
            18,
        );

        assert_eq!(text.kind, "text");
        assert_eq!(text.text, "hello");
        assert_eq!(image.kind, "image");
        assert_eq!(image.image, "https://example.com/a.jpg");
        assert_eq!(notice.kind, "notice");
        assert_eq!(notice.text, "one\ntwo");
        assert_eq!(encoded_notice.kind, "notice");
        assert_eq!(encoded_notice.text, "first\nsecond");
    }

    #[test]
    fn conversation_messages_accept_null_list() {
        let page: SessionMessagesWire = serde_json::from_value(serde_json::json!({
            "messages": null,
            "has_more": 0
        }))
        .unwrap();

        assert!(page.messages.is_empty());
        assert_eq!(loose_bool(page.has_more), Some(false));
    }

    #[test]
    fn send_message_request_matches_upstream_im_shape() {
        use prost::Message;

        let request = GrpcSendMessageRequest {
            message: Some(GrpcIMMessage {
                sender_uid: 1,
                receiver_type: 1,
                receiver_id: 2,
                message_type: 1,
                content: r#"{"content":"hello"}"#.into(),
                timestamp: 3,
                message_status: 0,
                new_face_version: 1,
            }),
            device_id: message_device_id(),
        };
        let decoded = GrpcSendMessageRequest::decode(request.encode_to_vec().as_slice()).unwrap();
        let message = decoded.message.unwrap();
        assert_eq!(message.sender_uid, 1);
        assert_eq!(message.receiver_id, 2);
        assert_eq!(message.content, r#"{"content":"hello"}"#);
        assert_eq!(decoded.device_id.len(), 36);
    }
}
