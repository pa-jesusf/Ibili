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
//! This module fetches danmaku from Bilibili's segmented protobuf endpoint
//! when the caller can provide a duration. That surface carries the upstream
//! metadata needed for cloud-block weights and advanced danmaku. If segmented
//! fetch/decode fails, we fall back to the classic XML endpoint to preserve
//! baseline playback functionality.

use crate::Core;
use crate::dto::{DanmakuItem, DanmakuTrack};
use crate::error::{CoreError, CoreResult};
use prost::Message;
use std::io::Read;

const URL_DANMAKU_LIST: &str = "https://api.bilibili.com/x/v1/dm/list.so";
const URL_DANMAKU_SEG: &str = "https://api.bilibili.com/x/v2/dm/web/seg.so";
const SEGMENT_LENGTH_SEC: i64 = 6 * 60;

#[derive(Clone, PartialEq, Message)]
struct DmSegMobileReplyWire {
    #[prost(message, repeated, tag = "1")]
    elems: Vec<DanmakuElemWire>,
}

#[derive(Clone, PartialEq, Message)]
struct DanmakuElemWire {
    #[prost(int64, tag = "1")]
    id: i64,
    #[prost(int32, tag = "2")]
    progress: i32,
    #[prost(int32, tag = "3")]
    mode: i32,
    #[prost(int32, tag = "4")]
    fontsize: i32,
    #[prost(uint32, tag = "5")]
    color: u32,
    #[prost(string, tag = "6")]
    mid_hash: String,
    #[prost(string, tag = "7")]
    content: String,
    #[prost(int32, tag = "9")]
    weight: i32,
    #[prost(int64, tag = "15")]
    like_count: i64,
    #[prost(int32, tag = "24")]
    colorful: i32,
    #[prost(int32, tag = "100")]
    count: i32,
    #[prost(bool, tag = "101")]
    is_self: bool,
}

impl Core {
    pub fn danmaku_list(&self, cid: i64, duration_sec: i64) -> CoreResult<DanmakuTrack> {
        if duration_sec > 0 {
            match self.danmaku_segmented_list(cid, duration_sec) {
                Ok(track) => return Ok(track),
                Err(err) => {
                    eprintln!(
                        "[ibili_core] segmented danmaku failed for cid={cid}, duration_sec={duration_sec}; falling back to XML: {err}"
                    );
                }
            }
        }
        self.danmaku_xml_list(cid)
    }

    fn danmaku_segmented_list(&self, cid: i64, duration_sec: i64) -> CoreResult<DanmakuTrack> {
        let segment_count = segment_count_for_duration(duration_sec);
        let self_mid_hash = current_mid_hash(self);
        let mut items = Vec::new();

        for segment_index in 1..=segment_count {
            let params = [
                ("type".to_string(), "1".to_string()),
                ("oid".to_string(), cid.to_string()),
                ("segment_index".to_string(), segment_index.to_string()),
            ];
            let bytes = self.http.get_bytes_web(URL_DANMAKU_SEG, &params)?;
            let reply = DmSegMobileReplyWire::decode(bytes.as_slice())
                .map_err(|e| CoreError::Decode(format!("dm seg decode: {e}")))?;
            items.extend(reply.elems.into_iter().map(|elem| build_segment_item(elem, self_mid_hash.as_deref())));
        }

        items.sort_by(|lhs, rhs| lhs.time_sec.total_cmp(&rhs.time_sec));
        Ok(DanmakuTrack { items })
    }

    fn danmaku_xml_list(&self, cid: i64) -> CoreResult<DanmakuTrack> {
        let params = [("oid".to_string(), cid.to_string())];
        let bytes = self.http.get_bytes_web(URL_DANMAKU_LIST, &params)?;
        let xml = inflate_if_needed(&bytes)?;
        Ok(parse_xml(&xml))
    }
}

fn segment_count_for_duration(duration_sec: i64) -> i64 {
    let safe = duration_sec.max(1);
    (safe + SEGMENT_LENGTH_SEC - 1) / SEGMENT_LENGTH_SEC
}

fn current_mid_hash(core: &Core) -> Option<String> {
    let mid = core.session.read().snapshot().mid;
    (mid > 0).then(|| format!("{:x}", crc32fast::hash(mid.to_string().as_bytes())))
}

fn build_segment_item(raw: DanmakuElemWire, self_mid_hash: Option<&str>) -> DanmakuItem {
    let is_self = raw.is_self
        || self_mid_hash
            .map(|expected| !raw.mid_hash.is_empty() && raw.mid_hash == expected)
            .unwrap_or(false);

    DanmakuItem {
        time_sec: raw.progress as f32 / 1000.0,
        mode: raw.mode,
        font_size: raw.fontsize,
        color: raw.color,
        text: raw.content,
        weight: raw.weight,
        has_weight: true,
        mid_hash: raw.mid_hash,
        like_count: raw.like_count,
        colorful: raw.colorful,
        count: raw.count,
        is_self,
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
        weight: 0,
        has_weight: false,
        mid_hash: String::new(),
        like_count: 0,
        colorful: 0,
        count: 0,
        is_self: false,
    })
}
