//! Public community annotations. This client deliberately has no Bilibili cookie jar.
use crate::error::{CoreError, CoreResult};
use once_cell::sync::Lazy;
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{io::Read, time::Duration};

const SERVERS: [&str; 2] = ["https://www.bsbsb.top", "https://www.bsbsb.xyz"];
const CATEGORIES: [&str; 9] = [
    "sponsor",
    "selfpromo",
    "interaction",
    "intro",
    "outro",
    "preview",
    "padding",
    "filler",
    "music_offtopic",
];
static CLIENT: Lazy<Result<Client, reqwest::Error>> = Lazy::new(|| {
    Client::builder()
        .connect_timeout(Duration::from_secs(4))
        .timeout(Duration::from_secs(10))
        .user_agent("Ibili/SponsorBlock")
        .build()
});

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct SponsorSegment {
    pub id: String,
    pub cid: i64,
    pub category: String,
    pub start: f64,
    pub end: f64,
    pub video_duration: f64,
}

#[derive(Deserialize)]
pub struct SegmentRequest {
    pub bvid: String,
    pub cid: i64,
    #[serde(default)]
    pub force_refresh: bool,
    #[serde(default)]
    pub version: String,
}

pub fn query(request: SegmentRequest) -> CoreResult<Vec<SponsorSegment>> {
    if request.bvid.len() != 12
        || !request.bvid.starts_with("BV")
        || !request.bvid.bytes().all(|b| b.is_ascii_alphanumeric())
        || request.cid <= 0
    {
        return Err(CoreError::InvalidArgument(
            "SponsorBlock requires BVID and CID".into(),
        ));
    }
    let client = CLIENT
        .as_ref()
        .map_err(|e| CoreError::Network(e.to_string()))?;
    let categories = serde_json::to_string(&CATEGORIES)?;
    let mut last_error = CoreError::Network("SponsorBlock unavailable".into());
    for server in SERVERS {
        let mut builder = client
            .get(format!("{server}/api/skipSegments"))
            .query(&[
                ("videoID", request.bvid.as_str()),
                ("cid", &request.cid.to_string()),
                ("categories", &categories),
            ])
            .header("Origin", "Ibili");
        if !request.version.is_empty() {
            builder = builder.header("x-ext-version", &request.version);
        }
        if request.force_refresh {
            builder = builder.header("x-skip-cache", "1");
        }
        match builder.send() {
            Ok(response) if response.status().as_u16() == 404 => return Ok(vec![]),
            Ok(response) if response.status().is_success() => {
                let mut bytes = Vec::new();
                if let Err(error) = response.take(2_000_001).read_to_end(&mut bytes) {
                    last_error = CoreError::Network(error.to_string());
                    continue;
                }
                if bytes.len() > 2_000_000 {
                    return Err(CoreError::Decode("SponsorBlock response too large".into()));
                }
                match parse(&bytes, request.cid) {
                    Ok(segments) => return Ok(segments),
                    Err(error) => last_error = error,
                }
            }
            Ok(response) => {
                let status = response.status();
                last_error = CoreError::Network(format!("SponsorBlock HTTP {status}"));
                if !status.is_server_error() && status.as_u16() != 429 {
                    return Err(last_error);
                }
            }
            Err(error) => last_error = CoreError::Network(error.to_string()),
        }
    }
    Err(last_error)
}

fn parse(bytes: &[u8], cid: i64) -> CoreResult<Vec<SponsorSegment>> {
    let rows: Vec<Value> = serde_json::from_slice(bytes)?;
    let mut segments = Vec::new();
    for row in rows {
        let row_cid = row["cid"]
            .as_i64()
            .or_else(|| row["cid"].as_str()?.parse().ok());
        let category = row["category"].as_str().unwrap_or("");
        let id = row["UUID"].as_str().unwrap_or("");
        let Some(times) = row["segment"].as_array().filter(|a| a.len() == 2) else {
            continue;
        };
        let (Some(start), Some(end)) = (times[0].as_f64(), times[1].as_f64()) else {
            continue;
        };
        let duration = match row.get("videoDuration") {
            None | Some(Value::Null) => 0.0,
            Some(value) => match value.as_f64() {
                Some(duration) => duration,
                None => continue,
            },
        };
        if row_cid != Some(cid)
            || row["actionType"].as_str() != Some("skip")
            || !CATEGORIES.contains(&category)
            || id.is_empty()
            || !start.is_finite()
            || !end.is_finite()
            || start < 0.0
            || end <= start
            || !duration.is_finite()
            || duration < 0.0
            || (duration > 0.0 && end > duration)
        {
            continue;
        }
        segments.push(SponsorSegment {
            id: id.into(),
            cid,
            category: category.into(),
            start,
            end,
            video_duration: duration,
        });
    }
    segments.sort_by(|a, b| a.start.total_cmp(&b.start));
    segments.dedup_by(|a, b| a == b);
    Ok(segments)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_fractional_times_and_filters_other_parts_and_actions() {
        let data = br#"[
            {"cid":"42","category":"sponsor","actionType":"skip","segment":[18.913,32.876],"UUID":"not-a-foundation-uuid","videoDuration":100},
            {"cid":"43","category":"sponsor","actionType":"skip","segment":[1,2],"UUID":"other"},
            {"category":"sponsor","actionType":"skip","segment":[1,2],"UUID":"missing-cid"},
            {"cid":42,"category":"sponsor","actionType":"mute","segment":[1,2],"UUID":"mute"},
            {"cid":42,"category":"intro","actionType":"skip","segment":[3,4.5],"UUID":"numeric","videoDuration":0}
        ]"#;
        let result = parse(data, 42).unwrap();
        assert_eq!(result.len(), 2);
        assert_eq!((result[1].start, result[1].end), (18.913, 32.876));
    }
    #[test]
    fn rejects_invalid_ranges_without_discarding_valid_rows() {
        let data = br#"[
            {"cid":1,"category":"sponsor","actionType":"skip","segment":[-1,2],"UUID":"negative"},
            {"cid":1,"category":"sponsor","actionType":"skip","segment":[5,2],"UUID":"reverse"},
            {"cid":1,"category":"sponsor","actionType":"skip","segment":[1,12],"UUID":"overflow","videoDuration":10},
            {"cid":1,"category":"sponsor","actionType":"skip","segment":[1,2],"UUID":"good"}
        ]"#;
        assert_eq!(parse(data, 1).unwrap().len(), 1);
        assert!(parse(br#"[]"#, 1).unwrap().is_empty());
        assert!(parse(br#"{}"#, 1).is_err());
    }
}
