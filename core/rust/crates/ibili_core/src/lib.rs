//! ibili_core: Bilibili protocol implementation.
//!
//! Public surface is intentionally narrow: a [`Core`] struct owns HTTP client,
//! session state, and exposes high-level service methods that return
//! plain DTOs serializable to JSON.

pub mod article;
pub mod auth;
pub mod cdn;
pub mod danmaku;
pub mod dto;
pub mod dynamic;
pub mod error;
pub mod feed;
mod grpc;
pub mod http;
pub mod interaction;
pub mod live;
pub mod message;
pub mod packaging;
pub mod reply;
pub mod search;
pub mod session;
pub mod signer;
pub mod user_space;
pub mod video;

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
        self.http.clear_web_cookies();
        self.http.install_web_cookies(&s.web_cookies);
        *self.session.write() = session::Session::from_persisted(s);
    }

    pub fn logout(&self) {
        *self.session.write() = session::Session::default();
        self.http.clear_web_cookies();
    }

    pub fn packaging_offline_build(
        &self,
        request: packaging::OfflinePackagingRequest,
    ) -> CoreResult<packaging::OfflinePackagingBuild> {
        packaging::offline_build(request)
    }
}
