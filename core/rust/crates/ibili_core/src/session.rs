use serde::{Deserialize, Serialize};

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct PersistedSession {
    pub access_token: String,
    pub refresh_token: String,
    pub mid: i64,
    pub expires_at_secs: i64,
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
            Some(p) => SessionSnapshot { logged_in: true, mid: p.mid, expires_at_secs: p.expires_at_secs },
            None => SessionSnapshot::default(),
        }
    }
    pub fn access_key(&self) -> Option<String> {
        self.persisted.as_ref().map(|p| p.access_token.clone())
    }
}
