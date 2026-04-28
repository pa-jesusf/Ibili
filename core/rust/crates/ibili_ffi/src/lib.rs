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
struct PlayurlArgs { aid: i64, cid: i64, #[serde(default = "default_qn")] qn: i64 }
fn default_qn() -> i64 { 0 }

#[derive(Deserialize)]
struct DanmakuArgs { cid: i64 }

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
            to_value(c.inner.video_playurl(a.aid, a.cid, a.qn)?)
        }
        "video.playurl.tv" => {
            let a: PlayurlArgs = serde_json::from_value(args)?;
            to_value(c.inner.video_playurl_tv_compat(a.aid, a.cid, a.qn)?)
        }
        "danmaku.list" => {
            let a: DanmakuArgs = serde_json::from_value(args)?;
            to_value(c.inner.danmaku_list(a.cid)?)
        }
        _ => Err(CoreError::InvalidArgument(format!("unknown method: {method}"))),
    }
}

fn to_value<T: Serialize>(v: T) -> Result<Value, CoreError> {
    serde_json::to_value(v).map_err(Into::into)
}
