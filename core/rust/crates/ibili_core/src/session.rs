use serde::{Deserialize, Serialize};

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct PersistedSession {
    pub access_token: String,
    pub refresh_token: String,
    pub mid: i64,
    pub expires_at_secs: i64,
    /// Web-flavoured cookies (SESSDATA / bili_jct / DedeUserID …) returned
    /// alongside the TV QR poll response. Required for `/x/player/wbi/playurl`,
    /// `/x/web-interface/nav` and any other web-side endpoint to authenticate
    /// the user — without these, B 站 caps anonymous web playurl at qn=64.
    /// Optional in JSON for backward compatibility with sessions persisted
    /// before this field existed.
    #[serde(default)]
    pub web_cookies: Vec<(String, String)>,
}

#[derive(Debug, Default, Clone, Serialize)]
pub struct SessionSnapshot {
    pub logged_in: bool,
    pub mid: i64,
    pub expires_at_secs: i64,
}

#[derive(Debug, Default, Clone)]
pub struct Session {
    pub persisted: Option<PersistedSession>,
}

impl Session {
    pub fn from_persisted(p: PersistedSession) -> Self {
        Self { persisted: Some(p) }
    }
    pub fn snapshot(&self) -> SessionSnapshot {
        match &self.persisted {
            Some(p) => SessionSnapshot {
                logged_in: true,
                mid: p.mid,
                expires_at_secs: p.expires_at_secs,
            },
            None => SessionSnapshot::default(),
        }
    }
    pub fn access_key(&self) -> Option<String> {
        self.persisted
            .as_ref()
            .filter(|p| !p.access_token.is_empty())
            .map(|p| p.access_token.clone())
    }

    pub fn has_web_session(&self) -> bool {
        self.persisted.as_ref().is_some_and(|p| {
            p.mid > 0
                && p.web_cookies
                    .iter()
                    .any(|(name, value)| name == "SESSDATA" && !value.is_empty())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cookie_session_authenticates_web_but_not_app_endpoints() {
        let session = Session::from_persisted(PersistedSession {
            mid: 42,
            web_cookies: vec![("SESSDATA".into(), "test".into())],
            ..Default::default()
        });
        assert!(session.has_web_session());
        assert!(session.access_key().is_none());
        assert!(session.snapshot().logged_in);
        assert!(!Session::default().has_web_session());
    }
}
