//! Bilibili search APIs (video search by type).
//!
//! Mirrors PiliPlus `lib/http/search.dart::SearchHttp.searchByType` with
//! `searchType = video`. We use the WBI-signed web endpoint and ride
//! the existing `HttpClient::get_signed_web` machinery.

use crate::dto::{
    SearchArticleItem, SearchArticlePage, SearchLiveItem, SearchLivePage, SearchPgcItem,
    SearchPgcPage, SearchUserItem, SearchUserPage, SearchVideoItem, SearchVideoPage,
};
use crate::error::{CoreError, CoreResult};
use crate::signer::WbiKey;
use crate::Core;
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
    #[serde(default, alias = "numResults", deserialize_with = "null_as_default")]
    num_results: i64,
    #[serde(default, alias = "numPages", deserialize_with = "null_as_default")]
    num_pages: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    pages: i64,
    #[serde(default)]
    result: Option<Vec<SearchTypeItem>>,
    #[serde(default)]
    v_voucher: Option<String>,
}

#[derive(Deserialize)]
struct SearchTypeItem {
    #[serde(default, deserialize_with = "null_as_default")]
    aid: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    bvid: String,
    #[serde(default, deserialize_with = "null_as_default")]
    cid: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    title: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pic: String,
    #[serde(default, deserialize_with = "null_as_default")]
    author: String,
    #[serde(default, deserialize_with = "null_as_default")]
    duration: String,
    #[serde(default, deserialize_with = "null_as_default")]
    play: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    video_review: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    danmaku: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    like: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    pubdate: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    senddate: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    uid: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    uname: String,
    #[serde(default, deserialize_with = "null_as_default")]
    uface: String,
    #[serde(default, deserialize_with = "null_as_default")]
    cover: String,
    #[serde(default, deserialize_with = "null_as_default")]
    online: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    roomid: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    cate_name: String,
    #[serde(default, deserialize_with = "null_as_default")]
    mid: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    upic: String,
    #[serde(default, deserialize_with = "null_as_default")]
    usign: String,
    #[serde(default, deserialize_with = "null_as_default")]
    fans: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    videos: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    level: i32,
    #[serde(default, deserialize_with = "null_as_default")]
    is_live: i32,
    #[serde(default, deserialize_with = "null_as_default")]
    room_id: i64,
    #[serde(default)]
    official_verify: Option<SearchOfficialVerify>,
    #[serde(default, deserialize_with = "null_as_default")]
    verify_info: String,
    #[serde(default, deserialize_with = "null_as_default")]
    id: i64,
    #[serde(default, deserialize_with = "string_vec_or_empty")]
    image_urls: Vec<String>,
    #[serde(default, deserialize_with = "null_as_default")]
    desc: String,
    #[serde(default, deserialize_with = "null_as_default")]
    category_name: String,
    #[serde(default, deserialize_with = "null_as_default")]
    view: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    reply: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    pub_time: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    season_id: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    media_id: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    areas: String,
    #[serde(default, deserialize_with = "null_as_default")]
    styles: String,
    #[serde(default, deserialize_with = "null_as_default")]
    season_type: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    season_type_name: String,
    #[serde(default, deserialize_with = "null_as_default")]
    media_score: Option<SearchPgcScore>,
    #[serde(default, deserialize_with = "null_as_default")]
    index_show: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pubtime: i64,
}

#[derive(Deserialize, Default)]
struct SearchOfficialVerify {
    #[serde(default, deserialize_with = "null_as_default")]
    desc: String,
}

#[derive(Deserialize, Default)]
struct SearchPgcScore {
    #[serde(default, deserialize_with = "score_string_or_empty")]
    score: String,
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
        let keyword_encoded = keyword.replace(' ', "%20");
        let raw: SearchTypeRoot = self.http.get_signed_web_with_headers(
            URL_SEARCH_TYPE,
            params,
            &key,
            &[
                ("Origin", "https://search.bilibili.com".to_string()),
                (
                    "Referer",
                    format!(
                        "https://search.bilibili.com/video?keyword={}",
                        keyword_encoded
                    ),
                ),
            ],
        )?;
        if raw.v_voucher.is_some() {
            return Err(CoreError::Api {
                code: -352,
                msg: "触发搜索风控，请稍后再试".into(),
            });
        }
        let num_pages = resolve_num_pages(&raw);
        let items = raw
            .result
            .unwrap_or_default()
            .into_iter()
            .map(|r| SearchVideoItem {
                aid: r.aid,
                bvid: r.bvid,
                cid: r.cid,
                owner_mid: if r.mid > 0 { r.mid } else { r.uid },
                title: strip_em_tags(&r.title),
                cover: ensure_https(r.pic),
                author: r.author,
                duration_sec: parse_duration(&r.duration),
                play: r.play,
                danmaku: if r.danmaku > 0 {
                    r.danmaku
                } else {
                    r.video_review
                },
                like: r.like,
                pubdate: if r.pubdate > 0 { r.pubdate } else { r.senddate },
            })
            .filter(|item| item.aid > 0 && !item.bvid.is_empty())
            .collect();
        Ok(SearchVideoPage {
            items,
            num_results: raw.num_results,
            num_pages,
        })
    }

    pub fn search_live(&self, keyword: &str, page: i64) -> CoreResult<SearchLivePage> {
        let key = self.fetch_wbi_key_for_search()?;
        let params: Vec<(String, String)> = vec![
            ("search_type".into(), "live_room".into()),
            ("keyword".into(), keyword.to_string()),
            ("page".into(), page.max(1).to_string()),
            ("page_size".into(), "20".into()),
            ("platform".into(), "pc".into()),
            ("web_location".into(), "1430654".into()),
        ];
        let keyword_encoded = keyword.replace(' ', "%20");
        let raw: SearchTypeRoot = self.http.get_signed_web_with_headers(
            URL_SEARCH_TYPE,
            params,
            &key,
            &[
                ("Origin", "https://search.bilibili.com".to_string()),
                (
                    "Referer",
                    format!(
                        "https://search.bilibili.com/live?keyword={}",
                        keyword_encoded
                    ),
                ),
            ],
        )?;
        if raw.v_voucher.is_some() {
            return Err(CoreError::Api {
                code: -352,
                msg: "触发搜索风控，请稍后再试".into(),
            });
        }
        let num_pages = resolve_num_pages(&raw);
        let items = raw
            .result
            .unwrap_or_default()
            .into_iter()
            .map(|r| SearchLiveItem {
                room_id: r.roomid,
                uid: r.uid,
                title: strip_em_tags(&r.title),
                cover: ensure_https(if r.cover.is_empty() { r.pic } else { r.cover }),
                uname: r.uname,
                face: ensure_https(r.uface),
                online: r.online,
                area_name: strip_em_tags(&r.cate_name),
            })
            .filter(|item| item.room_id > 0)
            .collect();
        Ok(SearchLivePage {
            items,
            num_results: raw.num_results,
            num_pages,
        })
    }

    pub fn search_pgc(
        &self,
        keyword: &str,
        page: i64,
        search_type: &str,
    ) -> CoreResult<SearchPgcPage> {
        let search_type = match search_type {
            "media_ft" => "media_ft",
            _ => "media_bangumi",
        };
        let key = self.fetch_wbi_key_for_search()?;
        let params: Vec<(String, String)> = vec![
            ("search_type".into(), search_type.into()),
            ("keyword".into(), keyword.to_string()),
            ("page".into(), page.max(1).to_string()),
            ("page_size".into(), "20".into()),
            ("platform".into(), "pc".into()),
            ("web_location".into(), "1430654".into()),
        ];
        let keyword_encoded = keyword.replace(' ', "%20");
        let raw: SearchTypeRoot = self.http.get_signed_web_with_headers(
            URL_SEARCH_TYPE,
            params,
            &key,
            &[
                ("Origin", "https://search.bilibili.com".to_string()),
                (
                    "Referer",
                    format!(
                        "https://search.bilibili.com/{}?keyword={}",
                        search_type, keyword_encoded
                    ),
                ),
            ],
        )?;
        if raw.v_voucher.is_some() {
            return Err(CoreError::Api {
                code: -352,
                msg: "触发搜索风控，请稍后再试".into(),
            });
        }
        let num_pages = resolve_num_pages(&raw);
        let items = raw
            .result
            .unwrap_or_default()
            .into_iter()
            .map(|r| SearchPgcItem {
                season_id: r.season_id,
                media_id: r.media_id,
                title: strip_em_tags(&r.title),
                cover: ensure_https(if r.cover.is_empty() { r.pic } else { r.cover }),
                areas: strip_em_tags(&r.areas),
                styles: strip_em_tags(&r.styles),
                season_type: r.season_type,
                season_type_name: strip_em_tags(&r.season_type_name),
                score: r.media_score.map(|s| s.score).unwrap_or_default(),
                index_show: strip_em_tags(&r.index_show),
                desc: strip_em_tags(&r.desc),
                pubtime: r.pubtime,
            })
            .filter(|item| item.season_id > 0)
            .collect();
        Ok(SearchPgcPage {
            items,
            num_results: raw.num_results,
            num_pages,
        })
    }

    pub fn search_user(&self, keyword: &str, page: i64) -> CoreResult<SearchUserPage> {
        self.search_user_with_filters(keyword, page, None, None, None)
    }

    pub fn search_user_with_filters(
        &self,
        keyword: &str,
        page: i64,
        order: Option<&str>,
        order_sort: Option<i64>,
        user_type: Option<i64>,
    ) -> CoreResult<SearchUserPage> {
        let key = self.fetch_wbi_key_for_search()?;
        let mut params: Vec<(String, String)> = vec![
            ("search_type".into(), "bili_user".into()),
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
        if let Some(sort) = order_sort {
            params.push(("order_sort".into(), sort.to_string()));
        }
        if let Some(user_type) = user_type {
            if user_type > 0 {
                params.push(("user_type".into(), user_type.to_string()));
            }
        }
        let keyword_encoded = keyword.replace(' ', "%20");
        let raw: SearchTypeRoot = self.http.get_signed_web_with_headers(
            URL_SEARCH_TYPE,
            params,
            &key,
            &[
                ("Origin", "https://search.bilibili.com".to_string()),
                (
                    "Referer",
                    format!(
                        "https://search.bilibili.com/bili_user?keyword={}",
                        keyword_encoded
                    ),
                ),
            ],
        )?;
        if raw.v_voucher.is_some() {
            return Err(CoreError::Api {
                code: -352,
                msg: "触发搜索风控，请稍后再试".into(),
            });
        }
        let num_pages = resolve_num_pages(&raw);
        let items = raw
            .result
            .unwrap_or_default()
            .into_iter()
            .map(|r| {
                let official_desc = r
                    .official_verify
                    .as_ref()
                    .map(|v| strip_em_tags(&v.desc))
                    .filter(|v| !v.is_empty())
                    .unwrap_or_else(|| strip_em_tags(&r.verify_info));
                SearchUserItem {
                    mid: r.mid,
                    uname: strip_em_tags(&r.uname),
                    face: ensure_https(if r.upic.is_empty() { r.uface } else { r.upic }),
                    sign: strip_em_tags(&r.usign),
                    fans: r.fans,
                    videos: r.videos,
                    level: r.level,
                    is_live: r.is_live == 1,
                    room_id: r.room_id,
                    official_desc,
                }
            })
            .filter(|item| item.mid > 0)
            .collect();
        Ok(SearchUserPage {
            items,
            num_results: raw.num_results,
            num_pages,
        })
    }

    pub fn search_article(
        &self,
        keyword: &str,
        page: i64,
        order: Option<&str>,
        category_id: Option<i64>,
    ) -> CoreResult<SearchArticlePage> {
        let key = self.fetch_wbi_key_for_search()?;
        let mut params: Vec<(String, String)> = vec![
            ("search_type".into(), "article".into()),
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
        if let Some(category_id) = category_id {
            if category_id > 0 {
                params.push(("category_id".into(), category_id.to_string()));
            }
        }
        let keyword_encoded = keyword.replace(' ', "%20");
        let raw: SearchTypeRoot = self.http.get_signed_web_with_headers(
            URL_SEARCH_TYPE,
            params,
            &key,
            &[
                ("Origin", "https://search.bilibili.com".to_string()),
                (
                    "Referer",
                    format!(
                        "https://search.bilibili.com/article?keyword={}",
                        keyword_encoded
                    ),
                ),
            ],
        )?;
        if raw.v_voucher.is_some() {
            return Err(CoreError::Api {
                code: -352,
                msg: "触发搜索风控，请稍后再试".into(),
            });
        }
        let num_pages = resolve_num_pages(&raw);
        let items = raw
            .result
            .unwrap_or_default()
            .into_iter()
            .map(|r| SearchArticleItem {
                id: r.id,
                title: strip_em_tags(&r.title),
                desc: strip_em_tags(&r.desc),
                cover: ensure_https(r.image_urls.into_iter().next().unwrap_or_else(|| r.pic)),
                mid: r.mid,
                category_name: strip_em_tags(&r.category_name),
                view: r.view,
                like: r.like,
                reply: r.reply,
                pub_time: r.pub_time,
            })
            .filter(|item| item.id > 0)
            .collect();
        Ok(SearchArticlePage {
            items,
            num_results: raw.num_results,
            num_pages,
        })
    }

    fn fetch_wbi_key_for_search(&self) -> CoreResult<WbiKey> {
        let nav: NavData = self.http.get_web(URL_NAV, &[])?;
        Ok(WbiKey::from_urls(
            &nav.wbi_img.img_url,
            &nav.wbi_img.sub_url,
        ))
    }
}

fn resolve_num_pages(raw: &SearchTypeRoot) -> i64 {
    if raw.num_pages > 0 {
        raw.num_pages
    } else if raw.pages > 0 {
        raw.pages
    } else if raw.num_results > 0 {
        (raw.num_results + 19) / 20
    } else {
        0
    }
}

fn null_as_default<'de, D, T>(de: D) -> Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Default + serde::Deserialize<'de>,
{
    Ok(Option::<T>::deserialize(de)?.unwrap_or_default())
}

fn string_vec_or_empty<'de, D>(de: D) -> Result<Vec<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde_json::Value;
    let v = Option::<Value>::deserialize(de)?;
    Ok(match v {
        Some(Value::Array(items)) => items
            .into_iter()
            .filter_map(|item| match item {
                Value::String(s) => Some(s),
                Value::Number(n) => Some(n.to_string()),
                _ => None,
            })
            .collect(),
        Some(Value::String(s)) if !s.is_empty() => vec![s],
        _ => Vec::new(),
    })
}

fn score_string_or_empty<'de, D>(de: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde_json::Value;
    let v = Option::<Value>::deserialize(de)?;
    Ok(match v {
        Some(Value::String(s)) => s,
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    })
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
