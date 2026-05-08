//! CDN host rewriting for upos DASH URLs.
//!
//! Rust port of `VideoUtils.getCdnUrl` from upstream PiliPlus
//! (lib/utils/video_utils.dart). Given the raw `[baseUrl] + backupUrl`
//! list returned by `wbi/playurl`, picks a preferred URL by rewriting the
//! upos mirror host to a chosen CDN, and returns a ranked list of
//! candidates for the iOS layer to race in parallel.

use once_cell::sync::Lazy;
use regex::Regex;
use url::Url;

/// Default upos mirror host. Mirrors upstream's `CDNService.ali` which is
/// listed first among real CDN options.
pub const DEFAULT_CDN_HOST: &str = "upos-sz-mirrorali.bilivideo.com";

const PROXY_TF: &str = "proxy-tf-all-ws.bilivideo.com";

/// Resolve the user-facing CDN selection used by the iOS settings screen.
/// Names mirror upstream PiliPlus's `CDNService` enum so future upstream
/// comparisons stay straightforward. `auto`, `baseUrl`, and `backupUrl` keep
/// the server-provided hosts; the iOS HLS proxy still races those candidates
/// at playback startup.
pub fn cdn_host_for_selection(selection: &str) -> Option<&'static str> {
    match selection {
        "ali" => Some("upos-sz-mirrorali.bilivideo.com"),
        "alib" => Some("upos-sz-mirroralib.bilivideo.com"),
        "alio1" => Some("upos-sz-mirroralio1.bilivideo.com"),
        "cos" => Some("upos-sz-mirrorcos.bilivideo.com"),
        "cosb" => Some("upos-sz-mirrorcosb.bilivideo.com"),
        "coso1" => Some("upos-sz-mirrorcoso1.bilivideo.com"),
        "hw" => Some("upos-sz-mirrorhw.bilivideo.com"),
        "hwb" => Some("upos-sz-mirrorhwb.bilivideo.com"),
        "hwo1" => Some("upos-sz-mirrorhwo1.bilivideo.com"),
        "hw_08c" => Some("upos-sz-mirror08c.bilivideo.com"),
        "hw_08h" => Some("upos-sz-mirror08h.bilivideo.com"),
        "hw_08ct" => Some("upos-sz-mirror08ct.bilivideo.com"),
        "tf_hw" => Some("upos-tf-all-hw.bilivideo.com"),
        "tf_tx" => Some("upos-tf-all-tx.bilivideo.com"),
        "akamai" => Some("upos-hz-mirrorakam.akamaized.net"),
        "aliov" => Some("upos-sz-mirroraliov.bilivideo.com"),
        "cosov" => Some("upos-sz-mirrorcosov.bilivideo.com"),
        "hwov" => Some("upos-sz-mirrorhwov.bilivideo.com"),
        "hk_bcache" => Some("cn-hk-eq-bcache-01.bilivideo.com"),
        _ => None,
    }
}

pub fn rank_urls_for_selection(
    urls: &[String],
    selection: &str,
) -> Vec<String> {
    let selection = if selection.trim().is_empty() {
        "auto"
    } else {
        selection.trim()
    };
    let host = match selection {
        "auto" | "baseUrl" | "backupUrl" => None,
        other => cdn_host_for_selection(other),
    };
    rank_urls(urls, host)
}

// Original Dart regex uses `(?!302)` lookahead which the `regex` crate does
// not support. We split detection into a host extractor + host predicate.
static UPGCXCODE_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^https?://([^/]+)/upgcxcode").expect("UPGCXCODE_RE compile")
});

static MCDN_TF_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r"^https?://(?:(?:\d{1,3}\.){3}\d{1,3}|[^/]+\.mcdn\.bilivideo\.(?:com|cn|net))(?::\d{1,5})?/v\d/resource",
    )
    .expect("MCDN_TF_RE compile")
});

/// Mirrors upstream's `_mirrorRegex` (no lookahead support in regex crate,
/// so we reconstruct the predicate manually).
fn host_is_mirror(host: &str) -> bool {
    // upos-tf-... or proxy-tf-... on bilivideo|akamaized {com,net}
    if (host.starts_with("upos-tf-") || host.starts_with("proxy-tf-"))
        && (host.ends_with(".bilivideo.com")
            || host.ends_with(".bilivideo.net")
            || host.ends_with(".akamaized.com")
            || host.ends_with(".akamaized.net"))
    {
        return true;
    }
    // upos-{region}-{tag}.bilivideo|akamaized.{com|net}, where {tag} != "302..."
    if !host.starts_with("upos-") {
        return false;
    }
    if !(host.ends_with(".bilivideo.com")
        || host.ends_with(".bilivideo.net")
        || host.ends_with(".akamaized.com")
        || host.ends_with(".akamaized.net"))
    {
        return false;
    }
    // Strip suffix down to the leading hostname segment, e.g.
    // "upos-sz-mirrorali" or "upos-hz-mirrorakam"
    let head = match host.split('.').next() {
        Some(h) => h,
        None => return false,
    };
    let mut parts = head.splitn(3, '-');
    let _ = parts.next(); // "upos"
    let region = parts.next();
    let tag = parts.next();
    match (region, tag) {
        (Some(r), Some(t)) if !r.is_empty() && !t.is_empty() => !t.starts_with("302"),
        _ => false,
    }
}

/// Rank a list of candidate URLs returned by Bilibili's playurl API.
///
/// The first element is the preferred URL (mirror host rewritten to
/// `default_host`). Remaining elements are kept as fallback candidates so
/// the iOS layer can race them in parallel.
///
/// * `default_host` — upos host to rewrite mirror URLs to. `None` keeps
///   the original host (equivalent to upstream's `CDNService.baseUrl`).
pub fn rank_urls(urls: &[String], default_host: Option<&str>) -> Vec<String> {
    if urls.is_empty() {
        return Vec::new();
    }

    let preferred = pick_preferred(urls, default_host);

    let mut out: Vec<String> = Vec::with_capacity(urls.len() + 1);
    if let Some(p) = preferred {
        out.push(p);
    }
    for u in urls {
        if !out.iter().any(|existing| existing == u) {
            out.push(u.clone());
        }
    }
    out
}

/// Mirror of upstream `VideoUtils.getCdnUrl`.
fn pick_preferred(
    urls: &[String],
    default_host: Option<&str>,
) -> Option<String> {
    if default_host.is_none() {
        return urls.first().cloned();
    }
    let host = default_host.unwrap();

    let mut mcdn_tf: Option<String> = None;
    let mut mcdn_upgcxcode: Option<String> = None;
    let mut last: Option<&String> = None;

    for url in urls {
        last = Some(url);

        let mirror_match = UPGCXCODE_RE
            .captures(url)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .filter(|h| host_is_mirror(h));

        if mirror_match.is_some() {
            let parsed = match Url::parse(url) {
                Ok(p) => p,
                Err(_) => continue,
            };
            // Inspect ?os=...
            let is_mcdn = parsed
                .query_pairs()
                .find(|(k, _)| k == "os")
                .map(|(_, v)| v == "mcdn")
                .unwrap_or(false);

            if is_mcdn {
                mcdn_upgcxcode = Some(url.clone());
                continue;
            }

            return Some(replace_host(&parsed, host));
        }

        if MCDN_TF_RE.is_match(url) {
            mcdn_tf = Some(url.clone());
            continue;
        }

        if url.contains("/upgcxcode/") {
            mcdn_upgcxcode = Some(url.clone());
            continue;
        }

        if url.contains("szbdyd.com") {
            if let Ok(parsed) = Url::parse(url) {
                let xy = parsed
                    .query_pairs()
                    .find(|(k, _)| k == "xy_usource")
                    .map(|(_, v)| v.into_owned())
                    .unwrap_or_else(|| host.to_string());
                let mut p = parsed.clone();
                let _ = p.set_scheme("https");
                let _ = p.set_host(Some(&xy));
                let _ = p.set_port(Some(443));
                return Some(p.to_string());
            }
        }
    }

    if let Some(m) = mcdn_upgcxcode {
        if let Ok(parsed) = Url::parse(&m) {
            return Some(replace_host(&parsed, host));
        }
        return Some(m);
    }
    if let Some(m) = mcdn_tf {
        let encoded = urlencoding_encode(&m);
        return Some(format!("https://{PROXY_TF}/?url={encoded}"));
    }
    last.cloned()
}

fn replace_host(parsed: &Url, host: &str) -> String {
    let mut p = parsed.clone();
    let _ = p.set_host(Some(host));
    p.to_string()
}

/// Minimal URL-encoder for query values (RFC 3986 unreserved set).
fn urlencoding_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for b in input.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rewrites_mirror_host_to_default() {
        let urls = vec![
            "https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/aa/bb/cc.mp4?os=hw".to_string(),
        ];
        let ranked = rank_urls(&urls, Some(DEFAULT_CDN_HOST));
        assert_eq!(
            ranked[0],
            "https://upos-sz-mirrorali.bilivideo.com/upgcxcode/aa/bb/cc.mp4?os=hw"
        );
        assert_eq!(ranked.len(), 2);
        assert_eq!(ranked[1], urls[0]);
    }

    #[test]
    fn keeps_mcdn_url_as_upgcxcode_fallback() {
        let urls = vec![
            "https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/aa/bb/cc.mp4?os=mcdn".to_string(),
            "https://1.2.3.4:8080/v1/resource/xx.mp4".to_string(),
        ];
        let ranked = rank_urls(&urls, Some(DEFAULT_CDN_HOST));
        // mcdn os=mcdn → treated as mcdn_upgcxcode → host rewritten
        assert!(ranked[0].starts_with("https://upos-sz-mirrorali.bilivideo.com/"));
    }

    fn empty_input_returns_empty() {
        assert!(rank_urls(&[], Some(DEFAULT_CDN_HOST)).is_empty());
    }

    #[test]
    fn falls_back_to_proxy_tf_for_mcdn_only() {
        let urls = vec!["https://1.2.3.4:8080/v1/resource/xx.mp4".to_string()];
        let ranked = rank_urls(&urls, Some(DEFAULT_CDN_HOST));
        assert!(ranked[0].starts_with("https://proxy-tf-all-ws.bilivideo.com/?url="));
    }
}
