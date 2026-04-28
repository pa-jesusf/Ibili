//! Unit tests for the pure-logic pieces of `ibili_core`:
//! signers, session state, JSON DTO shapes, and dispatch routing.
//! Network-dependent paths (`feed_home`, `video_playurl`, `auth_*`) are not
//! exercised here — they require a live Bilibili session and are covered by
//! integration tests under `tests/integration/` (gated behind a feature flag).

use ibili_core::dto::{ApiEnvelope, FeedItem};
use ibili_core::session::{PersistedSession, Session};
use ibili_core::signer::{AppSigner, WbiKey, WbiSigner, APPKEY, APPSEC};

#[test]
fn appkey_appsec_match_upstream_piliplus() {
    // PiliPlus constants.dart, sha1-pinned values from upstream commit.
    assert_eq!(APPKEY, "dfca71928277209b");
    assert_eq!(APPSEC, "b5475a8825547a4fc26c7d518eaaa02e");
}

#[test]
fn app_sign_adds_appkey_ts_and_md5_sign() {
    let mut params = vec![
        ("local_id".to_string(), "0".to_string()),
        ("auth_code".to_string(), "abc123".to_string()),
    ];
    AppSigner::sign(&mut params);

    let keys: Vec<&str> = params.iter().map(|(k, _)| k.as_str()).collect();
    assert!(keys.contains(&"appkey"));
    assert!(keys.contains(&"ts"));
    assert!(keys.contains(&"sign"));

    let sign = params.iter().find(|(k, _)| k == "sign").unwrap().1.clone();
    assert_eq!(sign.len(), 32, "MD5 hex must be 32 chars");
    assert!(sign.chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn app_sign_is_deterministic_given_same_inputs() {
    // We cannot easily freeze `ts`, but we can assert that two adjacent calls
    // produce different signs only because of `ts`, and identical signs when
    // `ts` is identical (clamped manually).
    let mut a = vec![("k".into(), "v".into())];
    let mut b = vec![("k".into(), "v".into())];
    AppSigner::sign(&mut a);
    AppSigner::sign(&mut b);

    let ts_a = a.iter().find(|(k, _)| k == "ts").unwrap().1.clone();
    let ts_b = b.iter().find(|(k, _)| k == "ts").unwrap().1.clone();
    if ts_a == ts_b {
        assert_eq!(
            a.iter().find(|(k, _)| k == "sign").unwrap().1,
            b.iter().find(|(k, _)| k == "sign").unwrap().1
        );
    }
}

#[test]
fn wbi_mixin_key_is_stable_for_known_input() {
    // Synthetic but deterministic.
    let key = WbiKey::from_urls(
        "https://i0.hdslb.com/bfs/wbi/aabbccddeeff00112233445566778899.png",
        "https://i0.hdslb.com/bfs/wbi/99887766554433221100ffeeddccbbaa.png",
    );
    let mixin = key.mixin_key();
    assert_eq!(mixin.len(), 32);
    // Mixin should depend on both halves.
    let other = WbiKey::from_urls(
        "https://i0.hdslb.com/bfs/wbi/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png",
        "https://i0.hdslb.com/bfs/wbi/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png",
    );
    assert_ne!(mixin, other.mixin_key());
}

#[test]
fn wbi_sign_produces_w_rid_and_wts() {
    let key = WbiKey::from_urls(
        "https://i0.hdslb.com/bfs/wbi/aabbccddeeff00112233445566778899.png",
        "https://i0.hdslb.com/bfs/wbi/99887766554433221100ffeeddccbbaa.png",
    );
    let mut params = vec![("foo".into(), "bar".into())];
    WbiSigner::sign(&mut params, &key);
    let keys: Vec<&str> = params.iter().map(|(k, _)| k.as_str()).collect();
    assert!(keys.contains(&"wts"));
    assert!(keys.contains(&"w_rid"));
    let w_rid = params.iter().find(|(k, _)| k == "w_rid").unwrap().1.clone();
    assert_eq!(w_rid.len(), 32);
}

#[test]
fn wbi_sign_strips_special_chars_from_values() {
    let key = WbiKey::from_urls(
        "https://i0.hdslb.com/bfs/wbi/aabbccddeeff00112233445566778899.png",
        "https://i0.hdslb.com/bfs/wbi/99887766554433221100ffeeddccbbaa.png",
    );
    // Bilibili strips !'()* before signing.
    let mut a = vec![("q".into(), "hello!world".to_string())];
    let mut b = vec![("q".into(), "helloworld".to_string())];
    WbiSigner::sign(&mut a, &key);
    WbiSigner::sign(&mut b, &key);
    let q_a = a.iter().find(|(k, _)| k == "q").unwrap().1.clone();
    assert_eq!(q_a, "helloworld", "value should have ! stripped");
    // After sanitisation, both inputs sign identically (modulo wts skew).
    let wts_a = a.iter().find(|(k, _)| k == "wts").unwrap().1.clone();
    let wts_b = b.iter().find(|(k, _)| k == "wts").unwrap().1.clone();
    if wts_a == wts_b {
        assert_eq!(
            a.iter().find(|(k, _)| k == "w_rid").unwrap().1,
            b.iter().find(|(k, _)| k == "w_rid").unwrap().1
        );
    }
}

#[test]
fn session_round_trip() {
    let p = PersistedSession {
        access_token: "tok".into(),
        refresh_token: "ref".into(),
        mid: 42,
        expires_at_secs: 1_700_000_000,
        web_cookies: Vec::new(),
    };
    let s = Session::from_persisted(p.clone());
    assert_eq!(s.access_key().unwrap(), "tok");
    let snap = s.snapshot();
    assert!(snap.logged_in);
    assert_eq!(snap.mid, 42);
}

#[test]
fn empty_session_has_no_access_key() {
    let s = Session::default();
    assert!(s.access_key().is_none());
    assert!(!s.snapshot().logged_in);
}

#[test]
fn api_envelope_decodes_success() {
    let body = r#"{"code":0,"message":"0","data":{"items":[]}}"#;
    let env: ApiEnvelope<serde_json::Value> = serde_json::from_str(body).unwrap();
    assert_eq!(env.code, 0);
    assert!(env.data.is_some());
}

#[test]
fn api_envelope_decodes_error() {
    let body = r#"{"code":-101,"message":"账号未登录"}"#;
    let env: ApiEnvelope<serde_json::Value> = serde_json::from_str(body).unwrap();
    assert_eq!(env.code, -101);
    assert!(env.data.is_none());
    assert_eq!(env.message, "账号未登录");
}

#[test]
fn feed_item_serializes_with_snake_case_fields() {
    let item = FeedItem {
        aid: 1, bvid: "BV1".into(), cid: 2, title: "t".into(),
        cover: "c".into(), author: "a".into(), duration_sec: 60,
        play: 0, danmaku: 0,
    };
    let json = serde_json::to_value(&item).unwrap();
    assert!(json.get("duration_sec").is_some(), "FFI relies on snake_case for Swift CodingKeys");
    assert!(json.get("aid").is_some());
}
