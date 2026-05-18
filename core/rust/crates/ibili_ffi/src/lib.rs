//! C ABI exposing [`ibili_core`] through a single JSON dispatch entry.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use ibili_core::{anime::AnimeMediaCandidate, Core, CoreError};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Opaque handle.
pub struct IbiliCore {
    inner: Core,
}

/// Create a core. Returns null on failure.
#[no_mangle]
pub extern "C" fn ibili_core_new(config_json: *const c_char) -> *mut IbiliCore {
    let cfg = if config_json.is_null() {
        "{}".to_string()
    } else {
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
        unsafe {
            drop(Box::from_raw(core));
        }
    }
}

/// Free a string previously returned by ibili_call / ibili_core_*.
#[no_mangle]
pub extern "C" fn ibili_string_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
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
    if core.is_null() {
        return Err(CoreError::InvalidArgument("null core".into()));
    }
    let core = unsafe { &*core };
    let method = unsafe { CStr::from_ptr(method) }
        .to_str()
        .map_err(|_| CoreError::InvalidArgument("method utf8".into()))?;
    let args: Value = if args_json.is_null() {
        Value::Object(Default::default())
    } else {
        let s = unsafe { CStr::from_ptr(args_json) }
            .to_str()
            .map_err(|_| CoreError::InvalidArgument("args utf8".into()))?;
        if s.is_empty() {
            Value::Object(Default::default())
        } else {
            serde_json::from_str(s)?
        }
    };
    handle(core, method, args)
}

#[derive(Deserialize)]
struct PollArgs {
    auth_code: String,
}

#[derive(Deserialize)]
struct FeedArgs {
    #[serde(default)]
    idx: i64,
    #[serde(default = "default_ps")]
    ps: i64,
    #[serde(default = "default_recommend_source")]
    source: String,
}
fn default_ps() -> i64 {
    20
}
fn default_recommend_source() -> String {
    "web".into()
}

#[derive(Deserialize)]
struct PopularArgs {
    #[serde(default = "default_one_i64")]
    pn: i64,
    #[serde(default = "default_ps")]
    ps: i64,
}

#[derive(Deserialize)]
struct LiveFeedArgs {
    #[serde(default = "default_one_i64")]
    page: i64,
}

#[derive(Deserialize)]
struct LiveRoomArgs {
    room_id: i64,
    #[serde(default)]
    qn: i64,
    #[serde(default = "default_cdn_selection")]
    cdn: String,
}

#[derive(Deserialize)]
struct SendLiveDanmakuArgs {
    room_id: i64,
    msg: String,
    #[serde(default = "default_dm_mode")]
    mode: i32,
    #[serde(default = "default_dm_color")]
    color: i32,
    #[serde(default = "default_dm_fontsize")]
    fontsize: i32,
}

#[derive(Deserialize)]
struct PlayurlArgs {
    aid: i64,
    #[serde(default)]
    bvid: String,
    cid: i64,
    #[serde(default)]
    ep_id: i64,
    #[serde(default)]
    season_id: i64,
    #[serde(default = "default_qn")]
    qn: i64,
    #[serde(default)]
    audio_qn: i64,
    #[serde(default = "default_cdn_selection")]
    cdn: String,
    #[serde(default = "default_codec_preference")]
    codec_preference: String,
}

#[derive(Deserialize)]
struct SubscriptionListArgs {
    mid: i64,
    #[serde(default = "default_one_i64")]
    page: i64,
    #[serde(default = "default_ps")]
    page_size: i64,
}

#[derive(Deserialize)]
struct SubscriptionResourcesArgs {
    id: i64,
    #[serde(default = "default_one_i64")]
    page: i64,
    #[serde(default = "default_ps")]
    page_size: i64,
}

#[derive(Deserialize)]
struct SubscriptionCancelArgs {
    id: i64,
    #[serde(default)]
    kind: i64,
}

#[derive(Deserialize)]
struct AnimeOAuthStartArgs {
    client_id: String,
    redirect_uri: String,
}

#[derive(Deserialize)]
struct AnimeOAuthExchangeArgs {
    client_id: String,
    client_secret: String,
    redirect_uri: String,
    code: String,
}

#[derive(Deserialize)]
struct AnimeOAuthRefreshArgs {
    client_id: String,
    client_secret: String,
    refresh_token: String,
}

#[derive(Deserialize)]
struct AnimeTokenArgs {
    access_token: String,
}

#[derive(Deserialize)]
struct AnimeCollectionListArgs {
    access_token: String,
    username: String,
    #[serde(default)]
    collection_type: i64,
    #[serde(default = "default_one_i64")]
    page: i64,
    #[serde(default = "default_ps")]
    page_size: i64,
}

#[derive(Deserialize)]
struct AnimeCollectionUpdateArgs {
    access_token: String,
    subject_id: i64,
    collection_type: i64,
}

#[derive(Deserialize)]
struct AnimeEpisodeUpdateArgs {
    access_token: String,
    #[serde(default)]
    subject_id: i64,
    episode_id: i64,
    #[serde(default = "default_episode_watched")]
    collection_type: i64,
}

fn default_episode_watched() -> i64 {
    2
}

#[derive(Deserialize)]
struct AnimeSubjectDetailArgs {
    #[serde(default)]
    access_token: String,
    subject_id: i64,
}

#[derive(Deserialize)]
struct AnimeSubjectSearchArgs {
    keyword: String,
    #[serde(default = "default_one_i64")]
    page: i64,
    #[serde(default = "default_ps")]
    page_size: i64,
}

#[derive(Deserialize)]
struct AnimeSourceURLArgs {
    url: String,
}

#[derive(Deserialize)]
struct AnimeSourceImportArgs {
    json_text: String,
}

#[derive(Deserialize)]
struct AnimeMediaSourceFetchArgs {
    source_json: String,
    #[serde(default)]
    subject_names: Vec<String>,
    #[serde(default)]
    episode_sort: f64,
    #[serde(default)]
    episode_name: String,
}

#[derive(Deserialize)]
struct AnimeMediaSourceParsePageArgs {
    source_json: String,
    page_url: String,
    html: String,
    #[serde(default)]
    subject_names: Vec<String>,
    #[serde(default)]
    episode_sort: f64,
    #[serde(default)]
    episode_name: String,
}

#[derive(Deserialize)]
struct AnimeMediaResolveArgs {
    candidate: AnimeMediaCandidate,
    #[serde(default)]
    title: String,
    #[serde(default)]
    cover: String,
}

#[derive(Deserialize)]
struct AnimeBiliSourceFetchArgs {
    #[serde(default)]
    subject_names: Vec<String>,
    #[serde(default)]
    episode_sort: f64,
    #[serde(default)]
    episode_name: String,
}

#[derive(Deserialize)]
struct AnimeDanmakuFetchArgs {
    #[serde(default)]
    app_id: String,
    #[serde(default)]
    app_secret: String,
    #[serde(default)]
    subject_primary_name: String,
    #[serde(default)]
    subject_names: Vec<String>,
    #[serde(default)]
    subject_air_date: String,
    #[serde(default)]
    episode_sort: f64,
    #[serde(default)]
    episode_ep: f64,
    #[serde(default)]
    episode_name: String,
}

fn default_qn() -> i64 {
    0
}
fn default_cdn_selection() -> String {
    "auto".into()
}
fn default_codec_preference() -> String {
    "auto".into()
}

#[derive(Deserialize)]
struct DanmakuArgs {
    cid: i64,
    #[serde(default)]
    duration_sec: i64,
}

#[derive(Deserialize)]
struct DanmakuSegmentArgs {
    cid: i64,
    segment_index: i64,
}

#[derive(Deserialize)]
struct VideoViewArgs {
    #[serde(default)]
    aid: i64,
    #[serde(default)]
    bvid: String,
    #[serde(default)]
    ep_id: i64,
    #[serde(default)]
    season_id: i64,
}

#[derive(Deserialize)]
struct ReplyMainArgs {
    oid: i64,
    #[serde(default = "default_reply_type")]
    kind: i32,
    #[serde(default = "default_reply_sort")]
    sort: i32,
    #[serde(default)]
    next_offset: String,
}
fn default_reply_type() -> i32 {
    1
}
fn default_reply_sort() -> i32 {
    1
}

#[derive(Deserialize)]
struct ReplyDetailArgs {
    oid: i64,
    #[serde(default = "default_reply_type")]
    kind: i32,
    root: i64,
    #[serde(default = "default_page")]
    page: i64,
}
fn default_page() -> i64 {
    1
}

#[derive(Deserialize)]
struct AidArgs {
    aid: i64,
}

#[derive(Deserialize)]
struct LikeArgs {
    aid: i64,
    #[serde(default = "default_like_action")]
    action: i32,
}
fn default_like_action() -> i32 {
    1
}

#[derive(Deserialize)]
struct CoinArgs {
    aid: i64,
    #[serde(default = "default_multiply")]
    multiply: i32,
    #[serde(default)]
    also_like: bool,
}
fn default_multiply() -> i32 {
    1
}

#[derive(Deserialize)]
struct FavoriteArgs {
    aid: i64,
    #[serde(default)]
    add_ids: Vec<i64>,
    #[serde(default)]
    del_ids: Vec<i64>,
}

#[derive(Deserialize)]
struct RelationArgs {
    fid: i64,
    #[serde(default = "default_relation_act")]
    act: i32,
}
fn default_relation_act() -> i32 {
    1
}

#[derive(Deserialize)]
struct FavFoldersArgs {
    #[serde(default)]
    rid: i64,
    up_mid: i64,
}

#[derive(Deserialize)]
struct HeartbeatArgs {
    #[serde(default)]
    aid: i64,
    #[serde(default)]
    bvid: String,
    cid: i64,
    played_seconds: i64,
}

#[derive(Deserialize)]
struct ReplyLikeArgs {
    oid: i64,
    #[serde(default = "default_reply_type")]
    kind: i32,
    rpid: i64,
    action: i32,
}

#[derive(Deserialize)]
struct SendDanmakuArgs {
    aid: i64,
    cid: i64,
    msg: String,
    #[serde(default)]
    progress_ms: i64,
    #[serde(default = "default_dm_mode")]
    mode: i32,
    #[serde(default = "default_dm_color")]
    color: i32,
    #[serde(default = "default_dm_fontsize")]
    fontsize: i32,
}
fn default_dm_mode() -> i32 {
    1
}
fn default_dm_color() -> i32 {
    16777215
}
fn default_dm_fontsize() -> i32 {
    25
}

#[derive(Deserialize)]
struct ReplyAddArgs {
    oid: i64,
    #[serde(default = "default_reply_type")]
    kind: i32,
    message: String,
    #[serde(default)]
    root: i64,
    #[serde(default)]
    parent: i64,
    #[serde(default)]
    pictures: Vec<ibili_core::dto::ReplyPicture>,
}

#[derive(Deserialize)]
struct UploadBfsArgs {
    /// Base64-encoded image bytes. Keeping the FFI text-only avoids
    /// needing a parallel binary entry point — the iOS layer encodes
    /// the JPEG/PNG once and we decode here.
    bytes_b64: String,
    #[serde(default = "default_bfs_name")]
    file_name: String,
    #[serde(default = "default_bfs_biz")]
    biz: String,
    #[serde(default = "default_bfs_category")]
    category: String,
}
fn default_bfs_name() -> String {
    "image.jpg".into()
}
fn default_bfs_biz() -> String {
    "new_dyn".into()
}
fn default_bfs_category() -> String {
    "daily".into()
}

#[derive(Deserialize)]
struct EmotePanelArgs {
    #[serde(default = "default_emote_business")]
    business: String,
}
fn default_emote_business() -> String {
    "reply".into()
}

#[derive(Deserialize)]
struct SearchVideoArgs {
    keyword: String,
    #[serde(default = "default_search_page")]
    page: i64,
    #[serde(default)]
    order: Option<String>,
    #[serde(default)]
    duration: Option<i64>,
    #[serde(default)]
    tids: Option<i64>,
}
fn default_search_page() -> i64 {
    1
}

#[derive(Deserialize)]
struct SearchLiveArgs {
    keyword: String,
    #[serde(default = "default_search_page")]
    page: i64,
}

#[derive(Deserialize)]
struct SearchPgcArgs {
    keyword: String,
    #[serde(default = "default_search_page")]
    page: i64,
    #[serde(default = "default_search_pgc_type")]
    search_type: String,
}
fn default_search_pgc_type() -> String {
    "media_bangumi".into()
}

#[derive(Deserialize)]
struct SearchUserArgs {
    keyword: String,
    #[serde(default = "default_search_page")]
    page: i64,
    #[serde(default)]
    order: Option<String>,
    #[serde(default)]
    order_sort: Option<i64>,
    #[serde(default)]
    user_type: Option<i64>,
}

#[derive(Deserialize)]
struct SearchArticleArgs {
    keyword: String,
    #[serde(default = "default_search_page")]
    page: i64,
    #[serde(default)]
    order: Option<String>,
    #[serde(default)]
    category_id: Option<i64>,
}

#[derive(Deserialize)]
struct ArticleReadArgs {
    cvid: i64,
}

#[derive(Deserialize)]
struct ArticleOpusArgs {
    id: String,
}

#[derive(Deserialize)]
struct MidArgs {
    mid: i64,
}
#[derive(Deserialize)]
struct VmidPageArgs {
    vmid: i64,
    #[serde(default = "default_one_i64")]
    pn: i64,
}
#[derive(Deserialize)]
struct HistoryCursorArgs {
    #[serde(default)]
    max: i64,
    #[serde(default)]
    view_at: i64,
}
#[derive(Deserialize)]
struct HistorySearchArgs {
    #[serde(default)]
    keyword: String,
    #[serde(default = "default_one_i64")]
    pn: i64,
}
#[derive(Deserialize)]
struct FavListArgs {
    media_id: i64,
    #[serde(default = "default_one_i64")]
    pn: i64,
    #[serde(default)]
    keyword: String,
    #[serde(default)]
    all_folders: bool,
}
#[derive(Deserialize)]
struct WatchLaterListArgs {
    #[serde(default = "default_one_i64")]
    pn: i64,
    #[serde(default)]
    keyword: String,
}
#[derive(Deserialize)]
struct BangumiListArgs {
    vmid: i64,
    #[serde(default = "default_bangumi_kind")]
    kind: i32,
    #[serde(default)]
    status: i32,
    #[serde(default = "default_one_i64")]
    pn: i64,
}
fn default_bangumi_kind() -> i32 {
    1
}
fn default_one_i64() -> i64 {
    1
}
#[derive(Deserialize)]
struct DynamicFeedArgs {
    #[serde(default = "default_feed_type")]
    feed_type: String,
    #[serde(default = "default_one_i64")]
    page: i64,
    #[serde(default)]
    offset: String,
}
fn default_feed_type() -> String {
    "all".into()
}

#[derive(Deserialize)]
struct SpaceDynamicArgs {
    host_mid: i64,
    #[serde(default)]
    offset: String,
}

#[derive(Deserialize)]
struct DynamicLikeArgs {
    dynamic_id: String,
    #[serde(default = "default_like_action")]
    action: i32,
}

#[derive(Deserialize)]
struct SpaceArcSearchArgs {
    mid: i64,
    #[serde(default)]
    keyword: String,
    #[serde(default = "default_pubdate")]
    order: String,
    #[serde(default = "default_one_i64")]
    page: i64,
}
fn default_pubdate() -> String {
    "pubdate".into()
}

#[derive(Deserialize)]
struct PackagingOfflineBuildArgs {
    diagnostics_dir: String,
    #[serde(default)]
    output_root_dir: String,
}

fn handle(c: &IbiliCore, method: &str, args: Value) -> Result<Value, CoreError> {
    match method {
        "session.snapshot" => to_value(c.inner.session_snapshot()),
        "session.restore" => {
            let s: ibili_core::session::PersistedSession = serde_json::from_value(args)?;
            c.inner.restore_session(s);
            Ok(Value::Object(Default::default()))
        }
        "session.logout" => {
            c.inner.logout();
            Ok(Value::Object(Default::default()))
        }
        "anime.oauth.start" => {
            let a: AnimeOAuthStartArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_oauth_start(&a.client_id, &a.redirect_uri)?)
        }
        "anime.oauth.exchange" => {
            let a: AnimeOAuthExchangeArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_oauth_exchange(
                &a.client_id,
                &a.client_secret,
                &a.redirect_uri,
                &a.code,
            )?)
        }
        "anime.oauth.refresh" => {
            let a: AnimeOAuthRefreshArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_oauth_refresh(
                &a.client_id,
                &a.client_secret,
                &a.refresh_token,
            )?)
        }
        "anime.me" => {
            let a: AnimeTokenArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_me(&a.access_token)?)
        }
        "anime.collection.list" => {
            let a: AnimeCollectionListArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_collection_list(
                &a.access_token,
                &a.username,
                a.collection_type,
                a.page,
                a.page_size,
            )?)
        }
        "anime.collection.update" => {
            let a: AnimeCollectionUpdateArgs = serde_json::from_value(args)?;
            c.inner
                .anime_collection_update(&a.access_token, a.subject_id, a.collection_type)?;
            Ok(Value::Object(Default::default()))
        }
        "anime.episode.update" => {
            let a: AnimeEpisodeUpdateArgs = serde_json::from_value(args)?;
            c.inner.anime_episode_update(
                &a.access_token,
                a.subject_id,
                a.episode_id,
                a.collection_type,
            )?;
            Ok(Value::Object(Default::default()))
        }
        "anime.subject.detail" => {
            let a: AnimeSubjectDetailArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_subject_detail(&a.access_token, a.subject_id)?)
        }
        "anime.subject.search" => {
            let a: AnimeSubjectSearchArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_subject_search(&a.keyword, a.page, a.page_size)?)
        }
        "anime.source.subscription.update" => {
            let a: AnimeSourceURLArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_source_subscription_update(&a.url)?)
        }
        "anime.source.import" => {
            let a: AnimeSourceImportArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_source_import(&a.json_text)?)
        }
        "anime.media.source_fetch" => {
            let a: AnimeMediaSourceFetchArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_media_source_fetch(
                &a.source_json,
                a.subject_names,
                a.episode_sort,
                &a.episode_name,
            )?)
        }
        "anime.media.source_parse_page" => {
            let a: AnimeMediaSourceParsePageArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_media_source_parse_page(
                &a.source_json,
                &a.page_url,
                &a.html,
                a.subject_names,
                a.episode_sort,
                &a.episode_name,
            )?)
        }
        "anime.media.resolve" => {
            let a: AnimeMediaResolveArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_media_resolve(a.candidate, &a.title, &a.cover)?)
        }
        "anime.bili_source.fetch" => {
            let a: AnimeBiliSourceFetchArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_bili_source_fetch(
                a.subject_names,
                a.episode_sort,
                &a.episode_name,
            )?)
        }
        "anime.danmaku.fetch" => {
            let a: AnimeDanmakuFetchArgs = serde_json::from_value(args)?;
            to_value(c.inner.anime_danmaku_fetch(
                &a.app_id,
                &a.app_secret,
                &a.subject_primary_name,
                a.subject_names,
                &a.subject_air_date,
                a.episode_sort,
                a.episode_ep,
                &a.episode_name,
            )?)
        }
        "auth.tv_qr.start" => to_value(c.inner.auth_tv_qr_start()?),
        "auth.tv_qr.poll" => {
            let a: PollArgs = serde_json::from_value(args)?;
            to_value(c.inner.auth_tv_qr_poll(&a.auth_code)?)
        }
        "feed.home" => {
            let a: FeedArgs = serde_json::from_value(args).unwrap_or(FeedArgs {
                idx: 0,
                ps: 20,
                source: default_recommend_source(),
            });
            to_value(c.inner.feed_home_with_source(a.idx, a.ps, &a.source)?)
        }
        "feed.popular" => {
            let a: PopularArgs =
                serde_json::from_value(args).unwrap_or(PopularArgs { pn: 1, ps: 20 });
            to_value(c.inner.feed_popular(a.pn, a.ps)?)
        }
        "live.feed" => {
            let a: LiveFeedArgs = serde_json::from_value(args).unwrap_or(LiveFeedArgs { page: 1 });
            to_value(c.inner.live_feed(a.page)?)
        }
        "live.room_info" => {
            let a: LiveRoomArgs = serde_json::from_value(args)?;
            to_value(c.inner.live_room_info(a.room_id)?)
        }
        "live.playurl" => {
            let a: LiveRoomArgs = serde_json::from_value(args)?;
            to_value(
                c.inner
                    .live_playurl_with_cdn_selection(a.room_id, a.qn, &a.cdn)?,
            )
        }
        "live.danmaku_info" => {
            let a: LiveRoomArgs = serde_json::from_value(args)?;
            to_value(c.inner.live_danmaku_info(a.room_id)?)
        }
        "live.danmaku_history" => {
            let a: LiveRoomArgs = serde_json::from_value(args)?;
            to_value(c.inner.live_danmaku_history(a.room_id)?)
        }
        "live.send_danmaku" => {
            let a: SendLiveDanmakuArgs = serde_json::from_value(args)?;
            c.inner
                .send_live_danmaku(a.room_id, &a.msg, a.mode, a.color, a.fontsize)?;
            Ok(Value::Object(Default::default()))
        }
        "video.playurl" => {
            let a: PlayurlArgs = serde_json::from_value(args)?;
            to_value(
                c.inner
                    .video_playurl_with_audio_playback_options_bvid(
                        a.aid,
                        &a.bvid,
                        a.cid,
                        a.qn,
                        a.audio_qn,
                        &a.cdn,
                        &a.codec_preference,
                    )?,
            )
        }
        "video.offline_playurl" => {
            let a: PlayurlArgs = serde_json::from_value(args)?;
            to_value(c.inner.video_offline_playurl_with_bvid(
                a.aid,
                &a.bvid,
                a.cid,
                a.qn,
                a.audio_qn,
                &a.cdn,
            )?)
        }
        "pgc.playurl" => {
            let a: PlayurlArgs = serde_json::from_value(args)?;
            to_value(c.inner.pgc_playurl_with_audio_playback_options(
                a.aid,
                a.cid,
                a.ep_id,
                a.season_id,
                a.qn,
                a.audio_qn,
                &a.cdn,
                &a.codec_preference,
            )?)
        }
        "pgc.offline_playurl" => {
            let a: PlayurlArgs = serde_json::from_value(args)?;
            to_value(c.inner.pgc_offline_playurl(
                a.aid,
                a.cid,
                a.ep_id,
                a.season_id,
                a.qn,
                a.audio_qn,
                &a.cdn,
            )?)
        }
        "pgc.season" => {
            let a: VideoViewArgs = serde_json::from_value(args)?;
            to_value(c.inner.pgc_season(a.season_id, a.ep_id)?)
        }
        "video.playurl.tv" => {
            let a: PlayurlArgs = serde_json::from_value(args)?;
            to_value(c.inner.video_playurl_tv_compat(a.aid, a.cid, a.qn)?)
        }
        "danmaku.list" => {
            let a: DanmakuArgs = serde_json::from_value(args)?;
            to_value(c.inner.danmaku_list(a.cid, a.duration_sec)?)
        }
        "danmaku.segment" => {
            let a: DanmakuSegmentArgs = serde_json::from_value(args)?;
            to_value(c.inner.danmaku_segment(a.cid, a.segment_index)?)
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
            c.inner
                .archive_heartbeat(a.aid, &a.bvid, a.cid, a.played_seconds)?;
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
            to_value(
                c.inner
                    .reply_add(a.oid, a.kind, &a.message, a.root, a.parent, a.pictures)?,
            )
        }
        "interaction.upload_bfs" => {
            let a: UploadBfsArgs = serde_json::from_value(args)?;
            use base64::Engine;
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(a.bytes_b64.as_bytes())
                .map_err(|e| ibili_core::CoreError::InvalidArgument(format!("base64: {e}")))?;
            to_value(
                c.inner
                    .upload_bfs(bytes, a.file_name, &a.biz, &a.category)?,
            )
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
        "search.live" => {
            let a: SearchLiveArgs = serde_json::from_value(args)?;
            to_value(c.inner.search_live(&a.keyword, a.page)?)
        }
        "search.pgc" => {
            let a: SearchPgcArgs = serde_json::from_value(args)?;
            to_value(c.inner.search_pgc(&a.keyword, a.page, &a.search_type)?)
        }
        "search.user" => {
            let a: SearchUserArgs = serde_json::from_value(args)?;
            to_value(c.inner.search_user_with_filters(
                &a.keyword,
                a.page,
                a.order.as_deref(),
                a.order_sort,
                a.user_type,
            )?)
        }
        "search.article" => {
            let a: SearchArticleArgs = serde_json::from_value(args)?;
            to_value(c.inner.search_article(
                &a.keyword,
                a.page,
                a.order.as_deref(),
                a.category_id,
            )?)
        }
        "article.read" => {
            let a: ArticleReadArgs = serde_json::from_value(args)?;
            to_value(c.inner.article_read_detail(a.cvid)?)
        }
        "article.opus" => {
            let a: ArticleOpusArgs = serde_json::from_value(args)?;
            to_value(c.inner.article_opus_detail(&a.id)?)
        }
        "user.card" => {
            let a: MidArgs = serde_json::from_value(args)?;
            to_value(c.inner.user_card(a.mid)?)
        }
        "user.live" => {
            let a: MidArgs = serde_json::from_value(args)?;
            to_value(c.inner.user_live(a.mid)?)
        }
        "user.history" => {
            let a: HistoryCursorArgs =
                serde_json::from_value(args).unwrap_or(HistoryCursorArgs { max: 0, view_at: 0 });
            to_value(c.inner.history_cursor(a.max, a.view_at)?)
        }
        "user.history_search" => {
            let a: HistorySearchArgs = serde_json::from_value(args).unwrap_or(HistorySearchArgs {
                keyword: String::new(),
                pn: 1,
            });
            to_value(c.inner.history_search(&a.keyword, a.pn)?)
        }
        "user.fav_resources" => {
            let a: FavListArgs = serde_json::from_value(args)?;
            to_value(c.inner.fav_resource_list(a.media_id, a.pn, &a.keyword, a.all_folders)?)
        }
        "user.subscriptions" => {
            let a: SubscriptionListArgs = serde_json::from_value(args)?;
            to_value(c.inner.subscription_folder_list(a.mid, a.page, a.page_size)?)
        }
        "user.subscription_resources" => {
            let a: SubscriptionResourcesArgs = serde_json::from_value(args)?;
            to_value(c.inner.subscription_resource_list(a.id, a.page, a.page_size)?)
        }
        "user.subscription_cancel" => {
            let a: SubscriptionCancelArgs = serde_json::from_value(args)?;
            c.inner.subscription_cancel(a.id, a.kind)?;
            Ok(Value::Object(Default::default()))
        }
        "user.bangumi_follow" => {
            let a: BangumiListArgs = serde_json::from_value(args)?;
            to_value(
                c.inner
                    .bangumi_follow_list(a.vmid, a.kind, a.status, a.pn)?,
            )
        }
        "user.watchlater_list" => {
            let a: WatchLaterListArgs = serde_json::from_value(args).unwrap_or(WatchLaterListArgs {
                pn: 1,
                keyword: String::new(),
            });
            to_value(c.inner.watchlater_list(a.pn, &a.keyword)?)
        }
        "user.followings" => {
            let a: VmidPageArgs = serde_json::from_value(args)?;
            to_value(c.inner.relation_followings(a.vmid, a.pn)?)
        }
        "user.followers" => {
            let a: VmidPageArgs = serde_json::from_value(args)?;
            to_value(c.inner.relation_followers(a.vmid, a.pn)?)
        }
        "dynamic.feed" => {
            let a: DynamicFeedArgs = serde_json::from_value(args).unwrap_or(DynamicFeedArgs {
                feed_type: "all".into(),
                page: 1,
                offset: String::new(),
            });
            to_value(c.inner.dynamic_feed(&a.feed_type, a.page, &a.offset)?)
        }
        "dynamic.space_feed" => {
            let a: SpaceDynamicArgs = serde_json::from_value(args)?;
            to_value(c.inner.space_dynamic_feed(a.host_mid, &a.offset)?)
        }
        "dynamic.like" => {
            let a: DynamicLikeArgs = serde_json::from_value(args)?;
            c.inner.dynamic_like(&a.dynamic_id, a.action)?;
            Ok(Value::Object(Default::default()))
        }
        "packaging.offline_build" => {
            let a: PackagingOfflineBuildArgs = serde_json::from_value(args)?;
            to_value(c.inner.packaging_offline_build(
                ibili_core::packaging::OfflinePackagingRequest {
                    diagnostics_dir: a.diagnostics_dir,
                    output_root_dir: a.output_root_dir,
                },
            )?)
        }
        "user.space_arc_search" => {
            let a: SpaceArcSearchArgs = serde_json::from_value(args)?;
            to_value(
                c.inner
                    .space_arc_search(a.mid, &a.keyword, &a.order, a.page)?,
            )
        }
        _ => Err(CoreError::InvalidArgument(format!(
            "unknown method: {method}"
        ))),
    }
}

fn to_value<T: Serialize>(v: T) -> Result<Value, CoreError> {
    serde_json::to_value(v).map_err(Into::into)
}
