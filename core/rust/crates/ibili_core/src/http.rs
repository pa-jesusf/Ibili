use crate::error::{CoreError, CoreResult};
use crate::dto::ApiEnvelope;
use reqwest::blocking::Client;
use serde::de::DeserializeOwned;

/// Matches PiliPlus `Constants.userAgent` (android_hd/TV User-Agent).
pub const UA_TV: &str = "Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android model/android_hd mobi_app/android_hd build/2001100 channel/master innerVer/2001100 osVer/15 network/2";
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

pub struct HttpClient {
    pub client: Client,
}

impl HttpClient {
    pub fn new() -> CoreResult<Self> {
        let client = Client::builder()
            .cookie_store(true)
            .gzip(true)
            .timeout(std::time::Duration::from_secs(20))
            .connect_timeout(std::time::Duration::from_secs(10))
            .danger_accept_invalid_certs(false)
            .user_agent(UA_TV)
            .build()
            .map_err(|e| CoreError::Internal(net_msg(&e)))?;
        Ok(Self { client })
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

