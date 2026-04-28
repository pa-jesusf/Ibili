//! Danmaku fetcher.
//!
//! Bilibili's classic XML danmaku endpoint
//! `https://api.bilibili.com/x/v1/dm/list.so?oid=<cid>` returns a deflate-compressed
//! XML document of the form:
//!
//! ```xml
//! <i>
//!   <d p="time,mode,fontsize,color,sendts,pool,uid,rowid">text</d>
//!   ...
//! </i>
//! ```
//!
//! This module fetches the bytes, inflates if necessary, parses each `<d>`
//! tag, and returns a [`DanmakuTrack`]. Heavy DASH-style segmented danmaku
//! (`/x/v2/dm/web/seg.so`) requires protobuf and is intentionally not used here
//! to keep the dependency surface minimal.

use crate::Core;
use crate::dto::{DanmakuItem, DanmakuTrack};
use crate::error::{CoreError, CoreResult};
use std::io::Read;

const URL_DANMAKU_LIST: &str = "https://api.bilibili.com/x/v1/dm/list.so";

impl Core {
    pub fn danmaku_list(&self, cid: i64) -> CoreResult<DanmakuTrack> {
        let params = [("oid".to_string(), cid.to_string())];
        let bytes = self.http.get_bytes_web(URL_DANMAKU_LIST, &params)?;
        let xml = inflate_if_needed(&bytes)?;
        Ok(parse_xml(&xml))
    }
}

/// Bilibili wraps the XML in raw deflate. Some CDN replies are already plain
/// XML — we sniff for the `<` byte and only deflate when we can't see one.
fn inflate_if_needed(bytes: &[u8]) -> CoreResult<String> {
    let leading = bytes.iter().take(8).copied().find(|b| !b.is_ascii_whitespace());
    if leading == Some(b'<') {
        return Ok(String::from_utf8_lossy(bytes).into_owned());
    }
    let mut out = String::new();
    flate2::read::DeflateDecoder::new(bytes)
        .read_to_string(&mut out)
        .map_err(|e| CoreError::Decode(format!("danmaku inflate: {e}")))?;
    Ok(out)
}

fn parse_xml(xml: &str) -> DanmakuTrack {
    use quick_xml::events::Event;
    use quick_xml::reader::Reader;

    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut buf = Vec::new();
    let mut items = Vec::new();
    let mut current_p: Option<String> = None;

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) if e.name().as_ref() == b"d" => {
                current_p = e.attributes()
                    .filter_map(|a| a.ok())
                    .find(|a| a.key.as_ref() == b"p")
                    .and_then(|a| a.unescape_value().ok().map(|c| c.into_owned()));
            }
            Ok(Event::Text(t)) => {
                if let Some(p) = current_p.take() {
                    if let Some(item) = build_item(&p, &t.unescape().unwrap_or_default()) {
                        items.push(item);
                    }
                }
            }
            Ok(Event::End(e)) if e.name().as_ref() == b"d" => {
                current_p = None;
            }
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
        buf.clear();
    }
    DanmakuTrack { items }
}

fn build_item(p: &str, text: &str) -> Option<DanmakuItem> {
    let parts: Vec<&str> = p.split(',').collect();
    if parts.len() < 4 { return None; }
    Some(DanmakuItem {
        time_sec: parts[0].parse().unwrap_or(0.0),
        mode: parts[1].parse().unwrap_or(1),
        font_size: parts[2].parse().unwrap_or(25),
        color: parts[3].parse::<u32>().unwrap_or(0xFFFFFF),
        text: text.to_string(),
    })
}
