use crate::Core;
use crate::dto::{TvQrStart, TvQrPoll};
use crate::error::{CoreError, CoreResult};
use crate::session::PersistedSession;
use serde::Deserialize;

const URL_AUTH_CODE: &str = "https://passport.bilibili.com/x/passport-tv-login/qrcode/auth_code";
const URL_POLL: &str = "https://passport.bilibili.com/x/passport-tv-login/qrcode/poll";

#[derive(Deserialize)]
struct AuthCodeData { auth_code: String, url: String }

#[derive(Deserialize)]
struct PollData {
    access_token: String,
    refresh_token: String,
    mid: i64,
    expires_in: i64,
    /// TV QR poll returns web-side cookies (SESSDATA / bili_jct / DedeUserID …)
    /// alongside the access_token. Mirrors PiliPlus
    /// `data['cookie_info']['cookies']` consumed in
    /// `lib/pages/login/controller.dart::setAccount`.
    #[serde(default)]
    cookie_info: Option<CookieInfo>,
}

#[derive(Deserialize)]
struct CookieInfo {
    #[serde(default)]
    cookies: Vec<CookiePair>,
}

#[derive(Deserialize)]
struct CookiePair {
    name: String,
    value: String,
}

impl Core {
    pub fn auth_tv_qr_start(&self) -> CoreResult<TvQrStart> {
        // PiliPlus LoginHttp.getHDcode params (lib/http/login.dart).
        let params = vec![
            ("local_id".into(), "0".into()),
            ("platform".into(), "android".into()),
            ("mobi_app".into(), "android_hd".into()),
        ];
        let d: AuthCodeData = self.http.post_signed_app(URL_AUTH_CODE, params)?;
        Ok(TvQrStart { auth_code: d.auth_code, url: d.url })
    }

    pub fn auth_tv_qr_poll(&self, auth_code: &str) -> CoreResult<TvQrPoll> {
        let params = vec![
            ("auth_code".into(), auth_code.into()),
            ("local_id".into(), "0".into()),
        ];
        match self.http.post_signed_app::<PollData>(URL_POLL, params) {
            Ok(d) => {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
                let web_cookies: Vec<(String, String)> = d.cookie_info
                    .map(|ci| ci.cookies.into_iter().map(|c| (c.name, c.value)).collect())
                    .unwrap_or_default();
                // Push cookies into the live http jar so the very next
                // wbi/playurl call (e.g. user immediately taps a video) is
                // authenticated, not just future restored sessions.
                self.http.install_web_cookies(&web_cookies);
                let session = PersistedSession {
                    access_token: d.access_token,
                    refresh_token: d.refresh_token,
                    mid: d.mid,
                    expires_at_secs: now + d.expires_in,
                    web_cookies,
                };
                *self.session.write() = crate::session::Session::from_persisted(session.clone());
                Ok(TvQrPoll::Confirmed { session })
            }
            // Bilibili TV poll: 0=ok, 86038=expired, 86039=pending (not scanned),
            // 86090=scanned awaiting confirm. Treat anything that isn't an explicit
            // scanned/expired signal as pending so we don't show false "scanned".
            Err(CoreError::Api { code, msg }) => match code {
                86038 => Ok(TvQrPoll::Expired),
                86090 => Ok(TvQrPoll::Scanned),
                86039 => Ok(TvQrPoll::Pending),
                _ if msg.contains("未扫描") || msg.contains("unscanned") => Ok(TvQrPoll::Pending),
                _ if msg.contains("未确认") || msg.contains("unconfirmed") => Ok(TvQrPoll::Scanned),
                _ => Err(CoreError::Api { code, msg }),
            },
            Err(e) => Err(e),
        }
    }
}
