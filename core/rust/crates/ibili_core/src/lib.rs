//! ibili_core: Bilibili protocol implementation.
//!
//! Public surface is intentionally narrow: a [`Core`] struct owns HTTP client,
//! session state, and exposes high-level service methods that return
//! plain DTOs serializable to JSON.

pub mod error;
pub mod dto;
pub mod signer;
pub mod http;
pub mod session;
pub mod auth;
pub mod feed;
pub mod video;
pub mod danmaku;
pub mod cdn;
pub mod search;
pub mod reply;
pub mod interaction;
pub mod user_space;
pub mod dynamic;

use std::sync::Arc;

use parking_lot::RwLock;

pub use error::{CoreError, CoreResult};

/// Top-level service handle. Cheap to clone.
#[derive(Clone)]
pub struct Core {
    pub(crate) http: Arc<http::HttpClient>,
    pub(crate) session: Arc<RwLock<session::Session>>,
}

impl Core {
    pub fn new(_config_json: &str) -> CoreResult<Self> {
        let http = http::HttpClient::new()?;
        Ok(Self {
            http: Arc::new(http),
            session: Arc::new(RwLock::new(session::Session::default())),
        })
    }

    pub fn session_snapshot(&self) -> session::SessionSnapshot {
        self.session.read().snapshot()
    }

    pub fn restore_session(&self, s: session::PersistedSession) {
        // Re-hydrate web cookies into the http jar so subsequent
        // wbi / nav / view requests authenticate as this user.
        self.http.install_web_cookies(&s.web_cookies);
        *self.session.write() = session::Session::from_persisted(s);
    }

    pub fn logout(&self) {
        *self.session.write() = session::Session::default();
        // Cookies remain in the in-memory jar until process restart; the iOS
        // layer drops persisted cookies via SessionStore.clear() on logout,
        // so on next launch the jar starts empty again.
    }
}
