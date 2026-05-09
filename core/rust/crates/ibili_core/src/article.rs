//! Article / opus support.
//!
//! Bilibili is migrating old `read/cv` articles to the newer dynamic
//! opus surface. We mirror PiliPlus here: try the opus endpoint when we
//! already have an opus id, and keep the legacy read endpoint as a
//! fallback for `cv` links and search results.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::signer::WbiKey;
use crate::{Core, CoreError, CoreResult};

const URL_NAV: &str = "https://api.bilibili.com/x/web-interface/nav";
const URL_ARTICLE_VIEW: &str = "https://api.bilibili.com/x/article/view";
const URL_ARTICLE_INFO: &str = "https://api.bilibili.com/x/article/viewinfo";
const URL_OPUS_DETAIL: &str = "https://api.bilibili.com/x/polymer/web-dynamic/v1/opus/detail";

#[derive(Debug, Serialize, Clone, Default)]
pub struct ArticleDetail {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub summary: String,
    pub cover: String,
    pub author: ArticleAuthor,
    pub stat: ArticleStat,
    pub pub_ts: i64,
    pub comment_id: i64,
    pub comment_type: i32,
    pub dyn_id: String,
    pub url: String,
    pub blocks: Vec<ArticleBlock>,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct ArticleAuthor {
    pub mid: i64,
    pub name: String,
    pub face: String,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct ArticleStat {
    pub view: i64,
    pub like: i64,
    pub reply: i64,
    pub favorite: i64,
    pub share: i64,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct ArticleImage {
    pub url: String,
    pub width: i64,
    pub height: i64,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct ArticleLinkCard {
    pub title: String,
    pub subtitle: String,
    pub cover: String,
    pub url: String,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct ArticleBlock {
    pub kind: String,
    pub text: String,
    pub rich_text: Vec<ArticleRichNode>,
    pub images: Vec<ArticleImage>,
    pub link_card: Option<ArticleLinkCard>,
    pub code_lang: String,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct ArticleRichNode {
    pub text: String,
    pub url: String,
    pub kind: String,
    pub rid: String,
    pub emoji_url: String,
    pub bold: bool,
    pub italic: bool,
    pub strikethrough: bool,
}

#[derive(Deserialize)]
struct NavData {
    wbi_img: NavWbiImage,
}

#[derive(Deserialize)]
struct NavWbiImage {
    img_url: String,
    sub_url: String,
}

#[derive(Default, Deserialize)]
struct OpusRoot {
    #[serde(default)] item: Option<OpusItemWire>,
    #[serde(default)] fallback: Option<OpusFallbackWire>,
}

#[derive(Default, Deserialize)]
struct OpusFallbackWire {
    #[serde(default, deserialize_with = "lenient_string")] id: Option<String>,
}

#[derive(Default, Deserialize)]
struct OpusItemWire {
    #[serde(default, deserialize_with = "lenient_string")] id_str: Option<String>,
    #[serde(default)] basic: Option<OpusBasicWire>,
    #[serde(default)] modules: Option<Vec<Value>>,
}

#[derive(Default, Deserialize)]
struct OpusBasicWire {
    #[serde(default, deserialize_with = "lenient_string")] comment_id_str: Option<String>,
    #[serde(default, deserialize_with = "lenient_i32")] comment_type: Option<i32>,
}

#[derive(Default, Deserialize)]
struct ArticleViewWire {
    #[serde(default, deserialize_with = "lenient_string")] title: Option<String>,
    #[serde(default)] author: Option<ArticleAuthorWire>,
    #[serde(default, deserialize_with = "lenient_i64")] publish_time: Option<i64>,
    #[serde(default, deserialize_with = "string_vec")] origin_image_urls: Vec<String>,
    #[serde(default, deserialize_with = "lenient_string")] dyn_id_str: Option<String>,
    #[serde(default)] opus: Option<ArticleViewOpusWire>,
}

#[derive(Default, Deserialize)]
struct ArticleViewOpusWire {
    #[serde(default)] content: Option<ArticleContentWire>,
}

#[derive(Default, Deserialize)]
struct ArticleContentWire {
    #[serde(default)] paragraphs: Vec<Value>,
}

#[derive(Default, Deserialize)]
struct ArticleInfoWire {
    #[serde(default, deserialize_with = "lenient_string")] title: Option<String>,
    #[serde(default, deserialize_with = "string_vec")] origin_image_urls: Vec<String>,
    #[serde(default)] stats: Option<ArticleInfoStatsWire>,
}

#[derive(Default, Deserialize)]
struct ArticleInfoStatsWire {
    #[serde(default, deserialize_with = "lenient_i64")] view: Option<i64>,
    #[serde(default, deserialize_with = "lenient_i64")] like: Option<i64>,
    #[serde(default, deserialize_with = "lenient_i64")] reply: Option<i64>,
    #[serde(default, deserialize_with = "lenient_i64")] favorite: Option<i64>,
    #[serde(default, deserialize_with = "lenient_i64")] share: Option<i64>,
}

#[derive(Default, Deserialize)]
struct ArticleAuthorWire {
    #[serde(default, deserialize_with = "lenient_i64")] mid: Option<i64>,
    #[serde(default, deserialize_with = "lenient_string")] name: Option<String>,
    #[serde(default, deserialize_with = "lenient_string")] face: Option<String>,
}

impl Core {
    pub fn article_opus_detail(&self, opus_id: &str) -> CoreResult<ArticleDetail> {
        if opus_id.trim().is_empty() {
            return Err(CoreError::InvalidArgument("opus id invalid".into()));
        }
        let key = self.fetch_wbi_key_for_article()?;
        let raw: OpusRoot = self.http.get_signed_web(
            URL_OPUS_DETAIL,
            vec![
                ("timezone_offset".into(), "-480".into()),
                ("features".into(), "htmlNewStyle".into()),
                ("id".into(), opus_id.to_string()),
            ],
            &key,
        )?;
        if let Some(fallback) = raw.fallback {
            if let Some(id) = fallback.id.filter(|s| !s.is_empty()) {
                return self.article_read_detail(id.parse().unwrap_or(0));
            }
        }
        let item = raw.item.ok_or_else(|| CoreError::Decode("missing opus item".into()))?;
        Ok(map_opus_item(item, opus_id))
    }

    pub fn article_read_detail(&self, cvid: i64) -> CoreResult<ArticleDetail> {
        if cvid <= 0 {
            return Err(CoreError::InvalidArgument("cv id invalid".into()));
        }
        let key = self.fetch_wbi_key_for_article()?;
        let raw: ArticleViewWire = self.http.get_signed_web(
            URL_ARTICLE_VIEW,
            vec![
                ("id".into(), cvid.to_string()),
                ("gaia_source".into(), "main_web".into()),
                ("web_location".into(), "333.976".into()),
            ],
            &key,
        )?;
        let info = self.article_info(cvid).ok();
        Ok(map_read_article(raw, info, cvid))
    }

    fn article_info(&self, cvid: i64) -> CoreResult<ArticleInfoWire> {
        if cvid <= 0 {
            return Err(CoreError::InvalidArgument("cv id invalid".into()));
        }
        let key = self.fetch_wbi_key_for_article()?;
        self.http.get_signed_web(
            URL_ARTICLE_INFO,
            vec![
                ("id".into(), cvid.to_string()),
                ("mobi_app".into(), "pc".into()),
                ("from".into(), "web".into()),
                ("gaia_source".into(), "main_web".into()),
            ],
            &key,
        )
    }

    fn fetch_wbi_key_for_article(&self) -> CoreResult<WbiKey> {
        let nav: NavData = self.http.get_web(URL_NAV, &[])?;
        Ok(WbiKey::from_urls(
            &nav.wbi_img.img_url,
            &nav.wbi_img.sub_url,
        ))
    }
}

fn map_opus_item(item: OpusItemWire, fallback_id: &str) -> ArticleDetail {
    let mut detail = ArticleDetail {
        id: item.id_str.clone().filter(|s| !s.is_empty()).unwrap_or_else(|| fallback_id.to_string()),
        kind: "opus".into(),
        url: format!(
            "https://www.bilibili.com/opus/{}",
            item.id_str.clone().unwrap_or_else(|| fallback_id.to_string())
        ),
        comment_type: 17,
        ..Default::default()
    };
    if let Some(basic) = item.basic {
        detail.comment_id = basic
            .comment_id_str
            .as_deref()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        detail.comment_type = basic.comment_type.unwrap_or(17);
    }
    if let Some(modules) = item.modules {
        for module in modules {
            let module_type = string_at(&module, &["module_type"]);
            match module_type.as_deref() {
                Some("MODULE_TYPE_TITLE") => {
                    if let Some(title) = string_at(&module, &["module_title", "text"]) {
                        detail.title = title;
                    }
                }
                Some("MODULE_TYPE_AUTHOR") => {
                    detail.author = ArticleAuthor {
                        mid: int_at(&module, &["module_author", "mid"]),
                        name: string_at(&module, &["module_author", "name"]).unwrap_or_default(),
                        face: ensure_https(string_at(&module, &["module_author", "face"]).unwrap_or_default()),
                    };
                    detail.pub_ts = int_at(&module, &["module_author", "pub_ts"]);
                }
                Some("MODULE_TYPE_CONTENT") => {
                    if let Some(paragraphs) = array_at(&module, &["module_content", "paragraphs"]) {
                        detail.blocks = paragraphs.iter().map(parse_article_block).collect();
                    }
                }
                Some("MODULE_TYPE_STAT") => {
                    detail.stat = ArticleStat {
                        view: int_at(&module, &["module_stat", "view", "count"]),
                        like: int_at(&module, &["module_stat", "like", "count"]),
                        reply: int_at(&module, &["module_stat", "comment", "count"]),
                        favorite: int_at(&module, &["module_stat", "favorite", "count"]),
                        share: int_at(&module, &["module_stat", "forward", "count"]),
                    };
                }
                _ => {}
            }
        }
    }
    finish_article_detail(detail)
}

fn map_read_article(raw: ArticleViewWire, info: Option<ArticleInfoWire>, cvid: i64) -> ArticleDetail {
    let mut detail = ArticleDetail {
        id: cvid.to_string(),
        kind: "read".into(),
        title: raw.title.unwrap_or_default(),
        author: raw.author.map(map_author).unwrap_or_default(),
        pub_ts: raw.publish_time.unwrap_or_default(),
        comment_id: cvid,
        comment_type: 12,
        dyn_id: raw.dyn_id_str.unwrap_or_default(),
        url: format!("https://www.bilibili.com/read/cv{cvid}"),
        ..Default::default()
    };
    if let Some(opus) = raw.opus.and_then(|o| o.content) {
        detail.blocks = opus.paragraphs.iter().map(parse_article_block).collect();
    }
    if let Some(info) = info {
        if detail.title.is_empty() {
            detail.title = info.title.unwrap_or_default();
        }
        detail.cover = info.origin_image_urls.first().cloned().unwrap_or_default();
        if let Some(stats) = info.stats {
            detail.stat = ArticleStat {
                view: stats.view.unwrap_or_default(),
                like: stats.like.unwrap_or_default(),
                reply: stats.reply.unwrap_or_default(),
                favorite: stats.favorite.unwrap_or_default(),
                share: stats.share.unwrap_or_default(),
            };
        }
    }
    if detail.cover.is_empty() {
        detail.cover = raw.origin_image_urls.first().cloned().unwrap_or_default();
    }
    finish_article_detail(detail)
}

fn finish_article_detail(mut detail: ArticleDetail) -> ArticleDetail {
    detail.cover = ensure_https(detail.cover);
    detail.author.face = ensure_https(detail.author.face);
    if detail.summary.is_empty() {
        detail.summary = detail
            .blocks
            .iter()
            .find(|b| !b.text.trim().is_empty())
            .map(|b| b.text.trim().chars().take(120).collect())
            .unwrap_or_default();
    }
    if detail.cover.is_empty() {
        detail.cover = detail
            .blocks
            .iter()
            .flat_map(|b| b.images.iter())
            .find(|img| !img.url.is_empty())
            .map(|img| img.url.clone())
            .unwrap_or_default();
    }
    detail
}

fn map_author(author: ArticleAuthorWire) -> ArticleAuthor {
    ArticleAuthor {
        mid: author.mid.unwrap_or_default(),
        name: author.name.unwrap_or_default(),
        face: ensure_https(author.face.unwrap_or_default()),
    }
}

fn parse_article_block(v: &Value) -> ArticleBlock {
    let para_type = int_at(v, &["para_type"]);
    let mut block = ArticleBlock::default();
    match para_type {
        1 => {
            block.kind = "text".into();
            block.rich_text = parse_nodes(array_at(v, &["text", "nodes"]));
            block.text = block.rich_text.iter().map(|n| n.text.as_str()).collect();
        }
        2 => {
            block.kind = "image".into();
            block.images = parse_images(v);
        }
        3 => {
            block.kind = "line".into();
        }
        4 => {
            block.kind = "quote".into();
            block.rich_text = parse_nodes(array_at(v, &["text", "nodes"]));
            block.text = block.rich_text.iter().map(|n| n.text.as_str()).collect();
        }
        _ => {
            if let Some(code) = object_at(v, &["code"]) {
                block.kind = "code".into();
                block.text = string_at(code, &["content"]).unwrap_or_default();
                block.code_lang = string_at(code, &["lang"]).unwrap_or_default();
            } else if let Some(heading) = array_at(v, &["heading", "nodes"]) {
                block.kind = "heading".into();
                block.rich_text = parse_nodes(Some(heading));
                block.text = block.rich_text.iter().map(|n| n.text.as_str()).collect();
            } else if object_at(v, &["link_card"]).is_some() {
                block.kind = "link_card".into();
                block.link_card = parse_link_card(v);
            } else if let Some(items) = array_at(v, &["list", "items"]) {
                block.kind = "text".into();
                let lines: Vec<String> = items
                    .iter()
                    .map(|item| parse_nodes(array_at(item, &["nodes"])).iter().map(|n| n.text.clone()).collect::<String>())
                    .collect();
                block.text = lines.join("\n");
            } else {
                block.kind = "text".into();
                block.text = string_at(v, &["text"]).unwrap_or_default();
            }
        }
    }
    if block.kind.is_empty() {
        block.kind = "text".into();
    }
    if block.link_card.is_none() {
        block.link_card = parse_link_card(v);
        if block.link_card.is_some() && block.text.is_empty() && block.images.is_empty() {
            block.kind = "link_card".into();
        }
    }
    block.images.iter_mut().for_each(|img| img.url = ensure_https(std::mem::take(&mut img.url)));
    if let Some(card) = block.link_card.as_mut() {
        card.cover = ensure_https(std::mem::take(&mut card.cover));
    }
    block
}

fn parse_nodes(nodes: Option<&Vec<Value>>) -> Vec<ArticleRichNode> {
    nodes
        .into_iter()
        .flatten()
        .map(parse_node)
        .filter(|n| !n.text.is_empty() || !n.emoji_url.is_empty())
        .collect()
}

fn parse_node(v: &Value) -> ArticleRichNode {
    if let Some(rich) = object_at(v, &["rich"]) {
        let kind = string_at(rich, &["type"]).unwrap_or_default();
        let emoji_url = string_at(rich, &["emoji", "url"]).unwrap_or_default();
        let text = if kind == "RICH_TEXT_NODE_TYPE_EMOJI" && !emoji_url.is_empty() {
            string_at(rich, &["text"]).or_else(|| string_at(rich, &["orig_text"])).unwrap_or_default()
        } else {
            string_at(rich, &["text"]).or_else(|| string_at(rich, &["orig_text"])).unwrap_or_default()
        };
        return ArticleRichNode {
            text,
            url: string_at(rich, &["jump_url"]).unwrap_or_default(),
            kind,
            rid: string_at(rich, &["rid"]).unwrap_or_default(),
            emoji_url: ensure_https(emoji_url),
            bold: bool_at(rich, &["style", "bold"]),
            italic: bool_at(rich, &["style", "italic"]),
            strikethrough: bool_at(rich, &["style", "strikethrough"]),
        };
    }
    if let Some(word) = object_at(v, &["word"]) {
        return ArticleRichNode {
            text: string_at(word, &["words"]).unwrap_or_default(),
            kind: "text".into(),
            bold: bool_at(word, &["style", "bold"]),
            italic: bool_at(word, &["style", "italic"]),
            strikethrough: bool_at(word, &["style", "strikethrough"]),
            ..Default::default()
        };
    }
    if let Some(formula) = string_at(v, &["formula", "latex_content"]) {
        return ArticleRichNode {
            text: formula,
            kind: "formula".into(),
            ..Default::default()
        };
    }
    ArticleRichNode::default()
}

fn parse_images(v: &Value) -> Vec<ArticleImage> {
    if let Some(pics) = array_at(v, &["pic", "pics"]) {
        return pics.iter().map(parse_image).collect();
    }
    if let Some(pic) = object_at(v, &["pic"]) {
        return vec![parse_image(pic)];
    }
    Vec::new()
}

fn parse_image(v: &Value) -> ArticleImage {
    ArticleImage {
        url: string_at(v, &["url"]).unwrap_or_default(),
        width: int_at(v, &["width"]),
        height: int_at(v, &["height"]),
    }
}

fn parse_link_card(v: &Value) -> Option<ArticleLinkCard> {
    let card = object_at(v, &["link_card", "card"])?;
    let candidates = ["ugc", "opus", "live", "common", "music"];
    for key in candidates {
        if let Some(value) = object_at(card, &[key]) {
            let title = string_at(value, &["title"])
                .or_else(|| string_at(value, &["name"]))
                .unwrap_or_default();
            if title.is_empty() {
                continue;
            }
            return Some(ArticleLinkCard {
                title,
                subtitle: string_at(value, &["desc_second"])
                    .or_else(|| string_at(value, &["desc"]))
                    .or_else(|| string_at(value, &["author", "name"]))
                    .unwrap_or_default(),
                cover: string_at(value, &["cover"]).unwrap_or_default(),
                url: string_at(value, &["jump_url"]).unwrap_or_default(),
            });
        }
    }
    None
}

fn object_at<'a>(v: &'a Value, path: &[&str]) -> Option<&'a Value> {
    let mut current = v;
    for key in path {
        current = current.get(*key)?;
    }
    current.as_object()?;
    Some(current)
}

fn array_at<'a>(v: &'a Value, path: &[&str]) -> Option<&'a Vec<Value>> {
    let mut current = v;
    for key in path {
        current = current.get(*key)?;
    }
    current.as_array()
}

fn string_at(v: &Value, path: &[&str]) -> Option<String> {
    let mut current = v;
    for key in path {
        current = current.get(*key)?;
    }
    match current {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

fn int_at(v: &Value, path: &[&str]) -> i64 {
    let mut current = v;
    for key in path {
        let Some(next) = current.get(*key) else { return 0 };
        current = next;
    }
    match current {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f.round() as i64)).unwrap_or(0),
        Value::String(s) => s.parse().unwrap_or(0),
        _ => 0,
    }
}

fn bool_at(v: &Value, path: &[&str]) -> bool {
    let mut current = v;
    for key in path {
        let Some(next) = current.get(*key) else { return false };
        current = next;
    }
    match current {
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_i64() == Some(1),
        Value::String(s) => s == "1" || s.eq_ignore_ascii_case("true"),
        _ => false,
    }
}

fn ensure_https(raw: String) -> String {
    if raw.starts_with("//") {
        format!("https:{}", raw)
    } else if let Some(rest) = raw.strip_prefix("http://") {
        format!("https://{}", rest)
    } else {
        raw
    }
}

fn lenient_string<'de, D>(de: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let v = Option::<Value>::deserialize(de)?;
    Ok(match v {
        Some(Value::String(s)) => Some(s),
        Some(Value::Number(n)) => Some(n.to_string()),
        Some(Value::Bool(b)) => Some(b.to_string()),
        _ => None,
    })
}

fn lenient_i64<'de, D>(de: D) -> Result<Option<i64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let v = Option::<Value>::deserialize(de)?;
    Ok(match v {
        Some(Value::Number(n)) => n.as_i64().or_else(|| n.as_f64().map(|f| f.round() as i64)),
        Some(Value::String(s)) => s.parse().ok(),
        Some(Value::Bool(b)) => Some(if b { 1 } else { 0 }),
        _ => None,
    })
}

fn lenient_i32<'de, D>(de: D) -> Result<Option<i32>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(lenient_i64(de)?.map(|v| v as i32))
}

fn string_vec<'de, D>(de: D) -> Result<Vec<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
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
        _ => Vec::new(),
    })
}
