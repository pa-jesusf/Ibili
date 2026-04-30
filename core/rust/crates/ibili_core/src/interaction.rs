//! Write-action endpoints used by the video detail page:
//! like / coin / favorite / triple / follow / watch-later.
//!
//! Upstream PiliPlus uses the **app** endpoint for plain like/coin
//! (signed via `app-key` + `appkey/sign` pair) and **web** endpoints
//! (with `csrf` from the `bili_jct` cookie) for triple/fav/relation/
//! watch-later. We mirror that split — keeps each call's authentication
//! identical to upstream so server-side gating behaves the same.

use crate::Core;
use crate::dto::{ArchiveRelation, CoinResult, FavFolderInfo, FavoriteResult, LikeResult, TripleResult};
use crate::error::{CoreError, CoreResult};
use serde::Deserialize;
use serde_json::Value;

const URL_LIKE_APP: &str = "https://app.bilibili.com/x/v2/view/like";
const URL_DISLIKE_APP: &str = "https://app.bilibili.com/x/v2/view/dislike";
const URL_COIN_APP: &str = "https://app.bilibili.com/x/v2/view/coin/add";
const URL_TRIPLE_WEB: &str = "https://api.bilibili.com/x/web-interface/archive/like/triple";
const URL_FAV_DEAL: &str = "https://api.bilibili.com/x/v3/fav/resource/deal";
const URL_RELATION_MOD: &str = "https://api.bilibili.com/x/relation/modify";
const URL_WATCHLATER_ADD: &str = "https://api.bilibili.com/x/v2/history/toview/add";
const URL_WATCHLATER_DEL: &str = "https://api.bilibili.com/x/v2/history/toview/v2/dels";
const URL_ARCHIVE_RELATION: &str = "https://api.bilibili.com/x/web-interface/archive/relation";
const URL_FAV_FOLDERS: &str = "https://api.bilibili.com/x/v3/fav/folder/created/list-all";
const URL_HEARTBEAT_WEB: &str = "https://api.bilibili.com/x/click-interface/web/heartbeat";
/// Returns the current account's 稍后再看 list (capped server-side
/// at ~100 most-recent entries). Used for membership lookup so the
/// detail page can render the watch-later button in its true state
/// instead of always-off.
const URL_WATCHLATER_LIST: &str = "https://api.bilibili.com/x/v2/history/toview/web";
/// Like / un-like a single comment. Mirrors PiliPlus `ReplyHttp.likeReply`.
const URL_REPLY_ACTION: &str = "https://api.bilibili.com/x/v2/reply/action";
/// Send a danmaku for the given cid (legacy XML-style endpoint, but
/// PiliPlus and the official web client both still post here).
const URL_DM_POST: &str = "https://api.bilibili.com/x/v2/dm/post";
/// Top-level / nested comment submit. Mirrors `ReplyHttp.replyAdd`.
const URL_REPLY_ADD: &str = "https://api.bilibili.com/x/v2/reply/add";
/// Image upload for dynamic / reply attachments.
const URL_UPLOAD_BFS: &str = "https://api.bilibili.com/x/dynamic/feed/draw/upload_bfs";
/// User emote panel (business=reply for comment composer).
const URL_EMOTE_PANEL: &str = "https://api.bilibili.com/x/emote/user/panel/web";

#[derive(Default, Deserialize)]
struct ToastWire {
    #[serde(default)] toast: String,
}

#[derive(Default, Deserialize)]
struct TripleWire {
    #[serde(default)] like: bool,
    #[serde(default)] coin: bool,
    #[serde(default)] fav: bool,
    #[serde(default)] multiply: i32,
    #[serde(default)] prompt: bool,
}

#[derive(Default, Deserialize)]
struct PromptWire {
    #[serde(default)] prompt: bool,
    #[serde(default)] toast_msg: String,
}

impl Core {
    /// Toggle like state on a UGC video.
    /// `like_action` is 1 (点赞) or 2 (取消点赞).
    ///
    /// NOTE: the bilibili `app/v2/view/like` endpoint inverts the
    /// natural reading — `like=0` means "like this video", `like=1`
    /// means "cancel like". Upstream PiliPlus encodes it as
    /// `type ? '0' : '1'` where `type = !hasLike`. We translate our
    /// caller-friendly 1/2 codes here so callers don't need to know.
    pub fn archive_like(&self, aid: i64, like_action: i32) -> CoreResult<LikeResult> {
        let access_key = self.session.read().access_key().ok_or(CoreError::AuthRequired)?;
        let want_like = like_action != 2;
        let like_param = if want_like { "0" } else { "1" };
        let params: Vec<(String, String)> = vec![
            ("access_key".into(), access_key),
            ("aid".into(), aid.to_string()),
            ("like".into(), like_param.into()),
        ];
        let _: Value = self.http.post_signed_app(URL_LIKE_APP, params)?;
        Ok(LikeResult { liked: if want_like { 1 } else { 0 }, toast: String::new() })
    }

    /// App-flavoured 点踩 endpoint (web does not support dislike).
    pub fn archive_dislike(&self, aid: i64) -> CoreResult<()> {
        let access_key = self.session.read().access_key().ok_or(CoreError::AuthRequired)?;
        let params: Vec<(String, String)> = vec![
            ("access_key".into(), access_key),
            ("aid".into(), aid.to_string()),
        ];
        let _: Value = self.http.post_signed_app(URL_DISLIKE_APP, params)?;
        Ok(())
    }

    /// Add `multiply` (1 or 2) coins, optionally also liking the video.
    pub fn archive_coin(&self, aid: i64, multiply: i32, also_like: bool) -> CoreResult<CoinResult> {
        let access_key = self.session.read().access_key().ok_or(CoreError::AuthRequired)?;
        let multiply = multiply.clamp(1, 2);
        let params: Vec<(String, String)> = vec![
            ("access_key".into(), access_key),
            ("aid".into(), aid.to_string()),
            ("multiply".into(), multiply.to_string()),
            ("select_like".into(), if also_like { "1".into() } else { "0".into() }),
        ];
        let raw: ToastWire = self.http.post_signed_app(URL_COIN_APP, params)?;
        Ok(CoinResult { like: also_like, toast: raw.toast })
    }

    /// One-click 三连 — applies like+coin(2)+fav atomically server-side.
    pub fn archive_triple(&self, aid: i64) -> CoreResult<TripleResult> {
        let csrf = self.http.csrf_token().ok_or(CoreError::AuthRequired)?;
        // Upstream PiliPlus sends these extra params; the like leg of the
        // triple endpoint silently no-ops without `eab_x/ramval/source/ga`.
        let params: Vec<(String, String)> = vec![
            ("aid".into(), aid.to_string()),
            ("eab_x".into(), "2".into()),
            ("ramval".into(), "0".into()),
            ("source".into(), "web_normal".into()),
            ("ga".into(), "1".into()),
            ("spmid".into(), "333.788.0.0".into()),
            ("statistics".into(), "{\"appId\":100,\"platform\":5}".into()),
            ("csrf".into(), csrf),
        ];
        let raw: TripleWire = self.http.post_form_web(URL_TRIPLE_WEB, &params)?;
        Ok(TripleResult {
            like: raw.like,
            coin: raw.coin,
            fav: raw.fav,
            multiply: raw.multiply,
            prompt: raw.prompt,
        })
    }

    /// Add/remove a video from one or more favourite folders.
    /// `add_ids` and `del_ids` are media_ids; comma-joined server-side.
    pub fn archive_favorite(&self, aid: i64, add_ids: &[i64], del_ids: &[i64]) -> CoreResult<FavoriteResult> {
        let csrf = self.http.csrf_token().ok_or(CoreError::AuthRequired)?;
        let join = |xs: &[i64]| -> String {
            xs.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(",")
        };
        let params: Vec<(String, String)> = vec![
            ("rid".into(), aid.to_string()),
            ("type".into(), "2".into()), // 2 = video
            ("add_media_ids".into(), join(add_ids)),
            ("del_media_ids".into(), join(del_ids)),
            ("csrf".into(), csrf),
        ];
        let raw: PromptWire = self.http.post_form_web(URL_FAV_DEAL, &params)?;
        Ok(FavoriteResult { prompt: raw.prompt, toast: raw.toast_msg })
    }

    /// Follow / unfollow a user. `act` is 1 (关注) or 2 (取消关注).
    pub fn relation_modify(&self, fid: i64, act: i32) -> CoreResult<()> {
        let csrf = self.http.csrf_token().ok_or(CoreError::AuthRequired)?;
        let act = if act == 2 { 2 } else { 1 };
        let params: Vec<(String, String)> = vec![
            ("fid".into(), fid.to_string()),
            ("act".into(), act.to_string()),
            ("re_src".into(), "11".into()),
            ("csrf".into(), csrf),
        ];
        let _: Value = self.http.post_form_web(URL_RELATION_MOD, &params)?;
        Ok(())
    }

    /// Add a video to the 稍后再看 list.
    pub fn watchlater_add(&self, aid: i64) -> CoreResult<()> {
        let csrf = self.http.csrf_token().ok_or(CoreError::AuthRequired)?;
        let params: Vec<(String, String)> = vec![
            ("aid".into(), aid.to_string()),
            ("csrf".into(), csrf),
        ];
        let _: Value = self.http.post_form_web(URL_WATCHLATER_ADD, &params)?;
        Ok(())
    }

    /// Remove a video from the 稍后再看 list.
    pub fn watchlater_del(&self, aid: i64) -> CoreResult<()> {
        let csrf = self.http.csrf_token().ok_or(CoreError::AuthRequired)?;
        let params: Vec<(String, String)> = vec![
            ("aids".into(), aid.to_string()),
            ("csrf".into(), csrf),
        ];
        let _: Value = self.http.post_form_web(URL_WATCHLATER_DEL, &params)?;
        Ok(())
    }

    /// Read the current account's like/coin/favorite/follow state for
    /// a given video. Backed by `/x/web-interface/archive/relation`.
    /// Returns a default-zero struct when the user is not logged in.
    pub fn archive_relation(&self, aid: i64, bvid: &str) -> CoreResult<ArchiveRelation> {
        if self.session.read().access_key().is_none() {
            return Ok(ArchiveRelation::default());
        }
        let mut params: Vec<(String, String)> = Vec::new();
        if aid > 0 { params.push(("aid".into(), aid.to_string())); }
        if !bvid.is_empty() { params.push(("bvid".into(), bvid.to_string())); }
        let raw: ArchiveRelationWire = self.http.get_web(URL_ARCHIVE_RELATION, &params)?;
        Ok(ArchiveRelation {
            liked: raw.like.unwrap_or(false),
            disliked: raw.dislike.unwrap_or(false),
            favorited: raw.favorite.unwrap_or(false),
            attention: raw.attention.unwrap_or(false),
            coin_number: raw.coin.unwrap_or(0),
        })
    }

    /// List all favourite folders the current user owns. When `rid`
    /// (an aid) is non-zero each entry's `fav_state` reflects whether
    /// the video is already in that folder. Backed by
    /// `/x/v3/fav/folder/created/list-all`.
    pub fn fav_folders(&self, rid: i64, up_mid: i64) -> CoreResult<Vec<FavFolderInfo>> {
        if self.session.read().access_key().is_none() {
            return Ok(Vec::new());
        }
        let mut params: Vec<(String, String)> = vec![
            ("type".into(), "2".into()),
            ("up_mid".into(), up_mid.to_string()),
        ];
        if rid > 0 { params.push(("rid".into(), rid.to_string())); }
        let raw: FavFoldersWire = self.http.get_web(URL_FAV_FOLDERS, &params)?;
        Ok(raw.list.into_iter().map(|f| FavFolderInfo {
            id: f.id,
            fid: f.fid.unwrap_or(0),
            mid: f.mid,
            attr: f.attr,
            title: f.title,
            fav_state: f.fav_state.unwrap_or(0),
            media_count: f.media_count,
        }).collect())
    }

    /// Report a UGC playback heartbeat so Bilibili records the
    /// position into the user's history. Mirrors PiliPlus
    /// `VideoHttp.heartBeat` with `type=3` (ugc) and uses the *web*
    /// session csrf — the field comes from the `bili_jct` cookie.
    /// `played_seconds` is the current playback time in seconds.
    /// Returns Ok(()) when the user is not logged in (no-op).
    pub fn archive_heartbeat(
        &self,
        aid: i64,
        bvid: &str,
        cid: i64,
        played_seconds: i64,
    ) -> CoreResult<()> {
        let Some(csrf) = self.http.csrf_token() else { return Ok(()); };
        let mut params: Vec<(String, String)> = vec![
            ("cid".into(), cid.to_string()),
            ("type".into(), "3".into()),
            ("played_time".into(), played_seconds.max(0).to_string()),
            ("csrf".into(), csrf),
        ];
        // Upstream sends `bvid` only — we send whichever identifier
        // the caller has. Both being present is harmless.
        if !bvid.is_empty() { params.push(("bvid".into(), bvid.to_string())); }
        if aid > 0 { params.push(("aid".into(), aid.to_string())); }
        let _: Value = self.http.post_form_web(URL_HEARTBEAT_WEB, &params)?;
        Ok(())
    }

    /// Fetch the aids currently in the user's 稍后再看 list. Returns an
    /// empty vec for anonymous sessions. Used by the detail page to
    /// initialize the watch-later button's active state on hydrate.
    pub fn watchlater_aids(&self) -> CoreResult<Vec<i64>> {
        if self.session.read().access_key().is_none() {
            return Ok(Vec::new());
        }
        let raw: WatchLaterListWire = self.http.get_web(URL_WATCHLATER_LIST, &[])?;
        Ok(raw.list.into_iter().map(|item| item.aid).collect())
    }

    /// Like / un-like a comment. `action` is 1 (点赞) or 0 (取消点赞).
    /// `kind` is the reply type (1 = video). Mirrors PiliPlus.
    pub fn reply_like(&self, oid: i64, kind: i32, rpid: i64, action: i32) -> CoreResult<()> {
        let csrf = self.http.csrf_token().ok_or(CoreError::AuthRequired)?;
        let action = if action == 0 { 0 } else { 1 };
        let params: Vec<(String, String)> = vec![
            ("type".into(), kind.to_string()),
            ("oid".into(), oid.to_string()),
            ("rpid".into(), rpid.to_string()),
            ("action".into(), action.to_string()),
            ("csrf".into(), csrf),
        ];
        let _: Value = self.http.post_form_web(URL_REPLY_ACTION, &params)?;
        Ok(())
    }

    /// Post a danmaku to the given cid. `progress_ms` is the playback
    /// position in milliseconds, `mode` is the scroll mode (1 = roll,
    /// 4 = bottom, 5 = top), `color` is RGB packed (e.g. 16777215 = white),
    /// `fontsize` is 25 (standard) or 18 (small).
    pub fn send_danmaku(
        &self,
        aid: i64,
        cid: i64,
        msg: &str,
        progress_ms: i64,
        mode: i32,
        color: i32,
        fontsize: i32,
    ) -> CoreResult<()> {
        let csrf = self.http.csrf_token().ok_or(CoreError::AuthRequired)?;
        let params: Vec<(String, String)> = vec![
            ("type".into(), "1".into()),
            ("oid".into(), cid.to_string()),
            ("aid".into(), aid.to_string()),
            ("msg".into(), msg.to_string()),
            ("progress".into(), progress_ms.to_string()),
            ("color".into(), color.to_string()),
            ("fontsize".into(), fontsize.to_string()),
            ("mode".into(), mode.to_string()),
            ("pool".into(), "0".into()),
            ("plat".into(), "1".into()),
            ("csrf".into(), csrf),
        ];
        let _: Value = self.http.post_form_web(URL_DM_POST, &params)?;
        Ok(())
    }

    /// Submit a top-level / nested comment.
    ///
    /// `pictures` is a list of `{img_src, img_width, img_height,
    /// img_size}` objects produced by `upload_bfs`. We *never* set
    /// `sync_to_dynamic` — comments must not leak to the user's
    /// dynamic feed.
    pub fn reply_add(
        &self,
        oid: i64,
        kind: i32,
        message: &str,
        root: i64,
        parent: i64,
        pictures: Vec<crate::dto::ReplyPicture>,
    ) -> CoreResult<crate::dto::ReplyAddResult> {
        let csrf = self.http.csrf_token().ok_or(CoreError::AuthRequired)?;
        let mut params: Vec<(String, String)> = vec![
            ("type".into(), kind.to_string()),
            ("oid".into(), oid.to_string()),
            ("message".into(), message.to_string()),
            ("plat".into(), "1".into()),
            ("csrf".into(), csrf),
        ];
        if root != 0 {
            params.push(("root".into(), root.to_string()));
        }
        if parent != 0 {
            params.push(("parent".into(), parent.to_string()));
        }
        if !pictures.is_empty() {
            let json = serde_json::to_string(&pictures)
                .map_err(|e| CoreError::Decode(e.to_string()))?;
            params.push(("pictures".into(), json));
        }
        #[derive(Default, Deserialize)]
        struct Wire {
            #[serde(default)] rpid: i64,
            #[serde(default)] success_toast: String,
        }
        let raw: Wire = self.http.post_form_web(URL_REPLY_ADD, &params)?;
        Ok(crate::dto::ReplyAddResult {
            rpid: raw.rpid,
            toast: raw.success_toast,
        })
    }

    /// Upload an image to bfs (used by reply / dynamic attachments).
    /// `bytes` is the raw image data, `file_name` is used solely to
    /// hint a content type.
    pub fn upload_bfs(
        &self,
        bytes: Vec<u8>,
        file_name: String,
        biz: &str,
        category: &str,
    ) -> CoreResult<crate::dto::UploadedImage> {
        let csrf = self.http.csrf_token().ok_or(CoreError::AuthRequired)?;
        #[derive(Default, Deserialize)]
        struct Wire {
            #[serde(default)] image_url: String,
            #[serde(default)] image_width: i32,
            #[serde(default)] image_height: i32,
            #[serde(default)] img_size: f64,
        }
        let raw: Wire = self.http.post_multipart_web(
            URL_UPLOAD_BFS,
            &[
                ("biz", biz.to_string()),
                ("category", category.to_string()),
                ("csrf", csrf),
            ],
            "file_up",
            file_name,
            bytes,
        )?;
        Ok(crate::dto::UploadedImage {
            url: raw.image_url,
            width: raw.image_width,
            height: raw.image_height,
            size: raw.img_size,
        })
    }

    /// Fetch the user's emote panel (sticker packages). `business` is
    /// `reply` for the comment composer; the panel can also drive the
    /// dynamic composer with `dynamic` but we don't expose that yet.
    pub fn emote_panel(&self, business: &str) -> CoreResult<Vec<crate::dto::EmotePackage>> {
        #[derive(Default, Deserialize)]
        struct Root {
            #[serde(default)] packages: Vec<RawPackage>,
        }
        #[derive(Default, Deserialize)]
        struct RawPackage {
            #[serde(default)] id: i64,
            #[serde(default)] text: String,
            #[serde(default)] url: String,
            #[serde(default)] r#type: i32,
            #[serde(default)] emote: Vec<RawEmote>,
        }
        #[derive(Default, Deserialize)]
        struct RawEmote {
            #[serde(default)] text: String,
            #[serde(default)] url: String,
        }
        let params: Vec<(String, String)> = vec![
            ("business".into(), business.to_string()),
            ("web_location".into(), "333.1245".into()),
        ];
        let raw: Root = self.http.get_web(URL_EMOTE_PANEL, &params)?;
        Ok(raw.packages.into_iter().map(|p| crate::dto::EmotePackage {
            id: p.id,
            text: p.text,
            url: p.url,
            kind: p.r#type,
            emotes: p.emote.into_iter()
                .map(|e| crate::dto::Emote { text: e.text, url: e.url })
                .collect(),
        }).collect())
    }
}

#[derive(Default, Deserialize)]
struct WatchLaterListWire {
    #[serde(default, deserialize_with = "null_as_empty_vec")]
    list: Vec<WatchLaterItemWire>,
}

#[derive(Default, Deserialize)]
struct WatchLaterItemWire {
    #[serde(default)] aid: i64,
}

fn null_as_empty_vec<'de, D, T>(de: D) -> Result<Vec<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::Deserialize<'de>,
{
    Ok(Option::<Vec<T>>::deserialize(de)?.unwrap_or_default())
}

#[derive(Default, Deserialize)]
struct ArchiveRelationWire {
    /// Bilibili returns ints (0/1) most of the time but PiliPlus
    /// observed booleans on some endpoints — accept either via
    /// `IntOrBool`.
    #[serde(default, deserialize_with = "deser_loose_bool")]
    like: Option<bool>,
    #[serde(default, deserialize_with = "deser_loose_bool")]
    dislike: Option<bool>,
    #[serde(default, deserialize_with = "deser_loose_bool")]
    favorite: Option<bool>,
    /// Web returns `true`/`false`; legacy app payloads sometimes use
    /// `-999` (not following) / >=0 (followed).
    #[serde(default, deserialize_with = "deser_attention")]
    attention: Option<bool>,
    #[serde(default)]
    coin: Option<i32>,
}

fn deser_attention<'de, D>(d: D) -> Result<Option<bool>, D::Error>
where D: serde::Deserializer<'de> {
    use serde::de::Error;
    let v = Option::<Value>::deserialize(d)?;
    Ok(match v {
        Some(Value::Bool(b)) => Some(b),
        // App-style: -999 means not following; >= 0 means followed.
        Some(Value::Number(n)) => n.as_i64().map(|x| x >= 0),
        Some(Value::Null) | None => None,
        Some(other) => return Err(D::Error::custom(format!("expected bool|int, got {other}"))),
    })
}

fn deser_loose_bool<'de, D>(d: D) -> Result<Option<bool>, D::Error>
where D: serde::Deserializer<'de> {
    use serde::de::Error;
    let v = Option::<Value>::deserialize(d)?;
    Ok(match v {
        Some(Value::Bool(b)) => Some(b),
        Some(Value::Number(n)) => n.as_i64().map(|x| x != 0),
        Some(Value::Null) | None => None,
        Some(other) => return Err(D::Error::custom(format!("expected bool|int, got {other}"))),
    })
}

#[derive(Default, Deserialize)]
struct FavFoldersWire {
    #[serde(default)]
    list: Vec<FavFolderWire>,
}

#[derive(Default, Deserialize)]
struct FavFolderWire {
    #[serde(default)] id: i64,
    #[serde(default)] fid: Option<i64>,
    #[serde(default)] mid: i64,
    #[serde(default)] attr: i32,
    #[serde(default)] title: String,
    #[serde(default)] fav_state: Option<i32>,
    #[serde(default)] media_count: i32,
}
