use crate::error::{CoreError, CoreResult};
use crate::http::UA_WEB;
use crate::Core;
use quick_xml::events::Event;
use quick_xml::reader::Reader;
use regex::Regex;
use reqwest::blocking::Client;
use scraper::{Html, Selector};
use serde::{Deserialize, Deserializer, Serialize};
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use url::Url;

const BANGUMI_API: &str = "https://api.bgm.tv";
const BANGUMI_WEB: &str = "https://bgm.tv";
const APP_UA: &str = "pa-jesusf/Ibili/0.1.0 (iOS) (https://github.com/pa-jesusf/Ibili)";
pub const DEFAULT_MEDIA_SOURCE_SUBSCRIPTIONS: [&str; 2] = [
    "https://sub.creamycake.org/v1/bt1.json",
    "https://sub.creamycake.org/v1/css1.json",
];
const MEDIA_FETCH_REQUEST_TIMEOUT_SECS: u64 = 4;
const MEDIA_FETCH_BATCH_SIZE: usize = 24;
const MEDIA_FETCH_STOP_AFTER_SUPPORTED: usize = 12;
const MEDIA_FETCH_MAX_SUBJECTS_PER_QUERY: usize = 3;
const MEDIA_FETCH_MAX_EPISODE_PAGES_PER_QUERY: usize = 5;

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeOAuthStart {
    pub authorize_url: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeOAuthToken {
    pub access_token: String,
    pub refresh_token: String,
    pub token_type: String,
    pub expires_in: i64,
    pub expires_at: i64,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeBangumiUser {
    pub id: i64,
    pub username: String,
    pub nickname: String,
    pub avatar: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeSubjectImage {
    pub large: String,
    pub common: String,
    pub medium: String,
    pub small: String,
    pub grid: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeSubject {
    pub id: i64,
    pub name: String,
    pub name_cn: String,
    pub summary: String,
    pub date: String,
    pub image: AnimeSubjectImage,
    pub rating_score: f64,
    pub rating_total: i64,
    pub rank: i64,
    pub collection_type: i64,
    pub collection_label: String,
    pub ep_status: i64,
    pub total_episodes: i64,
    pub tags: Vec<String>,
    pub aliases: Vec<String>,
    pub episodes: Vec<AnimeEpisode>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeEpisode {
    pub id: i64,
    pub subject_id: i64,
    pub sort: f64,
    pub ep: f64,
    pub name: String,
    pub name_cn: String,
    pub duration: String,
    pub airdate: String,
    pub desc: String,
    pub collection_type: i64,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeCollectionItem {
    pub subject: AnimeSubject,
    pub collection_type: i64,
    pub collection_label: String,
    pub updated_at: String,
    pub ep_status: i64,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeCollectionPage {
    pub total: i64,
    pub page: i64,
    pub page_size: i64,
    pub items: Vec<AnimeCollectionItem>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeSubjectSearchPage {
    pub total: i64,
    pub page: i64,
    pub page_size: i64,
    pub items: Vec<AnimeSubject>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeSource {
    pub id: String,
    pub factory_id: String,
    pub version: i64,
    pub name: String,
    pub description: String,
    pub icon_url: String,
    pub tier: String,
    pub enabled: bool,
    pub arguments: Value,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeSourceUpdate {
    pub sources: Vec<AnimeSource>,
    pub updated_at: i64,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeMediaCandidate {
    pub id: String,
    pub source_id: String,
    pub source_name: String,
    pub title: String,
    pub url: String,
    pub page_url: String,
    pub kind: String,
    pub quality_label: String,
    pub is_supported: bool,
    pub unsupported_reason: String,
    pub referer: String,
    pub user_agent: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeMediaFetchResult {
    pub candidates: Vec<AnimeMediaCandidate>,
    pub diagnostics: AnimeMediaFetchDiagnostics,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeMediaFetchDiagnostics {
    pub enabled_sources: i64,
    pub attempted_queries: i64,
    pub succeeded_queries: i64,
    pub failed_queries: i64,
    pub unsupported_candidates: i64,
    pub supported_candidates: i64,
    pub messages: Vec<String>,
    pub source_reports: Vec<AnimeMediaSourceReport>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeMediaSourceReport {
    pub source_id: String,
    pub source_name: String,
    pub factory_id: String,
    pub attempted_queries: i64,
    pub succeeded_queries: i64,
    pub failed_queries: i64,
    pub candidate_count: i64,
    pub supported_count: i64,
    pub status: String,
    pub message: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimePlayUrl {
    pub url: String,
    pub format: String,
    pub title: String,
    pub cover: String,
    pub referer: String,
    pub user_agent: String,
    pub duration_ms: i64,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct AnimeEpisodePlayResult {
    pub play: Option<AnimePlayUrl>,
    pub candidates: Vec<AnimeMediaCandidate>,
    pub diagnostics: AnimeMediaFetchDiagnostics,
}

#[derive(Deserialize)]
struct OAuthTokenRaw {
    access_token: String,
    #[serde(default)]
    refresh_token: String,
    #[serde(default)]
    token_type: String,
    #[serde(default)]
    expires_in: i64,
}

#[derive(Deserialize)]
struct BangumiUserRaw {
    #[serde(default)]
    id: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    username: String,
    #[serde(default, deserialize_with = "null_as_default")]
    nickname: String,
    #[serde(default)]
    avatar: BangumiAvatarRaw,
}

#[derive(Deserialize, Default)]
struct BangumiAvatarRaw {
    #[serde(default)]
    large: String,
    #[serde(default)]
    medium: String,
    #[serde(default)]
    small: String,
}

#[derive(Deserialize, Default)]
struct BangumiPaged<T> {
    #[serde(default)]
    total: i64,
    #[serde(default)]
    limit: i64,
    #[allow(dead_code)]
    #[serde(default)]
    offset: i64,
    #[serde(default)]
    data: Vec<T>,
}

#[derive(Deserialize, Default)]
struct BangumiCollectionRaw {
    subject: BangumiSubjectRaw,
    #[serde(default)]
    r#type: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    updated_at: String,
    #[serde(default)]
    ep_status: i64,
}

#[derive(Deserialize, Default)]
struct BangumiSubjectRaw {
    #[serde(default)]
    id: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    name: String,
    #[serde(default, deserialize_with = "null_as_default")]
    name_cn: String,
    #[serde(default, deserialize_with = "null_as_default")]
    summary: String,
    #[serde(default, deserialize_with = "null_as_default")]
    date: String,
    #[serde(default)]
    images: Option<BangumiImagesRaw>,
    #[serde(default)]
    rating: Option<BangumiRatingRaw>,
    #[serde(default)]
    rank: i64,
    #[serde(default)]
    eps: i64,
    #[serde(default)]
    total_episodes: i64,
    #[serde(default)]
    tags: Vec<BangumiTagRaw>,
    #[serde(default)]
    infobox: Vec<BangumiInfoBoxItemRaw>,
}

#[derive(Deserialize, Default)]
struct BangumiImagesRaw {
    #[serde(default, deserialize_with = "null_as_default")]
    large: String,
    #[serde(default, deserialize_with = "null_as_default")]
    common: String,
    #[serde(default, deserialize_with = "null_as_default")]
    medium: String,
    #[serde(default, deserialize_with = "null_as_default")]
    small: String,
    #[serde(default, deserialize_with = "null_as_default")]
    grid: String,
}

#[derive(Deserialize, Default)]
struct BangumiRatingRaw {
    #[serde(default)]
    score: f64,
    #[serde(default)]
    total: i64,
}

#[derive(Deserialize, Default)]
struct BangumiTagRaw {
    #[serde(default, deserialize_with = "null_as_default")]
    name: String,
}

#[derive(Deserialize, Default)]
struct BangumiInfoBoxItemRaw {
    #[serde(default, deserialize_with = "null_as_default")]
    key: String,
    #[serde(default)]
    value: Value,
}

#[derive(Deserialize, Default)]
struct BangumiEpisodeRaw {
    #[serde(default)]
    id: i64,
    #[serde(default)]
    sort: f64,
    #[serde(default)]
    ep: f64,
    #[serde(default, deserialize_with = "null_as_default")]
    name: String,
    #[serde(default, deserialize_with = "null_as_default")]
    name_cn: String,
    #[serde(default, deserialize_with = "null_as_default")]
    duration: String,
    #[serde(default, deserialize_with = "null_as_default")]
    airdate: String,
    #[serde(default, deserialize_with = "null_as_default")]
    desc: String,
    #[serde(default)]
    collection: Option<BangumiEpisodeCollectionRaw>,
}

#[derive(Deserialize, Default)]
struct BangumiEpisodeCollectionRaw {
    #[serde(default)]
    r#type: i64,
}

#[derive(Deserialize, Default)]
struct ExportedMediaSourceDataList {
    #[serde(default, alias = "mediaSources", alias = "media_sources")]
    media_sources: Vec<ExportedMediaSourceData>,
}

#[derive(Deserialize, Default)]
struct ExportedMediaSourceData {
    #[serde(default, alias = "factoryId", alias = "factory_id")]
    factory_id: String,
    #[serde(default)]
    version: i64,
    #[serde(default)]
    arguments: Value,
}

impl Core {
    pub fn anime_oauth_start(&self, client_id: &str, redirect_uri: &str) -> CoreResult<AnimeOAuthStart> {
        let client_id = client_id.trim();
        let redirect_uri = redirect_uri.trim();
        if client_id.is_empty() || redirect_uri.is_empty() {
            return Err(CoreError::InvalidArgument("missing Bangumi OAuth client id or redirect uri".into()));
        }
        let mut url = Url::parse(&format!("{BANGUMI_WEB}/oauth/authorize"))
            .map_err(|e| CoreError::Internal(e.to_string()))?;
        url.query_pairs_mut()
            .append_pair("client_id", client_id)
            .append_pair("response_type", "code")
            .append_pair("redirect_uri", redirect_uri);
        Ok(AnimeOAuthStart { authorize_url: url.to_string() })
    }

    pub fn anime_oauth_exchange(
        &self,
        client_id: &str,
        client_secret: &str,
        redirect_uri: &str,
        code: &str,
    ) -> CoreResult<AnimeOAuthToken> {
        let body = json!({
            "grant_type": "authorization_code",
            "client_id": client_id,
            "client_secret": client_secret,
            "redirect_uri": redirect_uri,
            "code": code,
        });
        self.oauth_token_request(body)
    }

    pub fn anime_oauth_refresh(
        &self,
        client_id: &str,
        client_secret: &str,
        refresh_token: &str,
    ) -> CoreResult<AnimeOAuthToken> {
        let body = json!({
            "grant_type": "refresh_token",
            "client_id": client_id,
            "client_secret": client_secret,
            "refresh_token": refresh_token,
        });
        self.oauth_token_request(body)
    }

    pub fn anime_me(&self, access_token: &str) -> CoreResult<AnimeBangumiUser> {
        let raw: BangumiUserRaw = self.bangumi_get("/v0/me", access_token, &[])?;
        Ok(AnimeBangumiUser {
            id: raw.id,
            username: raw.username,
            nickname: raw.nickname,
            avatar: first_non_empty(&[raw.avatar.large, raw.avatar.medium, raw.avatar.small]),
        })
    }

    pub fn anime_collection_list(
        &self,
        access_token: &str,
        username: &str,
        collection_type: i64,
        page: i64,
        page_size: i64,
    ) -> CoreResult<AnimeCollectionPage> {
        let username = username.trim();
        if username.is_empty() {
            return Err(CoreError::InvalidArgument("missing Bangumi username".into()));
        }
        let page = page.max(1);
        let page_size = page_size.clamp(1, 50);
        let offset = (page - 1) * page_size;
        let mut query = vec![
            ("subject_type".to_string(), "2".to_string()),
            ("limit".to_string(), page_size.to_string()),
            ("offset".to_string(), offset.to_string()),
        ];
        if collection_type > 0 {
            query.push(("type".to_string(), collection_type.to_string()));
        }
        let path = format!("/v0/users/{}/collections", url_path(username));
        let raw: BangumiPaged<BangumiCollectionRaw> = self.bangumi_get(&path, access_token, &query)?;
        Ok(AnimeCollectionPage {
            total: raw.total,
            page,
            page_size: raw.limit.max(page_size),
            items: raw.data.into_iter().map(|item| {
                let mut subject = convert_subject(item.subject, item.r#type, item.ep_status);
                subject.collection_type = item.r#type;
                subject.collection_label = subject_collection_label(item.r#type).to_string();
                AnimeCollectionItem {
                    subject,
                    collection_type: item.r#type,
                    collection_label: subject_collection_label(item.r#type).to_string(),
                    updated_at: item.updated_at,
                    ep_status: item.ep_status,
                }
            }).collect(),
        })
    }

    pub fn anime_collection_update(&self, access_token: &str, subject_id: i64, collection_type: i64) -> CoreResult<()> {
        if subject_id <= 0 || !(1..=5).contains(&collection_type) {
            return Err(CoreError::InvalidArgument("invalid Bangumi collection update".into()));
        }
        let path = format!("/v0/users/-/collections/{subject_id}");
        self.bangumi_no_content(
            reqwest::Method::POST,
            &path,
            access_token,
            Some(json!({ "type": collection_type })),
        )
    }

    pub fn anime_episode_update(
        &self,
        access_token: &str,
        subject_id: i64,
        episode_id: i64,
        collection_type: i64,
    ) -> CoreResult<()> {
        if episode_id <= 0 || !(0..=3).contains(&collection_type) {
            return Err(CoreError::InvalidArgument("invalid Bangumi episode update".into()));
        }
        if subject_id > 0 {
            let path = format!("/v0/users/-/collections/{subject_id}/episodes");
            let result = self.bangumi_no_content(
                reqwest::Method::PATCH,
                &path,
                access_token,
                Some(json!({ "episode_id": [episode_id], "type": collection_type })),
            );
            if result.is_ok() {
                return result;
            }
        }
        let path = format!("/v0/users/-/collections/-/episodes/{episode_id}");
        self.bangumi_no_content(
            reqwest::Method::PUT,
            &path,
            access_token,
            Some(json!({ "type": collection_type })),
        )
    }

    pub fn anime_subject_detail(&self, access_token: &str, subject_id: i64) -> CoreResult<AnimeSubject> {
        if subject_id <= 0 {
            return Err(CoreError::InvalidArgument("invalid Bangumi subject id".into()));
        }
        let subject_path = format!("/v0/subjects/{subject_id}");
        let episode_path = "/v0/episodes".to_string();
        let subject: BangumiSubjectRaw = self.bangumi_get(&subject_path, access_token, &[])?;
        let episodes: BangumiPaged<BangumiEpisodeRaw> = self.bangumi_get(
            &episode_path,
            access_token,
            &[
                ("subject_id".to_string(), subject_id.to_string()),
                ("type".to_string(), "0".to_string()),
                ("limit".to_string(), "1000".to_string()),
                ("offset".to_string(), "0".to_string()),
            ],
        )?;
        let mut converted = convert_subject(subject, 0, 0);
        converted.episodes = episodes.data.into_iter()
            .map(|episode| convert_episode(subject_id, episode))
            .collect();
        Ok(converted)
    }

    pub fn anime_subject_search(&self, keyword: &str, page: i64, page_size: i64) -> CoreResult<AnimeSubjectSearchPage> {
        let keyword = keyword.trim();
        if keyword.is_empty() {
            return Ok(AnimeSubjectSearchPage::default());
        }
        let page = page.max(1);
        let page_size = page_size.clamp(1, 30);
        let offset = (page - 1) * page_size;
        let url = format!("{BANGUMI_API}/v0/search/subjects?limit={page_size}&offset={offset}");
        let response = self.http.client
            .post(&url)
            .header("User-Agent", APP_UA)
            .header("Accept", "application/json")
            .json(&json!({
                "keyword": keyword,
                "sort": "match",
                "filter": { "type": [2] }
            }))
            .send()?;
        let status = response.status().as_u16();
        let text = response.text().map_err(|e| CoreError::Network(e.to_string()))?;
        if !(200..300).contains(&status) {
            return Err(CoreError::Api { code: status as i64, msg: bangumi_error_message(&text) });
        }
        let raw: BangumiPaged<BangumiSubjectRaw> = serde_json::from_str(&text)?;
        Ok(AnimeSubjectSearchPage {
            total: raw.total,
            page,
            page_size: raw.limit.max(page_size),
            items: raw.data.into_iter().map(|subject| convert_subject(subject, 0, 0)).collect(),
        })
    }

    pub fn anime_source_subscription_update(&self, url: &str) -> CoreResult<AnimeSourceUpdate> {
        let url = url.trim();
        if url.is_empty() {
            return Err(CoreError::InvalidArgument("missing media source subscription url".into()));
        }
        let text = self.http.client
            .get(url)
            .header("User-Agent", UA_WEB)
            .header("Accept", "application/json, text/plain, */*")
            .send()?
            .error_for_status()
            .map_err(|e| CoreError::Network(e.to_string()))?
            .text()
            .map_err(|e| CoreError::Network(e.to_string()))?;
        self.anime_source_import(&text)
    }

    pub fn anime_source_import(&self, json_text: &str) -> CoreResult<AnimeSourceUpdate> {
        parse_sources(json_text)
    }

    pub fn anime_media_fetch(
        &self,
        sources_json: &str,
        subject_names: Vec<String>,
        episode_sort: f64,
        episode_name: &str,
    ) -> CoreResult<AnimeMediaFetchResult> {
        let update = parse_sources(sources_json)?;
        let keywords = build_search_keywords(&subject_names);
        let mut candidates = Vec::new();
        let mut seen = HashSet::new();
        let enabled_sources = update.sources.iter().filter(|s| s.enabled).count() as i64;
        let mut diagnostics = AnimeMediaFetchDiagnostics {
            enabled_sources,
            ..Default::default()
        };
        let jobs = build_media_fetch_jobs(&update.sources, &keywords);
        let mut reports = reports_for_sources(&update.sources);
        if jobs.is_empty() {
            diagnostics.source_reports = reports.into_values().collect();
            return Ok(AnimeMediaFetchResult { candidates, diagnostics });
        }
        let client = self.http.client.clone();
        for batch in jobs.chunks(MEDIA_FETCH_BATCH_SIZE) {
            diagnostics.attempted_queries += batch.len() as i64;
            let handles = batch.iter().cloned().map(|job| {
                let client = client.clone();
                let episode_name = episode_name.to_string();
                thread::spawn(move || {
                    let result = fetch_media_job(&client, &job, episode_sort, &episode_name);
                    MediaFetchJobResult { job, result }
                })
            }).collect::<Vec<_>>();

            for handle in handles {
                match handle.join() {
                    Ok(job_result) => {
                        update_source_report_attempt(&mut reports, &job_result.job);
                        match job_result.result {
                            Ok(mut items) => {
                                diagnostics.succeeded_queries += 1;
                                update_source_report_success(&mut reports, &job_result.job, &items);
                                push_unique(&mut candidates, &mut seen, &mut items);
                            }
                            Err(error) => {
                                diagnostics.failed_queries += 1;
                                update_source_report_failure(&mut reports, &job_result.job, &error);
                                push_diagnostic_message(
                                    &mut diagnostics.messages,
                                    &job_result.job.source,
                                    &job_result.job.keyword,
                                    &error,
                                );
                            }
                        }
                    }
                    Err(_) => {
                        diagnostics.failed_queries += 1;
                        if diagnostics.messages.len() < 8 {
                            diagnostics.messages.push("规则源线程异常退出".into());
                        }
                    }
                }
            }

            let supported_count = candidates.iter().filter(|c| c.is_supported).count();
            if supported_count >= MEDIA_FETCH_STOP_AFTER_SUPPORTED {
                if diagnostics.messages.len() < 8 {
                    diagnostics.messages.push("已优先返回可播放资源，部分慢源仍可手动刷新再试".into());
                }
                break;
            }
        }
        diagnostics.supported_candidates = candidates.iter().filter(|c| c.is_supported).count() as i64;
        diagnostics.unsupported_candidates = candidates.len() as i64 - diagnostics.supported_candidates;
        diagnostics.source_reports = sorted_source_reports(reports);
        candidates.sort_by(|a, b| {
            b.is_supported.cmp(&a.is_supported)
                .then_with(|| score_quality(&b.quality_label).cmp(&score_quality(&a.quality_label)))
                .then_with(|| a.source_name.cmp(&b.source_name))
        });
        Ok(AnimeMediaFetchResult { candidates, diagnostics })
    }

    pub fn anime_media_resolve(
        &self,
        candidate: AnimeMediaCandidate,
        title: &str,
        cover: &str,
    ) -> CoreResult<AnimePlayUrl> {
        if !candidate.is_supported {
            return Err(CoreError::InvalidArgument(candidate.unsupported_reason));
        }
        let format = media_kind(&candidate.url);
        if format != "hls" && format != "mp4" {
            return Err(CoreError::InvalidArgument("暂不支持该资源格式".into()));
        }
        Ok(AnimePlayUrl {
            url: candidate.url,
            format,
            title: title.to_string(),
            cover: cover.to_string(),
            referer: if candidate.referer.is_empty() { candidate.page_url } else { candidate.referer },
            user_agent: if candidate.user_agent.is_empty() { UA_WEB.to_string() } else { candidate.user_agent },
            duration_ms: 0,
        })
    }

    pub fn anime_episode_play(
        &self,
        sources_json: &str,
        subject_names: Vec<String>,
        episode_sort: f64,
        episode_name: &str,
        title: &str,
        cover: &str,
    ) -> CoreResult<AnimeEpisodePlayResult> {
        let fetch = self.anime_media_fetch(sources_json, subject_names, episode_sort, episode_name)?;
        let play = fetch
            .candidates
            .iter()
            .find(|candidate| candidate.is_supported)
            .cloned()
            .map(|candidate| self.anime_media_resolve(candidate, title, cover))
            .transpose()?;
        Ok(AnimeEpisodePlayResult {
            play,
            candidates: fetch.candidates,
            diagnostics: fetch.diagnostics,
        })
    }

    fn oauth_token_request(&self, body: Value) -> CoreResult<AnimeOAuthToken> {
        let form = body.as_object()
            .map(|object| object.iter()
                .filter_map(|(key, value)| value.as_str().map(|s| (key.as_str(), s)))
                .collect::<Vec<_>>())
            .unwrap_or_default();
        let response = self.http.client
            .post(format!("{BANGUMI_WEB}/oauth/access_token"))
            .header("User-Agent", APP_UA)
            .header("Accept", "application/json")
            .form(&form)
            .send()?;
        let status = response.status().as_u16();
        let text = response.text().map_err(|e| CoreError::Network(e.to_string()))?;
        if !(200..300).contains(&status) {
            return Err(CoreError::Api { code: status as i64, msg: bangumi_error_message(&text) });
        }
        let raw: OAuthTokenRaw = serde_json::from_str(&text)?;
        let now = now_secs();
        Ok(AnimeOAuthToken {
            access_token: raw.access_token,
            refresh_token: raw.refresh_token,
            token_type: if raw.token_type.is_empty() { "Bearer".into() } else { raw.token_type },
            expires_in: raw.expires_in,
            expires_at: now + raw.expires_in.max(0),
        })
    }

    fn bangumi_get<T: for<'de> Deserialize<'de>>(
        &self,
        path: &str,
        access_token: &str,
        query: &[(String, String)],
    ) -> CoreResult<T> {
        let mut url = Url::parse(&format!("{BANGUMI_API}{path}"))
            .map_err(|e| CoreError::Internal(e.to_string()))?;
        {
            let mut pairs = url.query_pairs_mut();
            for (key, value) in query {
                pairs.append_pair(key, value);
            }
        }
        let mut request = self.http.client
            .get(url)
            .header("User-Agent", APP_UA)
            .header("Accept", "application/json");
        if !access_token.trim().is_empty() {
            request = request.bearer_auth(access_token.trim());
        }
        let response = request.send()?;
        decode_bangumi_response(response)
    }

    fn bangumi_no_content(
        &self,
        method: reqwest::Method,
        path: &str,
        access_token: &str,
        body: Option<Value>,
    ) -> CoreResult<()> {
        if access_token.trim().is_empty() {
            return Err(CoreError::AuthRequired);
        }
        let url = format!("{BANGUMI_API}{path}");
        let mut request = self.http.client
            .request(method, url)
            .header("User-Agent", APP_UA)
            .header("Accept", "application/json")
            .bearer_auth(access_token.trim());
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send()?;
        let status = response.status().as_u16();
        if (200..300).contains(&status) {
            return Ok(());
        }
        let text = response.text().unwrap_or_default();
        Err(CoreError::Api { code: status as i64, msg: bangumi_error_message(&text) })
    }

}

fn decode_bangumi_response<T: for<'de> Deserialize<'de>>(response: reqwest::blocking::Response) -> CoreResult<T> {
    let status = response.status().as_u16();
    let text = response.text().map_err(|e| CoreError::Network(e.to_string()))?;
    if !(200..300).contains(&status) {
        return Err(CoreError::Api { code: status as i64, msg: bangumi_error_message(&text) });
    }
    serde_json::from_str(&text).map_err(CoreError::from)
}

#[derive(Clone)]
struct MediaFetchJob {
    source: AnimeSource,
    keyword: String,
}

struct MediaFetchJobResult {
    job: MediaFetchJob,
    result: CoreResult<Vec<AnimeMediaCandidate>>,
}

#[derive(Clone)]
struct SelectorSubjectHit {
    title: String,
    url: String,
}

#[derive(Clone)]
struct SelectorEpisodeHit {
    title: String,
    url: String,
    channel: String,
}

fn build_media_fetch_jobs(sources: &[AnimeSource], keywords: &[String]) -> Vec<MediaFetchJob> {
    let mut jobs = Vec::new();
    for source in sources.iter().filter(|source| source.enabled) {
        if !matches!(source.factory_id.as_str(), "rss" | "web-selector") || !source_supports_avkit(source) {
            continue;
        }
        for keyword in keywords {
            jobs.push(MediaFetchJob {
                source: source.clone(),
                keyword: selector_search_keyword(source, keyword),
            });
        }
    }
    jobs
}

fn fetch_media_job(
    client: &Client,
    job: &MediaFetchJob,
    episode_sort: f64,
    episode_name: &str,
) -> CoreResult<Vec<AnimeMediaCandidate>> {
    match job.source.factory_id.as_str() {
        "rss" => fetch_rss_candidates_with_client(client, &job.source, &job.keyword, episode_sort, episode_name),
        "web-selector" => fetch_selector_candidates_with_client(client, &job.source, &job.keyword, episode_sort, episode_name),
        _ => Ok(Vec::new()),
    }
}

fn fetch_rss_candidates_with_client(
    client: &Client,
    source: &AnimeSource,
    keyword: &str,
    episode_sort: f64,
    episode_name: &str,
) -> CoreResult<Vec<AnimeMediaCandidate>> {
    let Some(search_url) = source.arguments.pointer("/searchConfig/searchUrl").and_then(Value::as_str) else {
        return Ok(Vec::new());
    };
    let url = fill_search_url(search_url, keyword, 1);
    if url.is_empty() {
        return Ok(Vec::new());
    }
    let text = http_get_text(
        client,
        &url,
        UA_WEB,
        "application/rss+xml, application/xml, text/xml, */*",
    )?;
    let filter_by_episode = source.arguments
        .pointer("/searchConfig/filterByEpisodeSort")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    Ok(parse_rss_candidates(source, &text, &url, episode_sort, episode_name, filter_by_episode))
}

fn fetch_selector_candidates_with_client(
    client: &Client,
    source: &AnimeSource,
    keyword: &str,
    episode_sort: f64,
    episode_name: &str,
) -> CoreResult<Vec<AnimeMediaCandidate>> {
    let Some(search_url) = source.arguments.pointer("/searchConfig/searchUrl").and_then(Value::as_str) else {
        return Ok(Vec::new());
    };
    let url = fill_search_url(search_url, keyword, 1);
    if url.is_empty() {
        return Ok(Vec::new());
    }
    let ua = selector_user_agent(source);
    let text = http_get_text(
        client,
        &url,
        ua,
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    )?;
    let filter_by_episode = source.arguments
        .pointer("/searchConfig/filterByEpisodeSort")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let mut candidates = parse_selector_candidates(source, &text, &url, episode_sort, episode_name, filter_by_episode);
    let subjects = parse_selector_subjects(source, &text, &url, keyword);
    for subject in subjects.into_iter().take(MEDIA_FETCH_MAX_SUBJECTS_PER_QUERY) {
        let subject_html = match http_get_text(
            client,
            &subject.url,
            ua,
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ) {
            Ok(html) => html,
            Err(_) => continue,
        };
        let episodes = parse_selector_episode_hits(
            source,
            &subject_html,
            &subject.url,
            episode_sort,
            episode_name,
            filter_by_episode,
        );
        let mut subject_has_playable = false;
        for episode in episodes.into_iter().take(MEDIA_FETCH_MAX_EPISODE_PAGES_PER_QUERY) {
            let candidate_title = selector_candidate_title(&subject.title, &episode);
            if is_supported_media_url(&episode.url) {
                subject_has_playable = true;
                candidates.push(make_candidate(
                    source,
                    candidate_title,
                    episode.url,
                    subject.url.clone(),
                    selector_referer(source, &subject.url),
                ));
                continue;
            }
            let episode_html = match http_get_text(
                client,
                &episode.url,
                ua,
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ) {
                Ok(html) => html,
                Err(_) => continue,
            };
            let mut urls = extract_selector_media_urls(&episode_html, &episode.url);
            if urls.is_empty() {
                urls = fetch_nested_selector_media_urls(client, source, &episode_html, &episode.url, ua);
            }
            for media_url in urls {
                subject_has_playable = true;
                candidates.push(make_candidate(
                    source,
                    candidate_title.clone(),
                    media_url,
                    episode.url.clone(),
                    selector_referer(source, &episode.url),
                ));
            }
            if subject_has_playable {
                break;
            }
        }
        if subject_has_playable {
            break;
        }
    }
    dedupe_candidates(candidates)
}

fn http_get_text(client: &Client, url: &str, user_agent: &str, accept: &str) -> CoreResult<String> {
    client
        .get(url)
        .timeout(Duration::from_secs(MEDIA_FETCH_REQUEST_TIMEOUT_SECS))
        .header("User-Agent", user_agent)
        .header("Accept", accept)
        .send()?
        .error_for_status()
        .map_err(|e| CoreError::Network(e.to_string()))?
        .text()
        .map_err(|e| CoreError::Network(e.to_string()))
}

fn parse_selector_subjects(
    source: &AnimeSource,
    html: &str,
    page_url: &str,
    keyword: &str,
) -> Vec<SelectorSubjectHit> {
    let document = Html::parse_document(html);
    let format_id = source.arguments
        .pointer("/searchConfig/subjectFormatId")
        .and_then(Value::as_str)
        .unwrap_or("a");
    let mut items = match format_id {
        "indexed" => parse_indexed_subject_hits(source, &document, page_url),
        "json-path-indexed" => parse_json_path_subject_hits(source, html, page_url),
        _ => parse_anchor_subject_hits(source, &document, page_url),
    };
    let normalized_keyword = simplify_keyword(keyword).to_lowercase();
    items.sort_by(|a, b| {
        let a_score = subject_title_score(&a.title, &normalized_keyword);
        let b_score = subject_title_score(&b.title, &normalized_keyword);
        b_score.cmp(&a_score)
            .then_with(|| a.title.len().cmp(&b.title.len()))
    });
    dedupe_subject_hits(items)
}

fn parse_anchor_subject_hits(source: &AnimeSource, document: &Html, page_url: &str) -> Vec<SelectorSubjectHit> {
    let selector_text = source.arguments
        .pointer("/searchConfig/selectorSubjectFormatA/selectLists")
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
        .unwrap_or("a");
    let Ok(selector) = Selector::parse(selector_text) else {
        return Vec::new();
    };
    document
        .select(&selector)
        .filter_map(|element| {
            let href = element.value().attr("href")?;
            let url = resolve_url(page_url, href)?;
            let title = element_text_or_title(&element);
            if title.is_empty() {
                None
            } else {
                Some(SelectorSubjectHit { title, url })
            }
        })
        .collect()
}

fn parse_json_path_subject_hits(source: &AnimeSource, html: &str, page_url: &str) -> Vec<SelectorSubjectHit> {
    let Ok(value) = serde_json::from_str::<Value>(html) else {
        return Vec::new();
    };
    let names_path = source.arguments
        .pointer("/searchConfig/selectorSubjectFormatJsonPathIndexed/selectNames")
        .and_then(Value::as_str)
        .unwrap_or("$[*]['title','name']");
    let links_path = source.arguments
        .pointer("/searchConfig/selectorSubjectFormatJsonPathIndexed/selectLinks")
        .and_then(Value::as_str)
        .unwrap_or("$[*]['url','link']");
    let names = json_path_strings(&value, names_path);
    let links = json_path_strings(&value, links_path);
    names
        .into_iter()
        .zip(links)
        .filter_map(|(title, href)| {
            let title = title.trim().to_string();
            if title.is_empty() {
                return None;
            }
            let url = resolve_url(page_url, &href)?;
            Some(SelectorSubjectHit { title, url })
        })
        .collect()
}

fn parse_indexed_subject_hits(source: &AnimeSource, document: &Html, page_url: &str) -> Vec<SelectorSubjectHit> {
    let Some(names_selector_text) = source.arguments
        .pointer("/searchConfig/selectorSubjectFormatIndexed/selectNames")
        .and_then(Value::as_str) else {
        return Vec::new();
    };
    let Some(links_selector_text) = source.arguments
        .pointer("/searchConfig/selectorSubjectFormatIndexed/selectLinks")
        .and_then(Value::as_str) else {
        return Vec::new();
    };
    let (Ok(names_selector), Ok(links_selector)) = (
        Selector::parse(names_selector_text),
        Selector::parse(links_selector_text),
    ) else {
        return Vec::new();
    };
    let names = document
        .select(&names_selector)
        .map(|element| element_text_or_title(&element))
        .collect::<Vec<_>>();
    let links = document
        .select(&links_selector)
        .filter_map(|element| element.value().attr("href").and_then(|href| resolve_url(page_url, href)))
        .collect::<Vec<_>>();
    names
        .into_iter()
        .zip(links)
        .filter_map(|(title, url)| if title.is_empty() { None } else { Some(SelectorSubjectHit { title, url }) })
        .collect()
}

fn parse_selector_episode_hits(
    source: &AnimeSource,
    html: &str,
    subject_url: &str,
    episode_sort: f64,
    episode_name: &str,
    filter_by_episode: bool,
) -> Vec<SelectorEpisodeHit> {
    let document = Html::parse_document(html);
    let channel_format = source.arguments
        .pointer("/searchConfig/channelFormatId")
        .and_then(Value::as_str)
        .unwrap_or("index-grouped");
    let base_url = selector_base_url(subject_url);
    match channel_format {
        "no-channel" => {
            let episodes_selector = source.arguments
                .pointer("/searchConfig/selectorChannelFormatNoChannel/selectEpisodes")
                .and_then(Value::as_str)
                .unwrap_or("a");
            let links_selector = source.arguments
                .pointer("/searchConfig/selectorChannelFormatNoChannel/selectEpisodeLinks")
                .and_then(Value::as_str)
                .unwrap_or("");
            let match_regex = source.arguments
                .pointer("/searchConfig/selectorChannelFormatNoChannel/matchEpisodeSortFromName")
                .and_then(Value::as_str);
            parse_episode_hits_from_parent(
                &document,
                base_url,
                episodes_selector,
                links_selector,
                match_regex,
                episode_sort,
                episode_name,
                filter_by_episode,
            )
        }
        _ => {
            let lists_selector_text = source.arguments
                .pointer("/searchConfig/selectorChannelFormatFlattened/selectEpisodeLists")
                .and_then(Value::as_str)
                .unwrap_or("");
            let episodes_selector = source.arguments
                .pointer("/searchConfig/selectorChannelFormatFlattened/selectEpisodesFromList")
                .and_then(Value::as_str)
                .unwrap_or("a");
            let links_selector = source.arguments
                .pointer("/searchConfig/selectorChannelFormatFlattened/selectEpisodeLinksFromList")
                .and_then(Value::as_str)
                .unwrap_or("");
            let match_regex = source.arguments
                .pointer("/searchConfig/selectorChannelFormatFlattened/matchEpisodeSortFromName")
                .and_then(Value::as_str);
            let Ok(lists_selector) = Selector::parse(lists_selector_text) else {
                return Vec::new();
            };
            let lists = document.select(&lists_selector).collect::<Vec<_>>();
            let channels = parse_channel_names(source, &document);
            lists
                .into_iter()
                .enumerate()
                .flat_map(|(index, list)| {
                    let channel = channels.get(index).cloned().unwrap_or_default();
                    parse_episode_hits_from_parent(
                        &list,
                        base_url,
                        episodes_selector,
                        links_selector,
                        match_regex,
                        episode_sort,
                        episode_name,
                        filter_by_episode,
                    )
                    .into_iter()
                    .map(move |mut hit| {
                        hit.channel = channel.clone();
                        hit
                    })
                })
                .collect()
        }
    }
}

fn parse_channel_names(source: &AnimeSource, document: &Html) -> Vec<String> {
    let selector_text = source.arguments
        .pointer("/searchConfig/selectorChannelFormatFlattened/selectChannelNames")
        .and_then(Value::as_str)
        .unwrap_or("");
    let match_text = source.arguments
        .pointer("/searchConfig/selectorChannelFormatFlattened/matchChannelName")
        .and_then(Value::as_str)
        .unwrap_or("");
    let Ok(selector) = Selector::parse(selector_text) else {
        return Vec::new();
    };
    let regex = if match_text.is_empty() {
        None
    } else {
        Regex::new(match_text).ok()
    };
    document
        .select(&selector)
        .filter_map(|element| {
            let text = element_text_or_title(&element);
            if text.is_empty() {
                return None;
            }
            if let Some(regex) = regex.as_ref() {
                let captures = regex.captures(&text)?;
                captures
                    .name("ch")
                    .map(|m| m.as_str().trim().to_string())
                    .or_else(|| captures.get(0).map(|m| m.as_str().trim().to_string()))
                    .filter(|s| !s.is_empty())
            } else {
                Some(text)
            }
        })
        .collect()
}

trait SelectableNode {
    fn select_node(&self, selector: &Selector) -> Vec<scraper::ElementRef<'_>>;
}

impl SelectableNode for Html {
    fn select_node(&self, selector: &Selector) -> Vec<scraper::ElementRef<'_>> {
        self.select(selector).collect()
    }
}

impl<'a> SelectableNode for scraper::ElementRef<'a> {
    fn select_node(&self, selector: &Selector) -> Vec<scraper::ElementRef<'_>> {
        self.select(selector).collect()
    }
}

fn parse_episode_hits_from_parent(
    parent: &dyn SelectableNode,
    base_url: &str,
    episodes_selector_text: &str,
    links_selector_text: &str,
    match_regex: Option<&str>,
    episode_sort: f64,
    episode_name: &str,
    filter_by_episode: bool,
) -> Vec<SelectorEpisodeHit>
{
    let Ok(episodes_selector) = Selector::parse(episodes_selector_text) else {
        return Vec::new();
    };
    let links = select_links_from_parent(parent, links_selector_text, base_url);
    let match_regex = match_regex
        .and_then(|pattern| if pattern.trim().is_empty() { None } else { Regex::new(pattern).ok() });
    parent
        .select_node(&episodes_selector)
        .into_iter()
        .enumerate()
        .filter_map(|(index, element)| {
            let title = element_text_or_title(&element);
            if title.is_empty() {
                return None;
            }
            if !episode_hit_matches(&title, episode_sort, episode_name, filter_by_episode, match_regex.as_ref()) {
                return None;
            }
            let raw_href = links
                .as_ref()
                .and_then(|items| items.get(index).cloned())
                .or_else(|| element.value().attr("href").map(str::to_string))
                .or_else(|| element.value().attr("src").map(str::to_string))?;
            let url = resolve_url(base_url, &raw_href)?;
            Some(SelectorEpisodeHit { title, url, channel: String::new() })
        })
        .collect()
}

fn select_links_from_parent(parent: &dyn SelectableNode, selector_text: &str, base_url: &str) -> Option<Vec<String>> {
    let selector_text = selector_text.trim();
    if selector_text.is_empty() {
        return None;
    }
    let selector = Selector::parse(selector_text).ok()?;
    Some(
        parent
            .select_node(&selector)
            .into_iter()
            .filter_map(|element| {
                element.value()
                    .attr("href")
                    .or_else(|| element.value().attr("src"))
                    .and_then(|href| resolve_url(base_url, href))
            })
            .collect(),
    )
}

fn episode_hit_matches(
    title: &str,
    episode_sort: f64,
    episode_name: &str,
    filter_by_episode: bool,
    match_regex: Option<&Regex>,
) -> bool {
    if !filter_by_episode {
        return true;
    }
    if let Some(regex) = match_regex {
        if let Some(captures) = regex.captures(title) {
            let raw = captures
                .name("ep")
                .map(|m| m.as_str())
                .or_else(|| captures.get(0).map(|m| m.as_str()))
                .unwrap_or(title);
            if episode_sort_matches_raw(raw, episode_sort) {
                return true;
            }
        }
    }
    should_include_title(title, episode_sort, episode_name, true)
}

fn episode_sort_matches_raw(raw: &str, episode_sort: f64) -> bool {
    if episode_sort <= 0.0 {
        return true;
    }
    let sort = episode_sort.round() as i64;
    let cleaned = raw.trim().trim_start_matches('第').trim_end_matches(['话', '集']);
    if let Ok(value) = cleaned.parse::<i64>() {
        return value == sort;
    }
    let normalized = cleaned.to_lowercase();
    let padded = format!("{:02}", sort);
    normalized == sort.to_string()
        || normalized == padded
        || normalized.contains(&format!("ep{}", sort))
        || normalized.contains(&format!("ep{}", padded))
}

fn extract_selector_media_urls(html: &str, page_url: &str) -> Vec<String> {
    let document = Html::parse_document(html);
    let selector = Selector::parse("video[src], source[src], a[href]").expect("valid media selector");
    let mut urls = Vec::new();
    for element in document.select(&selector) {
        let href = element.value().attr("src").or_else(|| element.value().attr("href")).unwrap_or("");
        if let Some(url) = resolve_url(page_url, href) {
            if is_supported_media_url(&url) {
                urls.push(url);
            }
        }
    }
    let quoted = Regex::new(r#"https?://[^"'\\\s<>]+(?:\.m3u8|\.mp4|\.m4v)(?:\?[^"'\\\s<>]*)?"#).expect("media url regex");
    for hit in quoted.find_iter(html) {
        if let Some(url) = resolve_url(page_url, hit.as_str()) {
            urls.push(url);
        }
    }
    dedupe_strings(urls)
}

fn fetch_nested_selector_media_urls(
    client: &Client,
    source: &AnimeSource,
    html: &str,
    page_url: &str,
    ua: &str,
) -> Vec<String> {
    let nested_regex = source.arguments
        .pointer("/searchConfig/matchVideo/matchNestedUrl")
        .and_then(Value::as_str)
        .and_then(|pattern| Regex::new(pattern).ok());
    let Some(nested_regex) = nested_regex else {
        return Vec::new();
    };
    let mut nested_pages = Vec::new();
    let document = Html::parse_document(html);
    let selector = Selector::parse("iframe[src], script[src], a[href]").expect("valid nested selector");
    for element in document.select(&selector) {
        let href = element.value().attr("src").or_else(|| element.value().attr("href")).unwrap_or("");
        if let Some(url) = resolve_url(page_url, href) {
            if nested_regex.is_match(&url) {
                nested_pages.push(url);
            }
        }
    }
    let mut urls = Vec::new();
    for nested_url in nested_pages.into_iter().take(2) {
        if let Ok(nested_html) = http_get_text(
            client,
            &nested_url,
            ua,
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ) {
            urls.extend(extract_selector_media_urls(&nested_html, &nested_url));
        }
    }
    dedupe_strings(urls)
}

fn dedupe_candidates(items: Vec<AnimeMediaCandidate>) -> CoreResult<Vec<AnimeMediaCandidate>> {
    let mut seen = HashSet::new();
    Ok(items.into_iter().filter(|item| seen.insert(item.url.clone())).collect())
}

fn dedupe_subject_hits(items: Vec<SelectorSubjectHit>) -> Vec<SelectorSubjectHit> {
    let mut seen = HashSet::new();
    items.into_iter().filter(|item| seen.insert(item.url.clone())).collect()
}

fn dedupe_strings(items: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    items.into_iter().filter(|item| seen.insert(item.clone())).collect()
}

fn selector_candidate_title(subject_title: &str, episode: &SelectorEpisodeHit) -> String {
    if episode.channel.is_empty() {
        format!("{} · {}", subject_title, episode.title)
    } else {
        format!("{} · {} · {}", subject_title, episode.channel, episode.title)
    }
}

fn element_text_or_title(element: &scraper::ElementRef<'_>) -> String {
    element.value()
        .attr("title")
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| element.text().collect::<Vec<_>>().join("").trim().to_string())
}

fn selector_base_url(subject_url: &str) -> &str {
    if subject_url.ends_with('/') {
        subject_url.trim_end_matches('/')
    } else {
        subject_url.rsplit_once('/').map(|(base, _)| base).unwrap_or(subject_url)
    }
}

fn json_path_strings(value: &Value, path: &str) -> Vec<String> {
    let Some(field_names) = json_path_field_names(path) else {
        return Vec::new();
    };
    let items = match value {
        Value::Array(items) => items.iter().collect::<Vec<_>>(),
        Value::Object(_) => vec![value],
        _ => Vec::new(),
    };
    items
        .into_iter()
        .filter_map(|item| {
            for field in &field_names {
                if let Some(value) = item.get(field).and_then(Value::as_str) {
                    if !value.trim().is_empty() {
                        return Some(value.to_string());
                    }
                }
            }
            None
        })
        .collect()
}

fn json_path_field_names(path: &str) -> Option<Vec<String>> {
    let bracket = Regex::new(r#"'([^']+)'"#).expect("json path bracket regex");
    let fields = bracket
        .captures_iter(path)
        .filter_map(|captures| captures.get(1).map(|m| m.as_str().to_string()))
        .collect::<Vec<_>>();
    if !fields.is_empty() {
        return Some(fields);
    }
    if let Some((_, field)) = path.rsplit_once('.') {
        let field = field.trim_matches(|c: char| !c.is_alphanumeric() && c != '_' && c != '-');
        if !field.is_empty() {
            return Some(vec![field.to_string()]);
        }
    }
    None
}

fn selector_search_keyword(source: &AnimeSource, keyword: &str) -> String {
    let mut value = keyword.trim().to_string();
    let remove_special = source.arguments
        .pointer("/searchConfig/searchRemoveSpecial")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    if remove_special {
        value = simplify_keyword(&value);
    }
    let use_first_word = source.arguments
        .pointer("/searchConfig/searchUseOnlyFirstWord")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if use_first_word {
        value = value.split_whitespace().next().unwrap_or(&value).to_string();
    }
    value
}

fn selector_user_agent(source: &AnimeSource) -> &str {
    source.arguments
        .pointer("/searchConfig/matchVideo/addHeadersToVideo/userAgent")
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(UA_WEB)
}

fn selector_referer(source: &AnimeSource, fallback: &str) -> Option<String> {
    let referer = source.arguments
        .pointer("/searchConfig/matchVideo/addHeadersToVideo/referer")
        .and_then(Value::as_str)
        .unwrap_or("");
    if referer.trim().is_empty() {
        Some(fallback.to_string())
    } else {
        Some(referer.to_string())
    }
}

fn source_supports_avkit(source: &AnimeSource) -> bool {
    let players = source.arguments
        .pointer("/searchConfig/onlySupportsPlayers")
        .and_then(Value::as_array);
    let Some(players) = players else { return true };
    if players.is_empty() {
        return true;
    }
    players.iter().any(|value| value.as_str() == Some("avkit"))
}

fn subject_title_score(title: &str, normalized_keyword: &str) -> i32 {
    let normalized_title = simplify_keyword(title).to_lowercase();
    if normalized_title == normalized_keyword {
        100
    } else if !normalized_keyword.is_empty() && normalized_title.contains(normalized_keyword) {
        80
    } else {
        0
    }
}

fn reports_for_sources(sources: &[AnimeSource]) -> HashMap<String, AnimeMediaSourceReport> {
    sources.iter().filter(|source| source.enabled).map(|source| {
        (source.id.clone(), AnimeMediaSourceReport {
            source_id: source.id.clone(),
            source_name: source.name.clone(),
            factory_id: source.factory_id.clone(),
            status: if matches!(source.factory_id.as_str(), "rss" | "web-selector") && source_supports_avkit(source) {
                "pending".into()
            } else {
                "unsupported".into()
            },
            message: if matches!(source.factory_id.as_str(), "rss" | "web-selector") && source_supports_avkit(source) {
                String::new()
            } else {
                "暂不支持该规则源类型".into()
            },
            ..Default::default()
        })
    }).collect()
}

fn update_source_report_attempt(reports: &mut HashMap<String, AnimeMediaSourceReport>, job: &MediaFetchJob) {
    if let Some(report) = reports.get_mut(&job.source.id) {
        report.attempted_queries += 1;
        if report.status == "pending" {
            report.status = "searching".into();
        }
    }
}

fn update_source_report_success(
    reports: &mut HashMap<String, AnimeMediaSourceReport>,
    job: &MediaFetchJob,
    items: &[AnimeMediaCandidate],
) {
    if let Some(report) = reports.get_mut(&job.source.id) {
        report.succeeded_queries += 1;
        report.candidate_count += items.len() as i64;
        report.supported_count += items.iter().filter(|item| item.is_supported).count() as i64;
        report.status = if report.supported_count > 0 {
            "found".into()
        } else if report.candidate_count > 0 {
            "unsupported".into()
        } else {
            "empty".into()
        };
        report.message = if report.supported_count > 0 {
            format!("找到 {} 个可播放资源", report.supported_count)
        } else if report.candidate_count > 0 {
            "有结果但格式暂不支持".into()
        } else {
            "没有匹配结果".into()
        };
    }
}

fn update_source_report_failure(
    reports: &mut HashMap<String, AnimeMediaSourceReport>,
    job: &MediaFetchJob,
    error: &CoreError,
) {
    if let Some(report) = reports.get_mut(&job.source.id) {
        report.failed_queries += 1;
        if report.supported_count == 0 && report.candidate_count == 0 {
            report.status = "failed".into();
            report.message = error.to_string();
        }
    }
}

fn sorted_source_reports(reports: HashMap<String, AnimeMediaSourceReport>) -> Vec<AnimeMediaSourceReport> {
    let mut values = reports.into_values().collect::<Vec<_>>();
    values.sort_by(|a, b| {
        source_status_rank(&a.status).cmp(&source_status_rank(&b.status))
            .then_with(|| b.supported_count.cmp(&a.supported_count))
            .then_with(|| a.source_name.cmp(&b.source_name))
    });
    values
}

fn source_status_rank(status: &str) -> i32 {
    match status {
        "found" => 0,
        "searching" => 1,
        "empty" => 2,
        "unsupported" => 3,
        "failed" => 4,
        _ => 5,
    }
}

fn parse_sources(json_text: &str) -> CoreResult<AnimeSourceUpdate> {
    let value: Value = serde_json::from_str(json_text)?;
    let list_value = value.get("exportedMediaSourceDataList")
        .or_else(|| value.get("data"))
        .cloned()
        .unwrap_or(value);
    let decoded: ExportedMediaSourceDataList = serde_json::from_value(list_value)?;
    let sources = decoded.media_sources.into_iter().enumerate().map(|(index, data)| {
        let name = data.arguments.get("name").and_then(Value::as_str).unwrap_or("未命名规则源").to_string();
        let id = stable_source_id(&data.factory_id, &name, index);
        AnimeSource {
            id,
            factory_id: data.factory_id,
            version: data.version,
            name,
            description: data.arguments.get("description").and_then(Value::as_str).unwrap_or("").to_string(),
            icon_url: data.arguments.get("iconUrl").or_else(|| data.arguments.get("icon_url")).and_then(Value::as_str).unwrap_or("").to_string(),
            tier: data.arguments.get("tier").and_then(Value::as_str).unwrap_or("Fallback").to_string(),
            enabled: true,
            arguments: data.arguments,
        }
    }).collect();
    Ok(AnimeSourceUpdate { sources, updated_at: now_secs() })
}

fn parse_rss_candidates(
    source: &AnimeSource,
    xml: &str,
    page_url: &str,
    episode_sort: f64,
    episode_name: &str,
    filter_by_episode: bool,
) -> Vec<AnimeMediaCandidate> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut buf = Vec::new();
    let mut items = Vec::new();
    let mut current_tag = String::new();
    let mut title = String::new();
    let mut link = String::new();
    let mut enclosure = String::new();
    let mut in_item = false;
    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                let tag = String::from_utf8_lossy(e.name().as_ref()).to_string();
                if tag == "item" || tag == "entry" {
                    in_item = true;
                    title.clear();
                    link.clear();
                    enclosure.clear();
                }
                if in_item && (tag == "enclosure" || tag.ends_with(":content")) {
                    for attr in e.attributes().filter_map(|a| a.ok()) {
                        if attr.key.as_ref() == b"url" {
                            enclosure = attr.unescape_value().unwrap_or_default().into_owned();
                        }
                    }
                }
                current_tag = tag;
            }
            Ok(Event::Empty(e)) => {
                if in_item && (e.name().as_ref() == b"enclosure" || e.name().as_ref().ends_with(b":content")) {
                    for attr in e.attributes().filter_map(|a| a.ok()) {
                        if attr.key.as_ref() == b"url" {
                            enclosure = attr.unescape_value().unwrap_or_default().into_owned();
                        }
                    }
                }
            }
            Ok(Event::Text(t)) if in_item => {
                let text = t.unescape().unwrap_or_default().into_owned();
                if current_tag == "title" {
                    title.push_str(&text);
                } else if current_tag == "link" {
                    link.push_str(&text);
                }
            }
            Ok(Event::End(e)) => {
                let tag = String::from_utf8_lossy(e.name().as_ref()).to_string();
                if tag == "item" || tag == "entry" {
                    let media_url = first_non_empty(&[enclosure.clone(), link.clone()]);
                    if should_include_title(&title, episode_sort, episode_name, filter_by_episode) {
                        items.push(make_candidate(source, title.clone(), media_url, page_url.to_string(), None));
                    }
                    in_item = false;
                    current_tag.clear();
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
        buf.clear();
    }
    items
}

fn parse_selector_candidates(
    source: &AnimeSource,
    html: &str,
    page_url: &str,
    episode_sort: f64,
    episode_name: &str,
    filter_by_episode: bool,
) -> Vec<AnimeMediaCandidate> {
    let document = Html::parse_document(html);
    let selector = Selector::parse("a[href], video[src], source[src]").expect("valid selector");
    let referer = source.arguments
        .pointer("/searchConfig/matchVideo/addHeadersToVideo/referer")
        .and_then(Value::as_str)
        .map(str::to_string);
    let mut candidates = Vec::new();
    let mut seen = HashSet::new();
    for element in document.select(&selector) {
        let value = element.value();
        let href = value.attr("href").or_else(|| value.attr("src")).unwrap_or("").trim();
        if href.is_empty() {
            continue;
        }
        let resolved = resolve_url(page_url, href).unwrap_or_else(|| href.to_string());
        if !is_media_like(&resolved) && !looks_like_episode_page(&resolved) {
            continue;
        }
        let title = element.text().collect::<Vec<_>>().join("").trim().to_string();
        let title = if title.is_empty() { resolved.clone() } else { title };
        if should_include_title(&title, episode_sort, episode_name, filter_by_episode)
            || is_supported_media_url(&resolved) {
            let mut item = make_candidate(source, title, resolved, page_url.to_string(), referer.clone());
            if !is_supported_media_url(&item.url) && looks_like_episode_page(&item.url) {
                item.unsupported_reason = "需要网页解析/验证码，第一版暂不支持".into();
            }
            if seen.insert(item.url.clone()) {
                candidates.push(item);
            }
        }
    }
    candidates
}

fn make_candidate(
    source: &AnimeSource,
    title: String,
    url: String,
    page_url: String,
    referer: Option<String>,
) -> AnimeMediaCandidate {
    let kind = media_kind(&url);
    let is_supported = kind == "hls" || kind == "mp4";
    let unsupported_reason = if is_supported {
        String::new()
    } else if kind == "torrent" {
        "BT/磁力资源第一版暂不支持".into()
    } else {
        "暂不支持该资源格式".into()
    };
    let quality_label = infer_quality(&title, &url);
    AnimeMediaCandidate {
        id: format!("{}:{}", source.id, stable_hash(&url)),
        source_id: source.id.clone(),
        source_name: source.name.clone(),
        title,
        url,
        page_url: page_url.clone(),
        kind,
        quality_label,
        is_supported,
        unsupported_reason,
        referer: referer.unwrap_or(page_url),
        user_agent: source.arguments
            .pointer("/searchConfig/matchVideo/addHeadersToVideo/userAgent")
            .and_then(Value::as_str)
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(UA_WEB)
            .to_string(),
    }
}

fn convert_subject(raw: BangumiSubjectRaw, collection_type: i64, ep_status: i64) -> AnimeSubject {
    let images = raw.images.unwrap_or_default();
    let rating = raw.rating.unwrap_or_default();
    let aliases = raw.infobox.into_iter()
        .filter(|item| item.key == "别名")
        .flat_map(|item| match item.value {
            Value::String(s) => vec![s],
            Value::Array(values) => values.into_iter().filter_map(|v| {
                v.as_str().map(str::to_string).or_else(|| {
                    v.get("v").and_then(Value::as_str).map(str::to_string)
                })
            }).collect(),
            _ => Vec::new(),
        })
        .filter(|s| !s.trim().is_empty())
        .collect::<Vec<_>>();
    AnimeSubject {
        id: raw.id,
        name: raw.name,
        name_cn: raw.name_cn,
        summary: raw.summary,
        date: raw.date,
        image: AnimeSubjectImage {
            large: images.large,
            common: images.common,
            medium: images.medium,
            small: images.small,
            grid: images.grid,
        },
        rating_score: rating.score,
        rating_total: rating.total,
        rank: raw.rank,
        collection_type,
        collection_label: subject_collection_label(collection_type).to_string(),
        ep_status,
        total_episodes: raw.total_episodes.max(raw.eps),
        tags: raw.tags.into_iter().map(|tag| tag.name).filter(|s| !s.is_empty()).collect(),
        aliases,
        episodes: Vec::new(),
    }
}

fn convert_episode(subject_id: i64, raw: BangumiEpisodeRaw) -> AnimeEpisode {
    AnimeEpisode {
        id: raw.id,
        subject_id,
        sort: raw.sort,
        ep: raw.ep,
        name: raw.name,
        name_cn: raw.name_cn,
        duration: raw.duration,
        airdate: raw.airdate,
        desc: raw.desc,
        collection_type: raw.collection.map(|c| c.r#type).unwrap_or(0),
    }
}

fn subject_collection_label(value: i64) -> &'static str {
    match value {
        1 => "想看",
        2 => "看过",
        3 => "在看",
        4 => "搁置",
        5 => "抛弃",
        _ => "未收藏",
    }
}

fn build_search_keywords(subject_names: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    subject_names.iter()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .filter_map(|s| {
            let value = simplify_keyword(s);
            if value.is_empty() || !seen.insert(value.clone()) {
                None
            } else {
                Some(value)
            }
        })
        .take(3)
        .collect()
}

fn fill_search_url(template: &str, keyword: &str, page: i64) -> String {
    let encoded = url::form_urlencoded::byte_serialize(keyword.as_bytes()).collect::<String>();
    template
        .replace("{keyword}", &encoded)
        .replace("{page}", &page.to_string())
}

fn should_include_title(title: &str, episode_sort: f64, episode_name: &str, filter_by_episode: bool) -> bool {
    if !filter_by_episode || episode_sort <= 0.0 {
        return true;
    }
    let normalized = title.to_lowercase();
    let sort = episode_sort.round() as i64;
    let patterns = [
        format!("{:02}", sort),
        format!("第{}集", sort),
        format!("第{:02}集", sort),
        format!(" ep{}", sort),
        format!(" ep{:02}", sort),
        format!("[{}]", sort),
        format!("[{:02}]", sort),
    ];
    if patterns.iter().any(|p| normalized.contains(&p.to_lowercase())) {
        return true;
    }
    let ep_name = episode_name.trim().to_lowercase();
    !ep_name.is_empty() && normalized.contains(&ep_name)
}

fn media_kind(url: &str) -> String {
    let lower = url.to_lowercase();
    if lower.contains(".m3u8") {
        "hls".into()
    } else if lower.contains(".mp4") || lower.contains(".m4v") {
        "mp4".into()
    } else if lower.starts_with("magnet:") || lower.contains(".torrent") {
        "torrent".into()
    } else {
        "web".into()
    }
}

fn is_supported_media_url(url: &str) -> bool {
    matches!(media_kind(url).as_str(), "hls" | "mp4")
}

fn is_media_like(url: &str) -> bool {
    let kind = media_kind(url);
    kind == "hls" || kind == "mp4" || kind == "torrent"
}

fn looks_like_episode_page(url: &str) -> bool {
    let lower = url.to_lowercase();
    lower.contains("play") || lower.contains("episode") || lower.contains("video")
}

fn infer_quality(title: &str, url: &str) -> String {
    let combined = format!("{} {}", title, url).to_lowercase();
    for quality in ["2160p", "4k", "1080p", "720p", "480p", "360p"] {
        if combined.contains(quality) {
            return quality.to_uppercase();
        }
    }
    if combined.contains("web-dl") {
        return "WEB-DL".into();
    }
    if combined.contains("bd") || combined.contains("bdrip") {
        return "BD".into();
    }
    String::new()
}

fn score_quality(label: &str) -> i32 {
    let lower = label.to_lowercase();
    if lower.contains("2160") || lower.contains("4k") { 4000 }
    else if lower.contains("1080") { 1080 }
    else if lower.contains("720") { 720 }
    else if lower.contains("480") { 480 }
    else { 0 }
}

fn resolve_url(base: &str, href: &str) -> Option<String> {
    let href = href.trim();
    if href.is_empty() {
        return Some(base.to_string());
    }
    if href.starts_with("http://") || href.starts_with("https://") || href.starts_with("magnet:") {
        return Some(href.to_string());
    }
    Url::parse(base).ok()?.join(href).ok().map(|u| u.to_string())
}

fn push_unique(target: &mut Vec<AnimeMediaCandidate>, seen: &mut HashSet<String>, items: &mut Vec<AnimeMediaCandidate>) {
    for item in items.drain(..) {
        if seen.insert(item.url.clone()) {
            target.push(item);
        }
    }
}

fn push_diagnostic_message(messages: &mut Vec<String>, source: &AnimeSource, keyword: &str, error: &CoreError) {
    if messages.len() >= 8 {
        return;
    }
    messages.push(format!("{} · {} · {}", source.name, keyword, error));
}

fn simplify_keyword(text: &str) -> String {
    let mut value = text.replace(['：', ':', '·'], " ");
    if let Some((head, _)) = value.split_once('(') {
        value = head.to_string();
    }
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn first_non_empty(values: &[String]) -> String {
    values.iter().find(|v| !v.trim().is_empty()).cloned().unwrap_or_default()
}

fn stable_source_id(factory_id: &str, name: &str, index: usize) -> String {
    format!("{}:{}:{}", factory_id, stable_hash(name), index)
}

fn stable_hash(text: &str) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn null_as_default<'de, D, T>(de: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: DeserializeOwned + Default,
{
    Ok(Option::<T>::deserialize(de)?.unwrap_or_default())
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn url_path(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes()).collect::<String>()
}

fn bangumi_error_message(text: &str) -> String {
    if let Ok(value) = serde_json::from_str::<Value>(text) {
        if let Some(detail) = value.get("detail").and_then(Value::as_str) {
            return detail.to_string();
        }
        if let Some(description) = value.get("description").and_then(Value::as_str) {
            return description.to_string();
        }
        if let Some(error) = value.get("error").and_then(Value::as_str) {
            return error.to_string();
        }
    }
    if text.trim().is_empty() {
        "Bangumi API request failed".into()
    } else {
        text.chars().take(300).collect()
    }
}

#[cfg(test)]
mod anime_tests {
    use super::*;

    fn test_source(factory_id: &str) -> AnimeSource {
        AnimeSource {
            id: "test-source".into(),
            factory_id: factory_id.into(),
            version: 1,
            name: "测试源".into(),
            description: String::new(),
            icon_url: String::new(),
            tier: "Fallback".into(),
            enabled: true,
            arguments: json!({
                "name": "测试源",
                "searchConfig": {
                    "matchVideo": {
                        "addHeadersToVideo": {
                            "referer": "https://example.test/list",
                            "userAgent": "TestAgent/1.0"
                        }
                    }
                }
            }),
        }
    }

    #[test]
    fn bangumi_oauth_start_builds_expected_callback_url() {
        let core = Core::new("{}").unwrap();
        let start = core
            .anime_oauth_start("client-id", "ibili://bangumi-oauth")
            .unwrap();
        let url = Url::parse(&start.authorize_url).unwrap();
        assert_eq!(url.as_str().split('?').next().unwrap(), "https://bgm.tv/oauth/authorize");
        let pairs = url.query_pairs().collect::<Vec<_>>();
        assert!(pairs.iter().any(|(k, v)| k == "client_id" && v == "client-id"));
        assert!(pairs.iter().any(|(k, v)| k == "response_type" && v == "code"));
        assert!(pairs.iter().any(|(k, v)| k == "redirect_uri" && v == "ibili://bangumi-oauth"));
    }

    #[test]
    fn default_media_source_subscriptions_match_animeko_defaults() {
        assert_eq!(
            DEFAULT_MEDIA_SOURCE_SUBSCRIPTIONS,
            [
                "https://sub.creamycake.org/v1/bt1.json",
                "https://sub.creamycake.org/v1/css1.json",
            ]
        );
    }

    #[test]
    fn parse_sources_accepts_animeko_export_wrapper() {
        let json_text = r#"{
          "exportedMediaSourceDataList": {
            "mediaSources": [
              {
                "factoryId": "rss",
                "version": 1,
                "arguments": {
                  "name": "AnimeGarden",
                  "description": "动画 BT 资源聚合站",
                  "iconUrl": "https://garden.example/favicon.ico",
                  "searchConfig": { "searchUrl": "https://garden.example/rss?q={keyword}" }
                }
              },
              {
                "factoryId": "web-selector",
                "version": 2,
                "arguments": {
                  "name": "WebDirect",
                  "tier": "Fallback",
                  "searchConfig": { "searchUrl": "https://video.example/search?wd={keyword}" }
                }
              }
            ]
          }
        }"#;
        let update = parse_sources(json_text).unwrap();
        assert_eq!(update.sources.len(), 2);
        assert_eq!(update.sources[0].factory_id, "rss");
        assert_eq!(update.sources[0].name, "AnimeGarden");
        assert_eq!(update.sources[0].icon_url, "https://garden.example/favicon.ico");
        assert_eq!(update.sources[1].factory_id, "web-selector");
        assert_eq!(update.sources[1].tier, "Fallback");
    }

    #[test]
    fn subject_total_episodes_ignores_collection_stats() {
        let raw = BangumiSubjectRaw {
            id: 1,
            name: "Test".into(),
            total_episodes: 12,
            eps: 0,
            ..Default::default()
        };
        let subject = convert_subject(raw, 0, 9999);
        assert_eq!(subject.total_episodes, 12);
        assert_eq!(subject.ep_status, 9999);
    }

    #[test]
    fn rss_candidates_mark_torrent_unsupported_and_hls_supported() {
        let source = test_source("rss");
        let xml = r#"
          <rss><channel>
            <item>
              <title>测试番 第01集 1080P</title>
              <enclosure url="https://cdn.example/video-01.m3u8" />
            </item>
            <item>
              <title>测试番 第02集 1080P</title>
              <link>magnet:?xt=urn:btih:abcdef</link>
            </item>
            <item>
              <title>测试番 第01集 BT</title>
              <link>https://cdn.example/video-01.torrent</link>
            </item>
          </channel></rss>
        "#;
        let items = parse_rss_candidates(&source, xml, "https://feed.example/rss", 1.0, "", true);
        assert_eq!(items.len(), 2);
        let hls = items.iter().find(|item| item.kind == "hls").unwrap();
        assert!(hls.is_supported);
        assert_eq!(hls.quality_label, "1080P");
        let torrent = items.iter().find(|item| item.kind == "torrent").unwrap();
        assert!(!torrent.is_supported);
        assert_eq!(torrent.unsupported_reason, "BT/磁力资源第一版暂不支持");
    }

    #[test]
    fn selector_candidates_resolve_relative_mp4_and_apply_headers() {
        let source = test_source("web-selector");
        let html = r#"
          <html><body>
            <a href="/play/ep1">测试番 第01集</a>
            <a href="/media/episode-01-720p.mp4">测试番 第01集 720P</a>
            <source src="https://cdn.example/episode-02.m3u8">
          </body></html>
        "#;
        let items = parse_selector_candidates(
            &source,
            html,
            "https://video.example/search",
            1.0,
            "",
            true,
        );
        let mp4 = items.iter().find(|item| item.kind == "mp4").unwrap();
        assert_eq!(mp4.url, "https://video.example/media/episode-01-720p.mp4");
        assert_eq!(mp4.referer, "https://example.test/list");
        assert_eq!(mp4.user_agent, "TestAgent/1.0");
        assert!(mp4.is_supported);
        let web = items.iter().find(|item| item.kind == "web").unwrap();
        assert!(!web.is_supported);
        assert_eq!(web.unsupported_reason, "需要网页解析/验证码，第一版暂不支持");
    }

    #[test]
    fn selector_episode_hits_fallback_when_channel_names_missing() {
        let source = AnimeSource {
            arguments: json!({
                "searchConfig": {
                    "channelFormatId": "index-grouped",
                    "selectorChannelFormatFlattened": {
                        "selectChannelNames": ".missing-channel",
                        "selectEpisodeLists": ".module-list",
                        "selectEpisodesFromList": "a",
                        "selectEpisodeLinksFromList": "",
                        "matchEpisodeSortFromName": "第\\s*(?<ep>.+)\\s*[话集]"
                    }
                }
            }),
            ..test_source("web-selector")
        };
        let html = r#"
          <div class="module-list">
            <a href="/play/1">第1集</a>
            <a href="/play/2">第2集</a>
          </div>
        "#;
        let hits = parse_selector_episode_hits(
            &source,
            html,
            "https://example.test/detail/season.html",
            2.0,
            "",
            true,
        );
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].title, "第2集");
        assert_eq!(hits[0].channel, "");
        assert_eq!(hits[0].url, "https://example.test/play/2");
    }

    #[test]
    fn json_path_subject_hits_support_animeko_simple_paths() {
        let source = AnimeSource {
            arguments: json!({
                "searchConfig": {
                    "subjectFormatId": "json-path-indexed",
                    "selectorSubjectFormatJsonPathIndexed": {
                        "selectNames": "$[*]['title','name']",
                        "selectLinks": "$[*]['url','link']"
                    }
                }
            }),
            ..test_source("web-selector")
        };
        let html = r#"[{"title":"测试番","url":"/detail/1"},{"name":"备用名","link":"https://cdn.example/detail/2"}]"#;
        let hits = parse_selector_subjects(&source, html, "https://example.test/search?q=a", "测试番");
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].title, "测试番");
        assert_eq!(hits[0].url, "https://example.test/detail/1");
        assert_eq!(hits[1].url, "https://cdn.example/detail/2");
    }

    #[test]
    fn keyword_builder_deduplicates_and_simplifies_aliases() {
        let names = vec![
            "葬送的芙莉莲：特别篇".to_string(),
            "葬送的芙莉莲 特别篇".to_string(),
            "Frieren (TV)".to_string(),
            "Sousou no Frieren".to_string(),
        ];
        let keywords = build_search_keywords(&names);
        assert_eq!(keywords, vec!["葬送的芙莉莲 特别篇", "Frieren", "Sousou no Frieren"]);
    }
}
