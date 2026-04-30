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
        let params: Vec<(String, String)> = vec![
            ("aid".into(), aid.to_string()),
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
