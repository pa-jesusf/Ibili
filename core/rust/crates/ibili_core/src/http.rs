use crate::dto::ApiEnvelope;
use crate::error::{CoreError, CoreResult};
use parking_lot::Mutex;
use reqwest::blocking::Client;
use reqwest::blocking::RequestBuilder;
use reqwest::cookie::{CookieStore, Jar};
use reqwest::redirect::Policy;
use reqwest::Url;
use serde::de::DeserializeOwned;
use serde_json::json;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

/// Matches PiliPlus `Constants.userAgent` (android_hd/TV User-Agent).
pub const UA_TV: &str = "Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android model/android_hd mobi_app/android_hd build/2001100 channel/master innerVer/2001100 osVer/15 network/2";
pub const UA_ANDROID_APP: &str = "Mozilla/5.0 BiliDroid/8.43.0 (bbcallen@gmail.com) os/android model/android mobi_app/android build/8430300 channel/master innerVer/8430300 osVer/15 network/2";
pub const UA_WEB: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15";
const WEB_REFERER: &str = "https://www.bilibili.com/";
const BUVID_URL: &str = "https://api.bilibili.com/";
const ACTIVATE_BUVID_URL: &str = "https://api.bilibili.com/x/internal/gaia-gateway/ExClimbWuzhi";
static WEB_IDENTITY_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Headers PiliPlus attaches to every app endpoint call.
fn app_headers() -> reqwest::header::HeaderMap {
    use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
    let mut h = HeaderMap::new();
    let pairs: &[(&str, &str)] = &[
        ("User-Agent", UA_TV),
        ("env", "prod"),
        ("app-key", "android_hd"),
        (
            "x-bili-trace-id",
            "11111111111111111111111111111111:1111111111111111:0:0",
        ),
        ("x-bili-aurora-eid", ""),
        ("x-bili-aurora-zone", ""),
        ("bili-http-engine", "cronet"),
        ("buvid", "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFFinfoc"),
    ];
    for (k, v) in pairs {
        if let (Ok(name), Ok(val)) = (
            HeaderName::from_bytes(k.as_bytes()),
            HeaderValue::from_str(v),
        ) {
            h.insert(name, val);
        }
    }
    h
}

/// Headers PiliPlus attaches to Android app endpoints (`mobi_app=android`).
fn android_app_headers() -> reqwest::header::HeaderMap {
    use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
    let mut h = HeaderMap::new();
    let pairs: &[(&str, &str)] = &[
        ("User-Agent", UA_ANDROID_APP),
        ("env", "prod"),
        ("app-key", "android"),
        (
            "x-bili-trace-id",
            "11111111111111111111111111111111:1111111111111111:0:0",
        ),
        ("x-bili-aurora-eid", ""),
        ("x-bili-aurora-zone", ""),
        ("bili-http-engine", "cronet"),
        ("buvid", "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFFinfoc"),
        (
            "fp_local",
            "1111111111111111111111111111111111111111111111111111111111111111",
        ),
        (
            "fp_remote",
            "1111111111111111111111111111111111111111111111111111111111111111",
        ),
        ("session_id", "11111111"),
    ];
    for (k, v) in pairs {
        if let (Ok(name), Ok(val)) = (
            HeaderName::from_bytes(k.as_bytes()),
            HeaderValue::from_str(v),
        ) {
            h.insert(name, val);
        }
    }
    h
}

pub struct HttpClient {
    pub client: Client,
    pub jar: Arc<Jar>,
    web_identity_activation: Mutex<WebIdentityActivationState>,
}

#[derive(Default)]
struct WebIdentityActivationState {
    buvid3: Option<String>,
    attempted: bool,
    succeeded: bool,
    error: Option<String>,
}

#[derive(Clone, Debug)]
pub struct WebIdentityActivationSnapshot {
    pub buvid3: String,
    pub attempted: bool,
    pub attempted_now: bool,
    pub succeeded: bool,
    pub error: Option<String>,
}

#[derive(Clone, Debug)]
pub struct WebSessionIdentitySnapshot {
    pub has_sessdata: bool,
    pub has_dede_user_id: bool,
    pub has_bili_jct: bool,
    pub has_access_token: bool,
    pub cookie_count: usize,
    pub mid: Option<i64>,
}

impl HttpClient {
    pub fn new() -> CoreResult<Self> {
        let jar = Arc::new(Jar::default());
        ensure_default_web_identity(&jar);
        let client = Client::builder()
            .cookie_provider(jar.clone())
            .gzip(true)
            .redirect(Policy::limited(10))
            .timeout(std::time::Duration::from_secs(20))
            .connect_timeout(std::time::Duration::from_secs(10))
            .danger_accept_invalid_certs(false)
            .user_agent(UA_TV)
            .build()
            .map_err(|e| CoreError::Internal(net_msg(&e)))?;
        Ok(Self {
            client,
            jar,
            web_identity_activation: Mutex::new(WebIdentityActivationState::default()),
        })
    }

    /// Inject web cookies (e.g. SESSDATA / bili_jct / DedeUserID) into the
    /// shared jar so subsequent web-flavoured requests carry them.
    /// `pairs` is `(name, value)`; cookies are scoped to `.bilibili.com`.
    pub fn install_web_cookies(&self, pairs: &[(String, String)]) {
        let url: Url = "https://api.bilibili.com/".parse().expect("valid url");
        ensure_default_web_identity(&self.jar);
        if pairs.is_empty() {
            return;
        }
        for (name, value) in pairs {
            let cookie = format!("{}={}; Domain=.bilibili.com; Path=/; Secure", name, value);
            self.jar.add_cookie_str(&cookie, &url);
        }
    }

    /// Match upstream PiliPlus's best-effort `buvid3` activation request.
    /// Bilibili sometimes gates web playback capabilities behind this risk
    /// fingerprint endpoint; failure is diagnostic only and must not block
    /// regular playback.
    pub fn ensure_web_identity_activated(&self) -> WebIdentityActivationSnapshot {
        let buvid3 = ensure_default_web_identity(&self.jar);
        {
            let mut state = self.web_identity_activation.lock();
            if state.buvid3.as_deref() == Some(&buvid3) && state.attempted {
                return WebIdentityActivationSnapshot {
                    buvid3,
                    attempted: state.attempted,
                    attempted_now: false,
                    succeeded: state.succeeded,
                    error: state.error.clone(),
                };
            }
            state.buvid3 = Some(buvid3.clone());
            state.attempted = true;
            state.succeeded = false;
            state.error = None;
        }

        let activation_result = self.activate_current_buvid();
        let mut state = self.web_identity_activation.lock();
        if state.buvid3.as_deref() == Some(&buvid3) {
            match activation_result {
                Ok(()) => {
                    state.succeeded = true;
                    state.error = None;
                }
                Err(error) => {
                    state.succeeded = false;
                    state.error = Some(error);
                }
            }
            WebIdentityActivationSnapshot {
                buvid3,
                attempted: state.attempted,
                attempted_now: true,
                succeeded: state.succeeded,
                error: state.error.clone(),
            }
        } else {
            WebIdentityActivationSnapshot {
                buvid3,
                attempted: true,
                attempted_now: true,
                succeeded: false,
                error: Some("buvid changed during activation".into()),
            }
        }
    }

    /// Read currently stored web cookies for bilibili.com. Useful at logout
    /// (we just drop the whole HttpClient instead in practice) and for
    /// snapshotting at login time.
    pub fn snapshot_cookies(&self) -> Vec<(String, String)> {
        let url: Url = "https://api.bilibili.com/".parse().expect("valid url");
        let Some(value) = self.jar.cookies(&url) else {
            return Vec::new();
        };
        let raw = value.to_str().unwrap_or("").to_string();
        raw.split(';')
            .filter_map(|p| {
                let p = p.trim();
                let eq = p.find('=')?;
                Some((p[..eq].to_string(), p[eq + 1..].to_string()))
            })
            .collect()
    }

    pub fn web_user_mid(&self) -> Option<i64> {
        self.snapshot_cookies()
            .into_iter()
            .find(|(k, _)| k == "DedeUserID")
            .and_then(|(_, v)| v.parse::<i64>().ok())
    }

    pub fn web_session_identity_snapshot(
        &self,
        has_access_token: bool,
    ) -> WebSessionIdentitySnapshot {
        let cookies = self.snapshot_cookies();
        let has_cookie = |name: &str| {
            cookies
                .iter()
                .any(|(key, value)| key == name && !value.is_empty())
        };
        let mid = cookies
            .iter()
            .find(|(key, _)| key == "DedeUserID")
            .and_then(|(_, value)| value.parse::<i64>().ok());
        WebSessionIdentitySnapshot {
            has_sessdata: has_cookie("SESSDATA"),
            has_dede_user_id: has_cookie("DedeUserID"),
            has_bili_jct: has_cookie("bili_jct"),
            has_access_token,
            cookie_count: cookies.len(),
            mid,
        }
    }

    fn activate_current_buvid(&self) -> Result<(), String> {
        let rand_png_end = base64_encode(&buvid_activation_random_bytes());
        let start = rand_png_end.len().saturating_sub(50);
        let payload = json!({
            "3064": 1,
            "39c8": "333.1387.fp.risk",
            "3c43": {
                "adca": "Linux",
                "bfe9": &rand_png_end[start..],
            },
        })
        .to_string();
        let resp = apply_default_web_headers(self.client.post(ACTIVATE_BUVID_URL), self)
            .json(&json!({ "payload": payload }))
            .send()
            .map_err(|e| net_msg(&e))?;
        let status = resp.status();
        let body = resp.text().map_err(|e| net_msg(&e))?;
        if !status.is_success() {
            return Err(format!(
                "http {}: {}",
                status.as_u16(),
                body.chars().take(200).collect::<String>()
            ));
        }
        let env: ApiEnvelope<serde_json::Value> = serde_json::from_str(&body).map_err(|e| {
            format!(
                "decode: {e}: {}",
                body.chars().take(200).collect::<String>()
            )
        })?;
        if env.code != 0 {
            return Err(format!("code={} msg={}", env.code, env.message));
        }
        Ok(())
    }

    pub fn get_signed_app<T: DeserializeOwned>(
        &self,
        url: &str,
        mut params: Vec<(String, String)>,
    ) -> CoreResult<T> {
        crate::signer::AppSigner::sign(&mut params);
        let resp = self
            .client
            .get(url)
            .headers(app_headers())
            .query(&params)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    pub fn get_signed_android_app<T: DeserializeOwned>(
        &self,
        url: &str,
        mut params: Vec<(String, String)>,
    ) -> CoreResult<T> {
        crate::signer::AppSigner::sign(&mut params);
        let resp = self
            .client
            .get(url)
            .headers(android_app_headers())
            .query(&params)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    pub fn get_android_app<T: DeserializeOwned>(
        &self,
        url: &str,
        params: &[(String, String)],
    ) -> CoreResult<T> {
        let resp = self
            .client
            .get(url)
            .headers(android_app_headers())
            .query(params)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    pub fn post_signed_app<T: DeserializeOwned>(
        &self,
        url: &str,
        mut params: Vec<(String, String)>,
    ) -> CoreResult<T> {
        crate::signer::AppSigner::sign(&mut params);
        // PiliPlus posts with queryParameters (URL-encoded query, empty body).
        let resp = self
            .client
            .post(url)
            .headers(app_headers())
            .query(&params)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    pub fn get_signed_web<T: DeserializeOwned>(
        &self,
        url: &str,
        mut params: Vec<(String, String)>,
        key: &crate::signer::WbiKey,
    ) -> CoreResult<T> {
        crate::signer::WbiSigner::sign(&mut params, key);
        let resp = apply_default_web_headers(self.client.get(url), self)
            .query(&params)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    pub fn get_signed_web_with_headers<T: DeserializeOwned>(
        &self,
        url: &str,
        mut params: Vec<(String, String)>,
        key: &crate::signer::WbiKey,
        extra_headers: &[(&str, String)],
    ) -> CoreResult<T> {
        use reqwest::header::{HeaderName, HeaderValue};
        crate::signer::WbiSigner::sign(&mut params, key);
        let mut req = apply_default_web_headers(self.client.get(url), self).query(&params);
        for (name, value) in extra_headers {
            if let (Ok(name), Ok(value)) = (
                HeaderName::from_bytes(name.as_bytes()),
                HeaderValue::from_str(value),
            ) {
                req = req.header(name, value);
            }
        }
        let resp = req.send().map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    pub fn get_web<T: DeserializeOwned>(
        &self,
        url: &str,
        params: &[(String, String)],
    ) -> CoreResult<T> {
        let resp = apply_default_web_headers(self.client.get(url), self)
            .query(params)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    pub fn get_web_with_headers<T: DeserializeOwned>(
        &self,
        url: &str,
        params: &[(String, String)],
        extra_headers: &[(&str, String)],
    ) -> CoreResult<T> {
        use reqwest::header::{HeaderName, HeaderValue};
        let mut req = apply_default_web_headers(self.client.get(url), self).query(params);
        for (name, value) in extra_headers {
            if let (Ok(name), Ok(value)) = (
                HeaderName::from_bytes(name.as_bytes()),
                HeaderValue::from_str(value),
            ) {
                req = req.header(name, value);
            }
        }
        let resp = req.send().map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    /// POST to a web-flavoured endpoint with `application/x-www-form-urlencoded`
    /// body, attaching cookies from the shared jar (so SESSDATA / bili_jct
    /// authenticate the request). Used for write actions that require a CSRF
    /// token (like / coin / triple / favorite / relation / watchlater /
    /// reply.add). Caller must include `csrf` in `form` when needed.
    pub fn post_form_web<T: DeserializeOwned>(
        &self,
        url: &str,
        form: &[(String, String)],
    ) -> CoreResult<T> {
        let resp = apply_default_web_headers(self.client.post(url), self)
            .form(form)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    /// Same as `post_form_web`, but accepts `data:null` / missing data.
    /// Mutating Bilibili endpoints often signal success purely through
    /// `{code:0}`.
    pub fn post_form_web_empty(&self, url: &str, form: &[(String, String)]) -> CoreResult<()> {
        let resp = apply_default_web_headers(self.client.post(url), self)
            .form(form)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        let env: ApiEnvelope<serde_json::Value> = serde_json::from_str(&body).map_err(|e| {
            CoreError::Decode(format!(
                "{}: {}",
                e,
                body.chars().take(500).collect::<String>()
            ))
        })?;
        if env.code != 0 {
            return Err(CoreError::Api {
                code: env.code,
                msg: env.message,
            });
        }
        Ok(())
    }

    /// POST a web form with query parameters and custom headers. Live
    /// message submit keeps WBI auth in the query string and CSRF in the
    /// form body, while requiring the live-room referer.
    pub fn post_form_web_with_headers<T: DeserializeOwned>(
        &self,
        url: &str,
        query: &[(String, String)],
        form: &[(String, String)],
        extra_headers: &[(&str, String)],
    ) -> CoreResult<T> {
        use reqwest::header::{HeaderName, HeaderValue};
        let mut req = apply_default_web_headers(self.client.post(url), self)
            .query(query)
            .form(form);
        for (name, value) in extra_headers {
            if let (Ok(name), Ok(value)) = (
                HeaderName::from_bytes(name.as_bytes()),
                HeaderValue::from_str(value),
            ) {
                req = req.header(name, value);
            }
        }
        let resp = req.send().map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    /// POST a multipart form with one binary file part plus arbitrary
    /// text fields. Used by `upload_bfs` (image attachments for
    /// reply / dynamic). The file MIME type is sniffed from the file
    /// extension; falls back to `application/octet-stream`.
    pub fn post_multipart_web<T: DeserializeOwned>(
        &self,
        url: &str,
        text_fields: &[(&str, String)],
        file_field: &str,
        file_name: String,
        file_bytes: Vec<u8>,
    ) -> CoreResult<T> {
        use reqwest::blocking::multipart::{Form, Part};
        let mime = mime_for_filename(&file_name);
        let part = Part::bytes(file_bytes)
            .file_name(file_name)
            .mime_str(mime)
            .map_err(|e| CoreError::Network(format!("multipart mime: {e}")))?;
        let mut form = Form::new().part(file_field.to_string(), part);
        for (k, v) in text_fields {
            form = form.text(k.to_string(), v.clone());
        }
        let resp = apply_default_web_headers(self.client.post(url), self)
            .multipart(form)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    /// Read the `bili_jct` cookie (CSRF token) from the shared jar.
    /// Returns `None` if the user has not logged in via web cookies yet.
    pub fn csrf_token(&self) -> Option<String> {
        self.snapshot_cookies()
            .into_iter()
            .find(|(k, _)| k == "bili_jct")
            .map(|(_, v)| v)
    }

    /// Fetch raw bytes — used for endpoints that return non-JSON payloads
    /// (e.g. the deflated-XML danmaku list).
    pub fn get_bytes_web(&self, url: &str, params: &[(String, String)]) -> CoreResult<Vec<u8>> {
        let resp = apply_default_web_headers(self.client.get(url), self)
            .query(params)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let bytes = resp.bytes().map_err(|e| CoreError::Network(net_msg(&e)))?;
        Ok(bytes.to_vec())
    }
}

/// Render a reqwest error including the full source chain so the iOS layer can
/// show the real cause (TLS handshake, DNS, etc.) instead of just the URL.
fn net_msg(e: &reqwest::Error) -> String {
    let mut out = format!("{e}");
    let mut src: Option<&dyn std::error::Error> = std::error::Error::source(e);
    while let Some(s) = src {
        out.push_str(" → ");
        out.push_str(&s.to_string());
        src = std::error::Error::source(s);
    }
    out
}

fn apply_default_web_headers(builder: RequestBuilder, client: &HttpClient) -> RequestBuilder {
    builder.headers(default_web_header_map(client))
}

fn default_web_headers(client: &HttpClient) -> Vec<(&'static str, String)> {
    let mut headers = vec![
        ("User-Agent", UA_WEB.to_string()),
        ("Referer", WEB_REFERER.to_string()),
        ("env", "prod".to_string()),
        ("app-key", "android64".to_string()),
        ("x-bili-aurora-zone", "sh001".to_string()),
    ];
    if let Some(mid) = client.web_user_mid().filter(|mid| *mid > 0) {
        headers.push(("x-bili-mid", mid.to_string()));
        headers.push(("x-bili-aurora-eid", gen_aurora_eid(mid)));
    }
    headers
}

pub fn default_web_header_map(client: &HttpClient) -> reqwest::header::HeaderMap {
    use reqwest::header::{HeaderMap, HeaderName, HeaderValue};

    let _ = ensure_default_web_identity(&client.jar);

    let mut headers = HeaderMap::new();
    let pairs = default_web_headers(client);
    for (name, value) in pairs {
        if let (Ok(header_name), Ok(header_value)) = (
            HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(&value),
        ) {
            headers.insert(header_name, header_value);
        }
    }
    headers
}

fn ensure_default_web_identity(jar: &Jar) -> String {
    let url: Url = BUVID_URL.parse().expect("valid buvid url");
    let current = jar
        .cookies(&url)
        .and_then(|raw| raw.to_str().ok().map(|s| s.to_string()))
        .unwrap_or_default();
    if let Some(existing) = cookie_header_value(&current, "buvid3") {
        return existing;
    }
    let buvid3 = gen_buvid3();
    {
        let cookie = format!("buvid3={}; Domain=.bilibili.com; Path=/; Secure", buvid3);
        jar.add_cookie_str(&cookie, &url);
    }
    buvid3
}

fn cookie_header_value(header: &str, target_name: &str) -> Option<String> {
    header.split(';').find_map(|part| {
        let trimmed = part.trim();
        let (name, value) = trimmed.split_once('=')?;
        (name == target_name).then(|| value.to_string())
    })
}

fn gen_buvid3() -> String {
    let mut seed = web_identity_seed();
    let mut bytes = [0u8; 16];
    for byte in &mut bytes {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        *byte = (seed >> 32) as u8;
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}{:05}infoc",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15],
        seed % 100_000
    )
}

fn gen_aurora_eid(uid: i64) -> String {
    if uid <= 0 {
        return String::new();
    }
    let mut bytes = uid.to_string().into_bytes();
    let key = b"ad1va46a7lza";
    for (index, byte) in bytes.iter_mut().enumerate() {
        *byte ^= key[index % key.len()];
    }
    let mut encoded = base64_encode(&bytes);
    while encoded.ends_with('=') {
        encoded.pop();
    }
    encoded
}

fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    let mut index = 0;
    while index < bytes.len() {
        let b0 = bytes[index];
        let b1 = bytes.get(index + 1).copied().unwrap_or(0);
        let b2 = bytes.get(index + 2).copied().unwrap_or(0);
        out.push(TABLE[(b0 >> 2) as usize] as char);
        out.push(TABLE[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
        if index + 1 < bytes.len() {
            out.push(TABLE[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char);
        } else {
            out.push('=');
        }
        if index + 2 < bytes.len() {
            out.push(TABLE[(b2 & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
        index += 3;
    }
    out
}

fn web_identity_seed() -> u64 {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    nanos
        ^ WEB_IDENTITY_COUNTER
            .fetch_add(1, Ordering::Relaxed)
            .rotate_left(11)
}

fn buvid_activation_random_bytes() -> Vec<u8> {
    let mut state = web_identity_seed();
    let mut bytes = Vec::with_capacity(40);
    for _ in 0..32 {
        state = state
            .wrapping_mul(2862933555777941757)
            .wrapping_add(3037000493);
        bytes.push((state >> 24) as u8);
    }
    bytes.extend([0, 0, 0, 0, 73, 69, 78, 68]);
    for _ in 0..4 {
        state = state.wrapping_mul(3202034522624059733).wrapping_add(1);
        bytes.push((state >> 32) as u8);
    }
    bytes
}

fn unwrap_envelope<T: DeserializeOwned>(body: String) -> CoreResult<T> {
    let env: ApiEnvelope<T> = serde_json::from_str(&body).map_err(|e| {
        CoreError::Decode(format!(
            "{}: {}",
            e,
            body.chars().take(500).collect::<String>()
        ))
    })?;
    if env.code != 0 {
        return Err(CoreError::Api {
            code: env.code,
            msg: env.message,
        });
    }
    env.data
        .ok_or_else(|| CoreError::Decode("missing data".into()))
}

fn mime_for_filename(name: &str) -> &'static str {
    let lower = name.to_ascii_lowercase();
    if lower.ends_with(".png") {
        "image/png"
    } else if lower.ends_with(".jpg") || lower.ends_with(".jpeg") {
        "image/jpeg"
    } else if lower.ends_with(".gif") {
        "image/gif"
    } else if lower.ends_with(".webp") {
        "image/webp"
    } else if lower.ends_with(".heic") {
        "image/heic"
    } else {
        "application/octet-stream"
    }
}
