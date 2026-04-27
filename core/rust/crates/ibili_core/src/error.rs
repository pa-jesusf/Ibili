use serde::Serialize;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("network error: {0}")]
    Network(String),
    #[error("decode error: {0}")]
    Decode(String),
    #[error("api error code={code} msg={msg}")]
    Api { code: i64, msg: String },
    #[error("auth required")]
    AuthRequired,
    #[error("login pending")]
    LoginPending,
    #[error("login expired")]
    LoginExpired,
    #[error("invalid argument: {0}")]
    InvalidArgument(String),
    #[error("not found")]
    NotFound,
    #[error("internal: {0}")]
    Internal(String),
}

pub type CoreResult<T> = Result<T, CoreError>;

#[derive(Debug, Serialize)]
pub struct ErrorEnvelope {
    pub category: &'static str,
    pub message: String,
    pub code: Option<i64>,
}

impl From<&CoreError> for ErrorEnvelope {
    fn from(e: &CoreError) -> Self {
        match e {
            CoreError::Network(m) => Self { category: "network", message: m.clone(), code: None },
            CoreError::Decode(m) => Self { category: "decode", message: m.clone(), code: None },
            CoreError::Api { code, msg } => Self { category: "api", message: msg.clone(), code: Some(*code) },
            CoreError::AuthRequired => Self { category: "auth_required", message: "auth required".into(), code: None },
            CoreError::LoginPending => Self { category: "login_pending", message: "pending".into(), code: None },
            CoreError::LoginExpired => Self { category: "login_expired", message: "qr expired".into(), code: None },
            CoreError::InvalidArgument(m) => Self { category: "invalid_argument", message: m.clone(), code: None },
            CoreError::NotFound => Self { category: "not_found", message: "not found".into(), code: None },
            CoreError::Internal(m) => Self { category: "internal", message: m.clone(), code: None },
        }
    }
}

impl From<reqwest::Error> for CoreError {
    fn from(e: reqwest::Error) -> Self { CoreError::Network(e.to_string()) }
}
impl From<serde_json::Error> for CoreError {
    fn from(e: serde_json::Error) -> Self { CoreError::Decode(e.to_string()) }
}
