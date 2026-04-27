//! Request signing for Bilibili endpoints.
//!
//! - [`AppSigner`] implements the legacy "appkey + sign" used by Android/TV apps.
//! - [`WbiSigner`] implements the web `wts` + `w_rid` signing.

use md5::{Digest, Md5};

/// AppSign credentials (TV app variant — works for our anonymous + access_key flows).
pub const APPKEY: &str = "4409e2ce8ffd12b8";
pub const APPSEC: &str = "59b43e04ad6965f34319062b478f83dd";

pub struct AppSigner;

impl AppSigner {
    /// Adds `appkey` and `ts`, then computes `sign = md5(sorted_query + appsec)`.
    /// Mutates `params` to include `appkey`, `ts`, `sign`.
    pub fn sign(params: &mut Vec<(String, String)>) {
        let ts = (std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()).to_string();
        params.push(("appkey".into(), APPKEY.into()));
        params.push(("ts".into(), ts));
        params.sort_by(|a, b| a.0.cmp(&b.0));
        let query = params.iter()
            .map(|(k, v)| format!("{}={}", k, urlencode(v)))
            .collect::<Vec<_>>()
            .join("&");
        let mut hasher = Md5::new();
        hasher.update(query.as_bytes());
        hasher.update(APPSEC.as_bytes());
        let sign = hex::encode(hasher.finalize());
        params.push(("sign".into(), sign));
    }
}

fn urlencode(s: &str) -> String {
    // Bilibili expects RFC3986 encoding for AppSign body.
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

/// WBI mixin order (extracted from PiliPlus / public reverse engineering).
const MIXIN_KEY_ENC_TAB: [usize; 64] = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
    22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
];

#[derive(Debug, Clone)]
pub struct WbiKey {
    pub img_key: String,
    pub sub_key: String,
}

impl WbiKey {
    /// Derive mixin key from img_url+sub_url file stems.
    pub fn from_urls(img_url: &str, sub_url: &str) -> Self {
        Self {
            img_key: stem(img_url),
            sub_key: stem(sub_url),
        }
    }

    pub fn mixin_key(&self) -> String {
        let raw = format!("{}{}", self.img_key, self.sub_key);
        let bytes = raw.as_bytes();
        let mut out = String::with_capacity(32);
        for &i in MIXIN_KEY_ENC_TAB.iter().take(32) {
            if let Some(&b) = bytes.get(i) {
                out.push(b as char);
            }
        }
        out
    }
}

fn stem(u: &str) -> String {
    let last = u.rsplit('/').next().unwrap_or("");
    last.split('.').next().unwrap_or("").to_string()
}

pub struct WbiSigner;

impl WbiSigner {
    /// Adds `wts`, sorts, computes `w_rid = md5(query + mixin_key)`.
    pub fn sign(params: &mut Vec<(String, String)>, key: &WbiKey) {
        let wts = (std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()).to_string();
        params.push(("wts".into(), wts));
        // Strip characters Bilibili strips from values: "!'()*"
        for (_, v) in params.iter_mut() {
            *v = v.chars().filter(|c| !"!'()*".contains(*c)).collect();
        }
        params.sort_by(|a, b| a.0.cmp(&b.0));
        let query = params.iter()
            .map(|(k, v)| format!("{}={}", k, urlencode(v)))
            .collect::<Vec<_>>()
            .join("&");
        let mut hasher = Md5::new();
        hasher.update(query.as_bytes());
        hasher.update(key.mixin_key().as_bytes());
        let w_rid = hex::encode(hasher.finalize());
        params.push(("w_rid".into(), w_rid));
    }
}
