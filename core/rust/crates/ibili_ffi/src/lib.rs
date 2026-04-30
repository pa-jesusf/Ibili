//! C ABI exposing [`ibili_core`] through a single JSON dispatch entry.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use ibili_core::{Core, CoreError};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Opaque handle.
pub struct IbiliCore {
    inner: Core,
}

/// Create a core. Returns null on failure.
#[no_mangle]
pub extern "C" fn ibili_core_new(config_json: *const c_char) -> *mut IbiliCore {
    let cfg = if config_json.is_null() { "{}".to_string() } else {
        match unsafe { CStr::from_ptr(config_json) }.to_str() {
            Ok(s) => s.to_owned(),
            Err(_) => return ptr::null_mut(),
        }
    };
    match Core::new(&cfg) {
        Ok(inner) => Box::into_raw(Box::new(IbiliCore { inner })),
        Err(_) => ptr::null_mut(),
    }
}

/// Destroy a core handle.
#[no_mangle]
pub extern "C" fn ibili_core_free(core: *mut IbiliCore) {
    if !core.is_null() {
        unsafe { drop(Box::from_raw(core)); }
    }
}

/// Free a string previously returned by ibili_call / ibili_core_*.
#[no_mangle]
pub extern "C" fn ibili_string_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)); }
    }
}

/// Dispatch a method by name. Returns a freshly-allocated JSON string
/// `{ "ok": bool, "data": ..., "error": { "category": "...", "message": "...", "code": ?} }`.
/// Caller MUST free with `ibili_string_free`.
#[no_mangle]
pub extern "C" fn ibili_call(
    core: *mut IbiliCore,
    method: *const c_char,
    args_json: *const c_char,
) -> *mut c_char {
    let resp = match dispatch(core, method, args_json) {
        Ok(v) => json!({ "ok": true, "data": v }),
        Err(e) => {
            let env = ibili_core::error::ErrorEnvelope::from(&e);
            json!({ "ok": false, "error": env })
        }
    };
    let s = serde_json::to_string(&resp).unwrap_or_else(|_| "{\"ok\":false}".into());
    CString::new(s).unwrap().into_raw()
}

fn dispatch(
    core: *mut IbiliCore,
    method: *const c_char,
    args_json: *const c_char,
) -> Result<Value, CoreError> {
    if core.is_null() { return Err(CoreError::InvalidArgument("null core".into())); }
    let core = unsafe { &*core };
    let method = unsafe { CStr::from_ptr(method) }.to_str()
        .map_err(|_| CoreError::InvalidArgument("method utf8".into()))?;
    let args: Value = if args_json.is_null() {
        Value::Object(Default::default())
    } else {
        let s = unsafe { CStr::from_ptr(args_json) }.to_str()
            .map_err(|_| CoreError::InvalidArgument("args utf8".into()))?;
        if s.is_empty() { Value::Object(Default::default()) }
        else { serde_json::from_str(s)? }
    };
    handle(core, method, args)
}

#[derive(Deserialize)]
struct PollArgs { auth_code: String }

#[derive(Deserialize)]
struct FeedArgs { #[serde(default)] idx: i64, #[serde(default = "default_ps")] ps: i64 }
fn default_ps() -> i64 { 20 }

#[derive(Deserialize)]
struct PlayurlArgs { aid: i64, cid: i64, #[serde(default = "default_qn")] qn: i64, #[serde(default)] audio_qn: i64 }
fn default_qn() -> i64 { 0 }

#[derive(Deserialize)]
struct DanmakuArgs {
    cid: i64,
    #[serde(default)] duration_sec: i64,
}

#[derive(Deserialize)]
struct VideoViewArgs {
    #[serde(default)] aid: i64,
    #[serde(default)] bvid: String,
}

#[derive(Deserialize)]
struct ReplyMainArgs {
    oid: i64,
    #[serde(default = "default_reply_type")] kind: i32,
    #[serde(default = "default_reply_sort")] sort: i32,
    #[serde(default)] next_offset: String,
}
fn default_reply_type() -> i32 { 1 }
fn default_reply_sort() -> i32 { 1 }

#[derive(Deserialize)]
struct ReplyDetailArgs {
    oid: i64,
    #[serde(default = "default_reply_type")] kind: i32,
    root: i64,
    #[serde(default = "default_page")] page: i64,
}
fn default_page() -> i64 { 1 }

#[derive(Deserialize)]
struct AidArgs { aid: i64 }

#[derive(Deserialize)]
struct LikeArgs { aid: i64, #[serde(default = "default_like_action")] action: i32 }
fn default_like_action() -> i32 { 1 }

#[derive(Deserialize)]
struct CoinArgs {
    aid: i64,
    #[serde(default = "default_multiply")] multiply: i32,
    #[serde(default)] also_like: bool,
}
fn default_multiply() -> i32 { 1 }

#[derive(Deserialize)]
struct FavoriteArgs {
    aid: i64,
    #[serde(default)] add_ids: Vec<i64>,
    #[serde(default)] del_ids: Vec<i64>,
}

#[derive(Deserialize)]
struct RelationArgs { fid: i64, #[serde(default = "default_relation_act")] act: i32 }
fn default_relation_act() -> i32 { 1 }

#[derive(Deserialize)]
struct FavFoldersArgs {
    #[serde(default)] rid: i64,
    up_mid: i64,
}

#[derive(Deserialize)]
struct HeartbeatArgs {
    #[serde(default)] aid: i64,
    #[serde(default)] bvid: String,
    cid: i64,
    played_seconds: i64,
}

#[derive(Deserialize)]
struct ReplyLikeArgs {
    oid: i64,
    #[serde(default = "default_reply_type")] kind: i32,
    rpid: i64,
    action: i32,
}

#[derive(Deserialize)]
struct SendDanmakuArgs {
    aid: i64,
    cid: i64,
    msg: String,
    #[serde(default)] progress_ms: i64,
    #[serde(default = "default_dm_mode")] mode: i32,
    #[serde(default = "default_dm_color")] color: i32,
    #[serde(default = "default_dm_fontsize")] fontsize: i32,
}
fn default_dm_mode() -> i32 { 1 }
fn default_dm_color() -> i32 { 16777215 }
fn default_dm_fontsize() -> i32 { 25 }

#[derive(Deserialize)]
struct ReplyAddArgs {
    oid: i64,
    #[serde(default = "default_reply_type")] kind: i32,
    message: String,
    #[serde(default)] root: i64,
    #[serde(default)] parent: i64,
    #[serde(default)] pictures: Vec<ibili_core::dto::ReplyPicture>,
}

#[derive(Deserialize)]
struct UploadBfsArgs {
    /// Base64-encoded image bytes. Keeping the FFI text-only avoids
    /// needing a parallel binary entry point — the iOS layer encodes
    /// the JPEG/PNG once and we decode here.
    bytes_b64: String,
    #[serde(default = "default_bfs_name")] file_name: String,
    #[serde(default = "default_bfs_biz")] biz: String,
    #[serde(default = "default_bfs_category")] category: String,
}
fn default_bfs_name() -> String { "image.jpg".into() }
fn default_bfs_biz() -> String { "new_dyn".into() }
fn default_bfs_category() -> String { "daily".into() }

#[derive(Deserialize)]
struct EmotePanelArgs {
    #[serde(default = "default_emote_business")] business: String,
}
fn default_emote_business() -> String { "reply".into() }

#[derive(Deserialize)]
struct SearchVideoArgs {
    keyword: String,
    #[serde(default = "default_search_page")] page: i64,
    #[serde(default)] order: Option<String>,
    #[serde(default)] duration: Option<i64>,
    #[serde(default)] tids: Option<i64>,
}
fn default_search_page() -> i64 { 1 }

fn handle(c: &IbiliCore, method: &str, args: Value) -> Result<Value, CoreError> {
    match method {
        "session.snapshot" => to_value(c.inner.session_snapshot()),
        "session.restore" => {
            let s: ibili_core::session::PersistedSession = serde_json::from_value(args)?;
            c.inner.restore_session(s);
            Ok(Value::Object(Default::default()))
        }
        "session.logout" => { c.inner.logout(); Ok(Value::Object(Default::default())) }
        "auth.tv_qr.start" => to_value(c.inner.auth_tv_qr_start()?),
        "auth.tv_qr.poll" => {
            let a: PollArgs = serde_json::from_value(args)?;
            to_value(c.inner.auth_tv_qr_poll(&a.auth_code)?)
        }
        "feed.home" => {
            let a: FeedArgs = serde_json::from_value(args).unwrap_or(FeedArgs { idx: 0, ps: 20 });
            to_value(c.inner.feed_home(a.idx, a.ps)?)
        }
        "video.playurl" => {
            let a: PlayurlArgs = serde_json::from_value(args)?;
            to_value(c.inner.video_playurl_with_audio(a.aid, a.cid, a.qn, a.audio_qn)?)
        }
        "video.playurl.tv" => {
            let a: PlayurlArgs = serde_json::from_value(args)?;
            to_value(c.inner.video_playurl_tv_compat(a.aid, a.cid, a.qn)?)
        }
        "danmaku.list" => {
            let a: DanmakuArgs = serde_json::from_value(args)?;
            to_value(c.inner.danmaku_list(a.cid, a.duration_sec)?)
        }
        "video.view_cid" => {
            let a: VideoViewArgs = serde_json::from_value(args)?;
            let cid = c.inner.video_view_cid(&a.bvid)?;
            Ok(json!({ "cid": cid }))
        }
        "video.view_full" => {
            let a: VideoViewArgs = serde_json::from_value(args)?;
            to_value(c.inner.video_view_full(a.aid, &a.bvid)?)
        }
        "video.related" => {
            let a: VideoViewArgs = serde_json::from_value(args)?;
            to_value(c.inner.video_related(a.aid, &a.bvid)?)
        }
        "reply.main" => {
            let a: ReplyMainArgs = serde_json::from_value(args)?;
            to_value(c.inner.reply_main(a.oid, a.kind, a.sort, &a.next_offset)?)
        }
        "reply.detail" => {
            let a: ReplyDetailArgs = serde_json::from_value(args)?;
            to_value(c.inner.reply_detail(a.oid, a.kind, a.root, a.page)?)
        }
        "interaction.like" => {
            let a: LikeArgs = serde_json::from_value(args)?;
            to_value(c.inner.archive_like(a.aid, a.action)?)
        }
        "interaction.dislike" => {
            let a: AidArgs = serde_json::from_value(args)?;
            c.inner.archive_dislike(a.aid)?;
            Ok(Value::Object(Default::default()))
        }
        "interaction.coin" => {
            let a: CoinArgs = serde_json::from_value(args)?;
            to_value(c.inner.archive_coin(a.aid, a.multiply, a.also_like)?)
        }
        "interaction.triple" => {
            let a: AidArgs = serde_json::from_value(args)?;
            to_value(c.inner.archive_triple(a.aid)?)
        }
        "interaction.favorite" => {
            let a: FavoriteArgs = serde_json::from_value(args)?;
            to_value(c.inner.archive_favorite(a.aid, &a.add_ids, &a.del_ids)?)
        }
        "interaction.relation" => {
            let a: RelationArgs = serde_json::from_value(args)?;
            c.inner.relation_modify(a.fid, a.act)?;
            Ok(Value::Object(Default::default()))
        }
        "interaction.watchlater_add" => {
            let a: AidArgs = serde_json::from_value(args)?;
            c.inner.watchlater_add(a.aid)?;
            Ok(Value::Object(Default::default()))
        }
        "interaction.watchlater_del" => {
            let a: AidArgs = serde_json::from_value(args)?;
            c.inner.watchlater_del(a.aid)?;
            Ok(Value::Object(Default::default()))
        }
        "interaction.archive_relation" => {
            let a: VideoViewArgs = serde_json::from_value(args)?;
            to_value(c.inner.archive_relation(a.aid, &a.bvid)?)
        }
        "interaction.fav_folders" => {
            let a: FavFoldersArgs = serde_json::from_value(args)?;
            to_value(c.inner.fav_folders(a.rid, a.up_mid)?)
        }
        "interaction.heartbeat" => {
            let a: HeartbeatArgs = serde_json::from_value(args)?;
            c.inner.archive_heartbeat(a.aid, &a.bvid, a.cid, a.played_seconds)?;
            Ok(Value::Object(Default::default()))
        }
        "interaction.watchlater_aids" => {
            let aids = c.inner.watchlater_aids()?;
            to_value(aids)
        }
        "interaction.reply_like" => {
            let a: ReplyLikeArgs = serde_json::from_value(args)?;
            c.inner.reply_like(a.oid, a.kind, a.rpid, a.action)?;
            Ok(Value::Object(Default::default()))
        }
        "interaction.send_danmaku" => {
            let a: SendDanmakuArgs = serde_json::from_value(args)?;
            c.inner.send_danmaku(
                a.aid,
                a.cid,
                &a.msg,
                a.progress_ms,
                a.mode,
                a.color,
                a.fontsize,
            )?;
            Ok(Value::Object(Default::default()))
        }
        "interaction.reply_add" => {
            let a: ReplyAddArgs = serde_json::from_value(args)?;
            to_value(c.inner.reply_add(
                a.oid,
                a.kind,
                &a.message,
                a.root,
                a.parent,
                a.pictures,
            )?)
        }
        "interaction.upload_bfs" => {
            let a: UploadBfsArgs = serde_json::from_value(args)?;
            use base64::Engine;
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(a.bytes_b64.as_bytes())
                .map_err(|e| ibili_core::CoreError::InvalidArgument(format!("base64: {e}")))?;
            to_value(c.inner.upload_bfs(bytes, a.file_name, &a.biz, &a.category)?)
        }
        "interaction.emote_panel" => {
            let a: EmotePanelArgs = serde_json::from_value(args)?;
            to_value(c.inner.emote_panel(&a.business)?)
        }
        "search.video" => {
            let a: SearchVideoArgs = serde_json::from_value(args)?;
            to_value(c.inner.search_video(
                &a.keyword,
                a.page,
                a.order.as_deref(),
                a.duration,
                a.tids,
            )?)
        }
        _ => Err(CoreError::InvalidArgument(format!("unknown method: {method}"))),
    }
}

fn to_value<T: Serialize>(v: T) -> Result<Value, CoreError> {
    serde_json::to_value(v).map_err(Into::into)
}
