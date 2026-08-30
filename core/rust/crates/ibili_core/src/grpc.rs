//! Minimal unary gRPC transport for Bilibili app services.

use crate::error::{CoreError, CoreResult};
use crate::http::UA_TV;
use crate::Core;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use flate2::read::GzDecoder;
use prost::Message;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use std::io::Read;

const APP_GRPC_BASE: &str = "https://app.bilibili.com";
const APP_BUILD: i32 = 2_001_100;
const APP_VERSION: &str = "2.0.1";
const MOBI_APP: &str = "android_hd";
const DEVICE: &str = "android";
const CHANNEL: &str = "master";

#[derive(Clone, PartialEq, Message)]
struct Metadata {
    #[prost(string, tag = "1")]
    access_key: String,
    #[prost(string, tag = "2")]
    mobi_app: String,
    #[prost(string, tag = "3")]
    device: String,
    #[prost(int32, tag = "4")]
    build: i32,
    #[prost(string, tag = "5")]
    channel: String,
    #[prost(string, tag = "6")]
    buvid: String,
    #[prost(string, tag = "7")]
    platform: String,
}

#[derive(Clone, PartialEq, Message)]
struct DeviceMetadata {
    #[prost(int32, tag = "1")]
    app_id: i32,
    #[prost(int32, tag = "2")]
    build: i32,
    #[prost(string, tag = "3")]
    buvid: String,
    #[prost(string, tag = "4")]
    mobi_app: String,
    #[prost(string, tag = "5")]
    platform: String,
    #[prost(string, tag = "6")]
    device: String,
    #[prost(string, tag = "7")]
    channel: String,
    #[prost(string, tag = "8")]
    brand: String,
    #[prost(string, tag = "9")]
    model: String,
    #[prost(string, tag = "10")]
    osver: String,
    #[prost(string, tag = "13")]
    version_name: String,
}

#[derive(Clone, PartialEq, Message)]
struct NetworkMetadata {
    #[prost(enumeration = "NetworkType", tag = "1")]
    kind: i32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, prost::Enumeration)]
#[repr(i32)]
enum NetworkType {
    Unknown = 0,
    Wifi = 1,
}

#[derive(Clone, PartialEq, Message)]
struct LocaleIDs {
    #[prost(string, tag = "1")]
    language: String,
    #[prost(string, tag = "2")]
    script: String,
    #[prost(string, tag = "3")]
    region: String,
}

#[derive(Clone, PartialEq, Message)]
struct LocaleMetadata {
    #[prost(message, optional, tag = "1")]
    c_locale: Option<LocaleIDs>,
    #[prost(message, optional, tag = "2")]
    s_locale: Option<LocaleIDs>,
    #[prost(string, tag = "4")]
    timezone: String,
}

#[derive(Clone, PartialEq, Message)]
struct FawkesMetadata {
    #[prost(string, tag = "1")]
    appkey: String,
    #[prost(string, tag = "2")]
    env: String,
    #[prost(string, tag = "3")]
    session_id: String,
}

impl Core {
    pub(crate) fn grpc_request<Req, Resp>(
        &self,
        path: &str,
        request: &Req,
        require_auth: bool,
    ) -> CoreResult<Resp>
    where
        Req: Message,
        Resp: Message + Default,
    {
        let access_key = self.session.read().access_key().unwrap_or_default();
        if require_auth && access_key.is_empty() {
            return Err(CoreError::AuthRequired);
        }
        let mid = self.session.read().snapshot().mid;
        let buvid = self.http.buvid3();
        let headers = grpc_headers(&access_key, mid, &buvid)?;
        let framed = frame_message(request);
        let url = format!("{APP_GRPC_BASE}{path}");
        let response = self
            .http
            .client
            .post(url)
            .headers(headers)
            .body(framed)
            .send()
            .map_err(|error| CoreError::Network(error.to_string()))?;

        let http_status = response.status();
        let grpc_status = response
            .headers()
            .get("grpc-status")
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<i64>().ok());
        let grpc_message = response
            .headers()
            .get("grpc-message")
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default()
            .to_string();
        let body = response
            .bytes()
            .map_err(|error| CoreError::Network(error.to_string()))?;

        if !http_status.is_success() {
            return Err(CoreError::Network(format!(
                "gRPC HTTP {}: {}",
                http_status.as_u16(),
                grpc_message
            )));
        }
        if let Some(status) = grpc_status.filter(|status| *status != 0) {
            return Err(CoreError::Api {
                code: status,
                msg: if grpc_message.is_empty() {
                    format!("gRPC status {status}")
                } else {
                    grpc_message
                },
            });
        }

        let protobuf = unframe_message(&body)?;
        Resp::decode(protobuf.as_slice()).map_err(|error| CoreError::Decode(error.to_string()))
    }
}

fn grpc_headers(access_key: &str, mid: i64, buvid: &str) -> CoreResult<HeaderMap> {
    let locale = LocaleIDs {
        language: "zh".into(),
        script: "Hans".into(),
        region: "CN".into(),
    };
    let metadata = Metadata {
        access_key: access_key.into(),
        mobi_app: MOBI_APP.into(),
        device: DEVICE.into(),
        build: APP_BUILD,
        channel: CHANNEL.into(),
        buvid: buvid.into(),
        platform: DEVICE.into(),
    };
    let device = DeviceMetadata {
        app_id: 5,
        build: APP_BUILD,
        buvid: buvid.into(),
        mobi_app: MOBI_APP.into(),
        platform: DEVICE.into(),
        device: DEVICE.into(),
        channel: CHANNEL.into(),
        brand: DEVICE.into(),
        model: DEVICE.into(),
        osver: "15".into(),
        version_name: APP_VERSION.into(),
    };
    let fawkes = FawkesMetadata {
        appkey: MOBI_APP.into(),
        env: "prod".into(),
        session_id: random_session_id(),
    };
    let locale = LocaleMetadata {
        c_locale: Some(locale.clone()),
        s_locale: Some(locale),
        timezone: "Asia/Shanghai".into(),
    };

    let mut headers = HeaderMap::new();
    insert_header(&mut headers, "content-type", "application/grpc")?;
    insert_header(&mut headers, "accept", "application/grpc")?;
    insert_header(&mut headers, "grpc-encoding", "gzip")?;
    insert_header(&mut headers, "grpc-accept-encoding", "gzip,identity")?;
    insert_header(&mut headers, "gzip-accept-encoding", "gzip,identity")?;
    insert_header(&mut headers, "user-agent", UA_TV)?;
    insert_header(&mut headers, "te", "trailers")?;
    insert_header(&mut headers, "x-bili-gaia-vtoken", "")?;
    insert_header(&mut headers, "x-bili-aurora-zone", "")?;
    insert_header(&mut headers, "x-bili-exps-bin", "")?;
    insert_header(&mut headers, "buvid", buvid)?;
    insert_header(&mut headers, "bili-http-engine", "cronet")?;
    insert_header(
        &mut headers,
        "x-bili-trace-id",
        "11111111111111111111111111111111:1111111111111111:0:0",
    )?;
    if mid > 0 {
        insert_header(&mut headers, "x-bili-mid", &mid.to_string())?;
    }
    if !access_key.is_empty() {
        insert_header(
            &mut headers,
            "authorization",
            &format!("identify_v1 {access_key}"),
        )?;
    }
    insert_binary_header(
        &mut headers,
        "x-bili-metadata-bin",
        &metadata.encode_to_vec(),
    )?;
    insert_binary_header(&mut headers, "x-bili-device-bin", &device.encode_to_vec())?;
    insert_binary_header(
        &mut headers,
        "x-bili-network-bin",
        &NetworkMetadata {
            kind: NetworkType::Wifi as i32,
        }
        .encode_to_vec(),
    )?;
    insert_binary_header(&mut headers, "x-bili-locale-bin", &locale.encode_to_vec())?;
    insert_binary_header(
        &mut headers,
        "x-bili-fawkes-req-bin",
        &fawkes.encode_to_vec(),
    )?;
    Ok(headers)
}

fn insert_binary_header(headers: &mut HeaderMap, name: &str, bytes: &[u8]) -> CoreResult<()> {
    insert_header(headers, name, &BASE64.encode(bytes))
}

fn insert_header(headers: &mut HeaderMap, name: &str, value: &str) -> CoreResult<()> {
    let name = HeaderName::from_bytes(name.as_bytes())
        .map_err(|error| CoreError::Internal(format!("gRPC header name: {error}")))?;
    let value = HeaderValue::from_str(value)
        .map_err(|error| CoreError::Internal(format!("gRPC header value: {error}")))?;
    headers.insert(name, value);
    Ok(())
}

fn frame_message(message: &impl Message) -> Vec<u8> {
    let protobuf = message.encode_to_vec();
    let mut framed = Vec::with_capacity(5 + protobuf.len());
    framed.push(0);
    framed.extend_from_slice(&(protobuf.len() as u32).to_be_bytes());
    framed.extend_from_slice(&protobuf);
    framed
}

fn unframe_message(body: &[u8]) -> CoreResult<Vec<u8>> {
    if body.len() < 5 {
        return Err(CoreError::Decode("gRPC response frame is truncated".into()));
    }
    let compressed = body[0] == 1;
    let length = u32::from_be_bytes([body[1], body[2], body[3], body[4]]) as usize;
    if body.len() < 5 + length {
        return Err(CoreError::Decode(format!(
            "gRPC response payload is truncated: expected {length}, got {}",
            body.len().saturating_sub(5)
        )));
    }
    let payload = &body[5..5 + length];
    if !compressed {
        return Ok(payload.to_vec());
    }
    let mut decoder = GzDecoder::new(payload);
    let mut decoded = Vec::new();
    decoder
        .read_to_end(&mut decoded)
        .map_err(|error| CoreError::Decode(format!("gRPC gzip: {error}")))?;
    Ok(decoded)
}

fn random_session_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or_default()
        ^ COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{seed:016x}")[..8].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, PartialEq, Message)]
    struct Fixture {
        #[prost(string, tag = "1")]
        value: String,
    }

    #[test]
    fn unary_frame_round_trips_uncompressed_protobuf() {
        let fixture = Fixture {
            value: "hello".into(),
        };
        let frame = frame_message(&fixture);
        let decoded = Fixture::decode(unframe_message(&frame).unwrap().as_slice()).unwrap();
        assert_eq!(decoded, fixture);
    }
}
