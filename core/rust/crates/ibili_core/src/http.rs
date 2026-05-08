use crate::error::{CoreError, CoreResult};
use crate::dto::ApiEnvelope;
use reqwest::Url;
use reqwest::blocking::Client;
use reqwest::cookie::{CookieStore, Jar};
use serde::de::DeserializeOwned;
use std::sync::Arc;

/// Matches PiliPlus `Constants.userAgent` (android_hd/TV User-Agent).
pub const UA_TV: &str = "Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android model/android_hd mobi_app/android_hd build/2001100 channel/master innerVer/2001100 osVer/15 network/2";
pub const UA_ANDROID_APP: &str = "Mozilla/5.0 BiliDroid/8.43.0 (bbcallen@gmail.com) os/android model/android mobi_app/android build/8430300 channel/master innerVer/8430300 osVer/15 network/2";
pub const UA_WEB: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.1 Safari/605.1.15";

/// Headers PiliPlus attaches to every app endpoint call.
fn app_headers() -> reqwest::header::HeaderMap {
    use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
    let mut h = HeaderMap::new();
    let pairs: &[(&str, &str)] = &[
        ("User-Agent", UA_TV),
        ("env", "prod"),
        ("app-key", "android_hd"),
        ("x-bili-trace-id", "11111111111111111111111111111111:1111111111111111:0:0"),
        ("x-bili-aurora-eid", ""),
        ("x-bili-aurora-zone", ""),
        ("bili-http-engine", "cronet"),
        ("buvid", "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFFinfoc"),
    ];
    for (k, v) in pairs {
        if let (Ok(name), Ok(val)) = (HeaderName::from_bytes(k.as_bytes()), HeaderValue::from_str(v)) {
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
        ("x-bili-trace-id", "11111111111111111111111111111111:1111111111111111:0:0"),
        ("x-bili-aurora-eid", ""),
        ("x-bili-aurora-zone", ""),
        ("bili-http-engine", "cronet"),
        ("buvid", "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFFinfoc"),
        ("fp_local", "1111111111111111111111111111111111111111111111111111111111111111"),
        ("fp_remote", "1111111111111111111111111111111111111111111111111111111111111111"),
        ("session_id", "11111111"),
    ];
    for (k, v) in pairs {
        if let (Ok(name), Ok(val)) = (HeaderName::from_bytes(k.as_bytes()), HeaderValue::from_str(v)) {
            h.insert(name, val);
        }
    }
    h
}

pub struct HttpClient {
    pub client: Client,
    pub jar: Arc<Jar>,
}

impl HttpClient {
    pub fn new() -> CoreResult<Self> {
        let jar = Arc::new(Jar::default());
        let client = Client::builder()
            .cookie_provider(jar.clone())
            .gzip(true)
            .timeout(std::time::Duration::from_secs(20))
            .connect_timeout(std::time::Duration::from_secs(10))
            .danger_accept_invalid_certs(false)
            .user_agent(UA_TV)
            .build()
            .map_err(|e| CoreError::Internal(net_msg(&e)))?;
        Ok(Self { client, jar })
    }

    /// Inject web cookies (e.g. SESSDATA / bili_jct / DedeUserID) into the
    /// shared jar so subsequent web-flavoured requests carry them.
    /// `pairs` is `(name, value)`; cookies are scoped to `.bilibili.com`.
    pub fn install_web_cookies(&self, pairs: &[(String, String)]) {
        if pairs.is_empty() { return; }
        let url: Url = "https://api.bilibili.com/".parse().expect("valid url");
        for (name, value) in pairs {
            let cookie = format!(
                "{}={}; Domain=.bilibili.com; Path=/; Secure",
                name, value
            );
            self.jar.add_cookie_str(&cookie, &url);
        }
    }

    /// Read currently stored web cookies for bilibili.com. Useful at logout
    /// (we just drop the whole HttpClient instead in practice) and for
    /// snapshotting at login time.
    pub fn snapshot_cookies(&self) -> Vec<(String, String)> {
        let url: Url = "https://api.bilibili.com/".parse().expect("valid url");
        let Some(value) = self.jar.cookies(&url) else { return Vec::new(); };
        let raw = value.to_str().unwrap_or("").to_string();
        raw.split(';')
            .filter_map(|p| {
                let p = p.trim();
                let eq = p.find('=')?;
                Some((p[..eq].to_string(), p[eq + 1..].to_string()))
            })
            .collect()
    }

    pub fn get_signed_app<T: DeserializeOwned>(
        &self, url: &str, mut params: Vec<(String, String)>,
    ) -> CoreResult<T> {
        crate::signer::AppSigner::sign(&mut params);
        let resp = self.client.get(url)
            .headers(app_headers())
            .query(&params)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    pub fn get_signed_android_app<T: DeserializeOwned>(
        &self, url: &str, mut params: Vec<(String, String)>,
    ) -> CoreResult<T> {
        crate::signer::AppSigner::sign(&mut params);
        let resp = self.client.get(url)
            .headers(android_app_headers())
            .query(&params)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    pub fn get_android_app<T: DeserializeOwned>(
        &self, url: &str, params: &[(String, String)],
    ) -> CoreResult<T> {
        let resp = self.client.get(url)
            .headers(android_app_headers())
            .query(params)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    pub fn post_signed_app<T: DeserializeOwned>(
        &self, url: &str, mut params: Vec<(String, String)>,
    ) -> CoreResult<T> {
        crate::signer::AppSigner::sign(&mut params);
        // PiliPlus posts with queryParameters (URL-encoded query, empty body).
        let resp = self.client.post(url)
            .headers(app_headers())
            .query(&params)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    pub fn get_signed_web<T: DeserializeOwned>(
        &self, url: &str, mut params: Vec<(String, String)>, key: &crate::signer::WbiKey,
    ) -> CoreResult<T> {
        crate::signer::WbiSigner::sign(&mut params, key);
        let resp = self.client.get(url)
            .header("User-Agent", UA_WEB)
            .header("Referer", "https://www.bilibili.com/")
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
        let mut req = self.client.get(url)
            .header("User-Agent", UA_WEB)
            .header("Referer", "https://www.bilibili.com/")
            .query(&params);
        for (name, value) in extra_headers {
            if let (Ok(name), Ok(value)) = (
                HeaderName::from_bytes(name.as_bytes()),
                HeaderValue::from_str(value),
            ) {
                req = req.header(name, value);
            }
        }
        let resp = req
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    pub fn get_web<T: DeserializeOwned>(
        &self, url: &str, params: &[(String, String)],
    ) -> CoreResult<T> {
        let resp = self.client.get(url)
            .header("User-Agent", UA_WEB)
            .header("Referer", "https://www.bilibili.com/")
            .query(params)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
        let body = resp.text().map_err(|e| CoreError::Network(net_msg(&e)))?;
        unwrap_envelope(body)
    }

    /// POST to a web-flavoured endpoint with `application/x-www-form-urlencoded`
    /// body, attaching cookies from the shared jar (so SESSDATA / bili_jct
    /// authenticate the request). Used for write actions that require a CSRF
    /// token (like / coin / triple / favorite / relation / watchlater /
    /// reply.add). Caller must include `csrf` in `form` when needed.
    pub fn post_form_web<T: DeserializeOwned>(
        &self, url: &str, form: &[(String, String)],
    ) -> CoreResult<T> {
        let resp = self.client.post(url)
            .header("User-Agent", UA_WEB)
            .header("Referer", "https://www.bilibili.com/")
            .form(form)
            .send()
            .map_err(|e| CoreError::Network(net_msg(&e)))?;
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
        let resp = self.client.post(url)
            .header("User-Agent", UA_WEB)
            .header("Referer", "https://www.bilibili.com/")
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
    pub fn get_bytes_web(
        &self, url: &str, params: &[(String, String)],
    ) -> CoreResult<Vec<u8>> {
        let resp = self.client.get(url)
            .header("User-Agent", UA_WEB)
            .header("Referer", "https://www.bilibili.com/")
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

fn unwrap_envelope<T: DeserializeOwned>(body: String) -> CoreResult<T> {
    let env: ApiEnvelope<T> = serde_json::from_str(&body)
        .map_err(|e| CoreError::Decode(format!("{}: {}", e, body.chars().take(500).collect::<String>())))?;
    if env.code != 0 {
        return Err(CoreError::Api { code: env.code, msg: env.message });
    }
    env.data.ok_or_else(|| CoreError::Decode("missing data".into()))
}


fn mime_for_filename(name: &str) -> &'static str {
    let lower = name.to_ascii_lowercase();
    if lower.ends_with(".png") { "image/png" }
    else if lower.ends_with(".jpg") || lower.ends_with(".jpeg") { "image/jpeg" }
    else if lower.ends_with(".gif") { "image/gif" }
    else if lower.ends_with(".webp") { "image/webp" }
    else if lower.ends_with(".heic") { "image/heic" }
    else { "application/octet-stream" }
}
