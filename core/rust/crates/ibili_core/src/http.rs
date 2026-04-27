use crate::error::{CoreError, CoreResult};
use crate::dto::ApiEnvelope;
use reqwest::blocking::Client;
use serde::de::DeserializeOwned;

pub const UA_TV: &str = "Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android model/MI6 mobi_app/android_tv build/2001100 channel/master innerVer/2001100 osVer/12 network/2";
pub const UA_WEB: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.1 Safari/605.1.15";

pub struct HttpClient {
    pub client: Client,
}

impl HttpClient {
    pub fn new() -> CoreResult<Self> {
        let client = Client::builder()
            .cookie_store(true)
            .gzip(true)
            .timeout(std::time::Duration::from_secs(20))
            .build()
            .map_err(|e| CoreError::Internal(e.to_string()))?;
        Ok(Self { client })
    }

    pub fn get_signed_app<T: DeserializeOwned>(
        &self, url: &str, mut params: Vec<(String, String)>,
    ) -> CoreResult<T> {
        crate::signer::AppSigner::sign(&mut params);
        let resp = self.client.get(url)
            .header("User-Agent", UA_TV)
            .query(&params)
            .send()?;
        unwrap_envelope(resp.text()?)
    }

    pub fn post_signed_app<T: DeserializeOwned>(
        &self, url: &str, mut params: Vec<(String, String)>,
    ) -> CoreResult<T> {
        crate::signer::AppSigner::sign(&mut params);
        let resp = self.client.post(url)
            .header("User-Agent", UA_TV)
            .form(&params)
            .send()?;
        unwrap_envelope(resp.text()?)
    }

    pub fn get_web<T: DeserializeOwned>(
        &self, url: &str, params: &[(String, String)],
    ) -> CoreResult<T> {
        let resp = self.client.get(url)
            .header("User-Agent", UA_WEB)
            .header("Referer", "https://www.bilibili.com/")
            .query(params)
            .send()?;
        unwrap_envelope(resp.text()?)
    }
}

fn unwrap_envelope<T: DeserializeOwned>(body: String) -> CoreResult<T> {
    let env: ApiEnvelope<T> = serde_json::from_str(&body)
        .map_err(|e| CoreError::Decode(format!("{}: {}", e, body.chars().take(500).collect::<String>())))?;
    if env.code != 0 {
        return Err(CoreError::Api { code: env.code, msg: env.message });
    }
    env.data.ok_or_else(|| CoreError::Decode("missing data".into()))
}
