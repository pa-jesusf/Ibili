use crate::{signer::WbiKey, CoreError, CoreResult};
use parking_lot::Mutex;
use std::time::{Duration, Instant};

/// Only nav-key acquisition is serialized, not signed API requests.
#[derive(Default)]
pub(crate) struct WbiKeyCache(Mutex<Option<(Instant, WbiKey)>>);

impl WbiKeyCache {
    pub(crate) fn get(&self, load: impl FnOnce() -> CoreResult<WbiKey>) -> CoreResult<WbiKey> {
        self.get_at(Instant::now(), load)
    }

    fn get_at(
        &self,
        now: Instant,
        load: impl FnOnce() -> CoreResult<WbiKey>,
    ) -> CoreResult<WbiKey> {
        let mut cached = self.0.lock();
        if let Some((time, key)) = cached.as_ref() {
            if now.saturating_duration_since(*time) < Duration::from_secs(3600) {
                return Ok(key.clone());
            }
        }
        let key = load()?;
        if key.img_key.len() != 32 || key.sub_key.len() != 32 {
            return Err(CoreError::Decode("invalid WBI key".into()));
        }
        *cached = Some((now, key.clone()));
        Ok(key)
    }

    pub(crate) fn reject(&self, rejected: &WbiKey) {
        let mut cached = self.0.lock();
        if cached.as_ref().is_some_and(|(_, key)| {
            key.img_key == rejected.img_key && key.sub_key == rejected.sub_key
        }) {
            *cached = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn key() -> WbiKey {
        WbiKey {
            img_key: "a".repeat(32),
            sub_key: "b".repeat(32),
        }
    }
    #[test]
    fn cached_expired_rejected_and_failed_keys() {
        let cache = WbiKeyCache::default();
        let now = Instant::now();
        cache.get_at(now, || Ok(key())).unwrap();
        cache.get_at(now, || panic!("cache miss")).unwrap();
        assert!(cache
            .get_at(now + Duration::from_secs(3601), || Err(CoreError::NotFound))
            .is_err());
        cache.reject(&key());
        assert!(cache.get_at(now, || Err(CoreError::NotFound)).is_err());
        cache.get_at(now, || Ok(key())).unwrap();
    }
    #[test]
    fn concurrent_misses_share_one_fetch() {
        let cache = WbiKeyCache::default();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        std::thread::scope(|scope| {
            for _ in 0..8 {
                scope.spawn(|| {
                    cache
                        .get(|| {
                            calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                            Ok(key())
                        })
                        .unwrap();
                });
            }
        });
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[test]
    fn old_rejection_preserves_new_key_and_invalid_keys_are_not_cached() {
        let cache = WbiKeyCache::default();
        let now = Instant::now();
        let invalid = WbiKey {
            img_key: String::new(),
            sub_key: String::new(),
        };
        assert!(cache.get_at(now, || Ok(invalid)).is_err());
        cache.get_at(now, || Ok(key())).unwrap();
        let new = WbiKey {
            img_key: "c".repeat(32),
            sub_key: "d".repeat(32),
        };
        cache
            .get_at(now + Duration::from_secs(3600), || Ok(new.clone()))
            .unwrap();
        cache.reject(&key());
        assert_eq!(
            cache
                .get_at(now + Duration::from_secs(3601), || panic!(
                    "old rejection erased new key"
                ))
                .unwrap()
                .img_key,
            new.img_key
        );
    }
}
