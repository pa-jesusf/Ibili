//! Bilibili search APIs (video search by type).
//!
//! Mirrors PiliPlus `lib/http/search.dart::SearchHttp.searchByType` with
//! `searchType = video`. We use the WBI-signed web endpoint and ride
//! the existing `HttpClient::get_signed_web` machinery.

use crate::Core;
use crate::dto::{SearchVideoItem, SearchVideoPage};
use crate::error::CoreResult;
use crate::signer::WbiKey;
use serde::Deserialize;

const URL_SEARCH_TYPE: &str = "https://api.bilibili.com/x/web-interface/wbi/search/type";
const URL_NAV: &str = "https://api.bilibili.com/x/web-interface/nav";

#[derive(Deserialize)]
struct NavData {
    wbi_img: NavWbiImage,
}

#[derive(Deserialize)]
struct NavWbiImage {
    img_url: String,
    sub_url: String,
}

#[derive(Deserialize, Default)]
struct SearchTypeRoot {
    #[serde(default)]
    num_results: i64,
    #[serde(default)]
    num_pages: i64,
    #[serde(default)]
    result: Option<Vec<SearchTypeItem>>,
}

#[derive(Deserialize)]
struct SearchTypeItem {
    #[serde(default)] aid: i64,
    #[serde(default)] bvid: String,
    #[serde(default)] cid: i64,
    #[serde(default)] title: String,
    #[serde(default)] pic: String,
    #[serde(default)] author: String,
    #[serde(default)] duration: String,
    #[serde(default)] play: i64,
    #[serde(default)] video_review: i64,
    #[serde(default)] danmaku: i64,
    #[serde(default)] like: i64,
    #[serde(default)] pubdate: i64,
    #[serde(default)] senddate: i64,
}

impl Core {
    /// Run a video keyword search.
    ///
    /// `order` accepts upstream values like `"totalrank"` (综合) /
    /// `"click"` (最多播放) / `"pubdate"` (最新发布) / `"dm"` (最多弹幕).
    /// `duration` is `0..=4` matching upstream's "全部/10分钟以下/10-30分钟/30-60分钟/60分钟以上".
    /// `tids` is the zone id; `None` means all zones.
    pub fn search_video(
        &self,
        keyword: &str,
        page: i64,
        order: Option<&str>,
        duration: Option<i64>,
        tids: Option<i64>,
    ) -> CoreResult<SearchVideoPage> {
        let key = self.fetch_wbi_key_for_search()?;
        let mut params: Vec<(String, String)> = vec![
            ("search_type".into(), "video".into()),
            ("keyword".into(), keyword.to_string()),
            ("page".into(), page.max(1).to_string()),
            ("page_size".into(), "20".into()),
            ("platform".into(), "pc".into()),
            ("web_location".into(), "1430654".into()),
        ];
        if let Some(o) = order {
            if !o.is_empty() {
                params.push(("order".into(), o.to_string()));
            }
        }
        if let Some(d) = duration {
            params.push(("duration".into(), d.to_string()));
        }
        if let Some(t) = tids {
            params.push(("tids".into(), t.to_string()));
        }
        let raw: SearchTypeRoot = self
            .http
            .get_signed_web(URL_SEARCH_TYPE, params, &key)?;
        let items = raw
            .result
            .unwrap_or_default()
            .into_iter()
            .map(|r| SearchVideoItem {
                aid: r.aid,
                bvid: r.bvid,
                cid: r.cid,
                title: strip_em_tags(&r.title),
                cover: ensure_https(r.pic),
                author: r.author,
                duration_sec: parse_duration(&r.duration),
                play: r.play,
                danmaku: if r.danmaku > 0 { r.danmaku } else { r.video_review },
                like: r.like,
                pubdate: if r.pubdate > 0 { r.pubdate } else { r.senddate },
            })
            .collect();
        Ok(SearchVideoPage {
            items,
            num_results: raw.num_results,
            num_pages: raw.num_pages,
        })
    }

    fn fetch_wbi_key_for_search(&self) -> CoreResult<WbiKey> {
        let nav: NavData = self.http.get_web(URL_NAV, &[])?;
        Ok(WbiKey::from_urls(&nav.wbi_img.img_url, &nav.wbi_img.sub_url))
    }
}

/// Bilibili search returns titles wrapped in `<em class="keyword">…</em>`
/// markers around matches. Strip them so the iOS layer renders plain text.
fn strip_em_tags(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut in_tag = false;
    for ch in raw.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(ch),
            _ => {}
        }
    }
    out
}

/// Bilibili sometimes returns covers as `//i0.hdslb.com/...` (scheme-relative)
/// or with `http://`; force HTTPS so AVPlayer/RemoteImage doesn't trip ATS.
fn ensure_https(raw: String) -> String {
    if raw.starts_with("//") {
        format!("https:{}", raw)
    } else if let Some(rest) = raw.strip_prefix("http://") {
        format!("https://{}", rest)
    } else {
        raw
    }
}

/// Search results return duration as `"H:MM:SS"` or `"M:SS"`. Convert to
/// total seconds; on parse failure return 0.
fn parse_duration(raw: &str) -> i64 {
    let mut total: i64 = 0;
    for part in raw.split(':') {
        let n: i64 = part.parse().unwrap_or(0);
        total = total * 60 + n;
    }
    total
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_duration_handles_h_m_s_and_m_s() {
        assert_eq!(parse_duration("01:02:03"), 3723);
        assert_eq!(parse_duration("12:34"), 754);
        assert_eq!(parse_duration("0"), 0);
        assert_eq!(parse_duration("bogus"), 0);
    }

    #[test]
    fn strip_em_tags_removes_markers_only() {
        assert_eq!(
            strip_em_tags("hello <em class=\"keyword\">world</em>!"),
            "hello world!"
        );
        assert_eq!(strip_em_tags("plain"), "plain");
    }

    #[test]
    fn ensure_https_promotes_scheme() {
        assert_eq!(
            ensure_https("//i0.hdslb.com/x.jpg".into()),
            "https://i0.hdslb.com/x.jpg"
        );
        assert_eq!(
            ensure_https("http://i0.hdslb.com/x.jpg".into()),
            "https://i0.hdslb.com/x.jpg"
        );
        assert_eq!(
            ensure_https("https://i0.hdslb.com/x.jpg".into()),
            "https://i0.hdslb.com/x.jpg"
        );
    }
}
