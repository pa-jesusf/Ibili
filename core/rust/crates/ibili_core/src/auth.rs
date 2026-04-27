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
}

impl Core {
    pub fn auth_tv_qr_start(&self) -> CoreResult<TvQrStart> {
        let params = vec![
            ("local_id".into(), "0".into()),
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
                let session = PersistedSession {
                    access_token: d.access_token,
                    refresh_token: d.refresh_token,
                    mid: d.mid,
                    expires_at_secs: now + d.expires_in,
                };
                *self.session.write() = crate::session::Session::from_persisted(session.clone());
                Ok(TvQrPoll::Confirmed { session })
            }
            Err(CoreError::Api { code, .. }) => match code {
                86038 => Ok(TvQrPoll::Expired),
                86039 => Ok(TvQrPoll::Scanned),    // scanned, awaiting confirm
                86090 => Ok(TvQrPoll::Scanned),
                86101 => Ok(TvQrPoll::Pending),    // not scanned
                _ => Err(CoreError::Api { code, msg: format!("poll code {code}") }),
            },
            Err(e) => Err(e),
        }
    }
}
