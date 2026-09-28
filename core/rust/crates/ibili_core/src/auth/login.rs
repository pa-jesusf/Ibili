//! Native login protocols mirrored from PiliPlus lib/http/login.dart.
//! Candidate credentials are returned, never installed until the UI accepts this attempt.
use crate::dto::ApiEnvelope;
use crate::http::HttpClient;
use crate::session::PersistedSession;
use crate::{Core, CoreError, CoreResult};
use base64::Engine;
use md5::{Digest, Md5};
use rand::{distributions::Alphanumeric, Rng};
use rsa::{pkcs8::DecodePublicKey, Pkcs1v15Encrypt, RsaPublicKey};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::OnceLock;

const PASSPORT: &str = "https://passport.bilibili.com";

#[derive(Default, Deserialize)]
#[serde(default)]
pub struct LoginRequest {
    username: String,
    password: String,
    tel: String,
    country_code: String,
    code: String,
    captcha_key: String,
    cookie: String,
    captcha: Option<CaptchaProof>,
    risk: Option<PhoneRisk>,
}

#[derive(Deserialize)]
pub struct CaptchaProof {
    challenge: String,
    validate: String,
    seccode: String,
    token: String,
}

#[derive(Serialize)]
pub struct CaptchaChallenge {
    gt: String,
    challenge: String,
    token: String,
}

#[derive(Serialize, Deserialize)]
pub struct PhoneRisk {
    url: String,
    tmp_code: String,
    request_id: String,
    source: String,
    #[serde(default)]
    phone: String,
}

#[derive(Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum LoginResult {
    Confirmed { session: PersistedSession },
    Captcha { captcha: CaptchaChallenge },
    PhoneVerification { risk: PhoneRisk },
    SmsSent { captcha_key: String },
}

impl Core {
    pub fn auth_login(&self, method: &str, request: LoginRequest) -> CoreResult<LoginResult> {
        // A rejected/cancelled attempt must not modify the live account cookie jar.
        let http = HttpClient::new()?;
        let mut form = app_form();
        add_captcha(&mut form, request.captcha.as_ref());
        match method {
            "auth.cookie" => {
                let cookies = parse_cookie_header(&request.cookie)?;
                http.install_web_cookies(&cookies);
                #[derive(Deserialize)]
                struct Account {
                    mid: i64,
                }
                let account: Account =
                    http.get_web("https://api.bilibili.com/x/member/web/account", &[])?;
                if account.mid <= 0 {
                    return Err(CoreError::AuthRequired);
                }
                if let Some((_, mid)) = cookies.iter().find(|(name, _)| name == "DedeUserID") {
                    if mid.parse::<i64>().ok() != Some(account.mid) {
                        return Err(CoreError::InvalidArgument("Cookie 的用户身份不一致".into()));
                    }
                }
                Ok(LoginResult::Confirmed {
                    session: PersistedSession {
                        mid: account.mid,
                        web_cookies: cookies,
                        ..Default::default()
                    },
                })
            }
            "auth.password" => {
                require(&request.username, "请输入邮箱或手机号")?;
                require(&request.password, "请输入密码")?;
                let key: LoginKey =
                    http.get_web(&format!("{PASSPORT}/x/passport-login/web/key"), &[])?;
                add_device(&mut form, &key)?;
                form.extend([
                    ("username".into(), request.username),
                    (
                        "password".into(),
                        encrypt(&key.key, &(key.hash + &request.password))?,
                    ),
                    ("permission".into(), "ALL".into()),
                    (
                        "from_pv".into(),
                        "main.homepage.avatar-nologin.all.click".into(),
                    ),
                    ("from_url".into(), "bilibili%3A%2F%2Fpegasus%2Fpromo".into()),
                ]);
                let response = post(&http, "/x/passport-login/oauth2/login", form, None)?;
                login_result(&http, response)
            }
            "auth.sms.send" => {
                validate_phone(&request.country_code, &request.tel)?;
                let timestamp = time::OffsetDateTime::now_utc().unix_timestamp_nanos() / 1_000_000;
                form.extend([
                    ("cid".into(), request.country_code),
                    ("tel".into(), request.tel),
                    (
                        "login_session_id".into(),
                        hex::encode(Md5::digest(format!("{}{timestamp}", buvid()))),
                    ),
                ]);
                let response = post(&http, "/x/passport-login/sms/send", form, None)?;
                if response.code == -105
                    || response
                        .data
                        .as_ref()
                        .is_some_and(|v| !str_field(v, "recaptcha_url").is_empty())
                {
                    let challenge = response
                        .data
                        .as_ref()
                        .and_then(|v| challenge_from_url(str_field(v, "recaptcha_url")).ok());
                    return Ok(LoginResult::Captcha {
                        captcha: match challenge {
                            Some(challenge) => challenge,
                            None => pre_captcha(&http)?, // Documented upstream response without URL parameters.
                        },
                    });
                }
                sms_result(response)
            }
            "auth.sms.login" => {
                validate_phone(&request.country_code, &request.tel)?;
                require(&request.captcha_key, "请先获取短信验证码")?;
                require(&request.code, "请输入短信验证码")?;
                let key: LoginKey =
                    http.get_web(&format!("{PASSPORT}/x/passport-login/web/key"), &[])?;
                add_device(&mut form, &key)?;
                form.extend([
                    ("cid".into(), request.country_code),
                    ("tel".into(), request.tel),
                    ("captcha_key".into(), request.captcha_key),
                    ("code".into(), request.code),
                    (
                        "from_pv".into(),
                        "main.my-information.my-login.0.click".into(),
                    ),
                    (
                        "from_url".into(),
                        "bilibili%3A%2F%2Fuser_center%2Fmine".into(),
                    ),
                ]);
                login_result(
                    &http,
                    post(&http, "/x/passport-login/login/sms", form, None)?,
                )
            }
            "auth.captcha" => Ok(LoginResult::Captcha {
                captcha: pre_captcha(&http)?,
            }),
            "auth.risk.send" => {
                let risk = checked_risk(request.risk.as_ref())?;
                if request.captcha.is_none() {
                    return Err(CoreError::InvalidArgument("请先完成人机验证".into()));
                }
                form.extend([
                    ("tmp_code".into(), risk.tmp_code.clone()),
                    ("sms_type".into(), "loginTelCheck".into()),
                ]);
                sms_result(post(
                    &http,
                    "/x/safecenter/common/sms/send",
                    form,
                    Some(&risk.url),
                )?)
            }
            "auth.risk.verify" => {
                let risk = checked_risk(request.risk.as_ref())?;
                require(&request.code, "请输入短信验证码")?;
                require(&request.captcha_key, "请先获取短信验证码")?;
                form.extend([
                    ("type".into(), "loginTelCheck".into()),
                    ("tmp_code".into(), risk.tmp_code.clone()),
                    ("request_id".into(), risk.request_id.clone()),
                    ("source".into(), risk.source.clone()),
                    ("captcha_key".into(), request.captcha_key),
                    ("code".into(), request.code),
                ]);
                let verified = data(post(
                    &http,
                    "/x/safecenter/login/tel/verify",
                    form,
                    Some(&risk.url),
                )?)?;
                let code = str_field(&verified, "code");
                require(code, "验证响应缺少授权码")?;
                let mut exchange = app_form();
                exchange.extend([
                    ("code".into(), code.into()),
                    ("grant_type".into(), "authorization_code".into()),
                ]);
                login_result(
                    &http,
                    post(
                        &http,
                        "/x/passport-login/oauth2/access_token",
                        exchange,
                        None,
                    )?,
                )
            }
            _ => Err(CoreError::InvalidArgument(
                "unsupported login method".into(),
            )),
        }
    }
}

#[derive(Deserialize)]
struct LoginKey {
    hash: String,
    key: String,
}

fn encrypt(pem: &str, text: &str) -> CoreResult<String> {
    let key = RsaPublicKey::from_public_key_pem(pem)
        .map_err(|_| CoreError::Decode("登录公钥格式错误".into()))?;
    // Public-key encryption only; private RSA keys are never present on this client.
    let encrypted = key
        .encrypt(&mut rand::rngs::OsRng, Pkcs1v15Encrypt, text.as_bytes())
        .map_err(|_| CoreError::InvalidArgument("登录数据无法加密，请检查输入长度".into()))?;
    Ok(base64::engine::general_purpose::STANDARD.encode(encrypted))
}

fn device_id() -> &'static str {
    static DEVICE: OnceLock<String> = OnceLock::new();
    DEVICE.get_or_init(|| make_device_id(time::OffsetDateTime::now_utc()))
}

fn make_device_id(date: time::OffsetDateTime) -> String {
    // PiliPlus LoginUtils.genDeviceId: 16 random bytes, seven BCD date
    // bytes, eight random bytes, then the low byte of their sum.
    let mut bytes = rand::random::<[u8; 32]>();
    let components = [
        date.year() / 100,
        date.year() % 100,
        date.month() as i32,
        date.day() as i32,
        date.hour() as i32,
        date.minute() as i32,
        date.second() as i32,
    ];
    for (index, value) in components.into_iter().enumerate() {
        bytes[16 + index] = (((value / 10) << 4) | (value % 10)) as u8;
    }
    bytes[31] = bytes[..31]
        .iter()
        .fold(0u8, |sum, byte| sum.wrapping_add(*byte));
    hex::encode(bytes)
}

fn buvid() -> &'static str {
    static BUVID: OnceLock<String> = OnceLock::new();
    BUVID.get_or_init(|| {
        let value = hex::encode(rand::random::<[u8; 16]>());
        format!(
            "XY{}{}{}{}",
            &value[2..3],
            &value[12..13],
            &value[22..23],
            value
        )
    })
}

fn app_form() -> Vec<(String, String)> {
    [
        ("build", "2001100"),
        ("buvid", buvid()),
        ("local_id", buvid()),
        ("c_locale", "zh_CN"),
        ("s_locale", "zh_CN"),
        ("channel", "master"),
        ("disable_rcmd", "0"),
        ("mobi_app", "android_hd"),
        ("platform", "android"),
        (
            "statistics",
            r#"{"appId":5,"platform":3,"version":"2.0.1","abtest":""}"#,
        ),
    ]
    .into_iter()
    .map(|(k, v)| (k.into(), v.into()))
    .collect()
}

fn add_device(form: &mut Vec<(String, String)>, key: &LoginKey) -> CoreResult<()> {
    let random: String = rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(16)
        .map(char::from)
        .collect();
    let dt = encrypt(&key.key, &random)?;
    form.extend([
        ("bili_local_id".into(), device_id().into()),
        ("device_id".into(), device_id().into()),
        ("device".into(), "phone".into()),
        ("device_name".into(), "vivo".into()),
        ("device_platform".into(), "Android14vivo".into()),
        (
            "dt".into(),
            url::form_urlencoded::byte_serialize(dt.as_bytes()).collect(),
        ),
    ]);
    Ok(())
}

fn add_captcha(form: &mut Vec<(String, String)>, captcha: Option<&CaptchaProof>) {
    if let Some(c) = captcha {
        form.extend([
            ("gee_challenge".into(), c.challenge.clone()),
            ("gee_validate".into(), c.validate.clone()),
            ("gee_seccode".into(), c.seccode.clone()),
            ("recaptcha_token".into(), c.token.clone()),
        ]);
    }
}

fn post(
    http: &HttpClient,
    path: &str,
    form: Vec<(String, String)>,
    referer: Option<&str>,
) -> CoreResult<ApiEnvelope<Value>> {
    http.post_login_form(&format!("{PASSPORT}{path}"), form, buvid(), referer)
}

fn data(response: ApiEnvelope<Value>) -> CoreResult<Value> {
    if response.code != 0 {
        return Err(CoreError::Api {
            code: response.code,
            msg: response.message,
        });
    }
    response
        .data
        .ok_or_else(|| CoreError::Decode("登录响应缺少数据".into()))
}

fn login_result(http: &HttpClient, response: ApiEnvelope<Value>) -> CoreResult<LoginResult> {
    if response.code == -105 {
        let value = response
            .data
            .ok_or_else(|| CoreError::Decode("缺少人机验证信息".into()))?;
        return Ok(LoginResult::Captcha {
            captcha: challenge_from_url(str_field(&value, "url"))?,
        });
    }
    let value = data(response)?;
    if value["status"].as_i64() == Some(2) {
        let url = str_field(&value, "url");
        let parsed = passport_url(url)?;
        let query: std::collections::HashMap<_, _> = parsed.query_pairs().collect();
        let mut risk = PhoneRisk {
            url: url.into(),
            tmp_code: query
                .get("tmp_token")
                .map(|s| s.to_string())
                .unwrap_or_default(),
            request_id: query
                .get("request_id")
                .map(|s| s.to_string())
                .unwrap_or_default(),
            source: query
                .get("source")
                .map(|s| s.to_string())
                .unwrap_or_default(),
            phone: String::new(),
        };
        checked_risk(Some(&risk))?;
        let info: Value = http.get_web(
            &format!("{PASSPORT}/x/safecenter/user/info"),
            &[("tmp_code".into(), risk.tmp_code.clone())],
        )?;
        if info["account_info"]["tel_verify"].as_bool() != Some(true) {
            return Err(CoreError::InvalidArgument(
                "此账号不能使用手机号验证，请使用其他登录方式".into(),
            ));
        }
        risk.phone = str_field(&info["account_info"], "hide_tel").into();
        return Ok(LoginResult::PhoneVerification { risk });
    }
    Ok(LoginResult::Confirmed {
        session: session_from_value(&value)?,
    })
}

fn session_from_value(value: &Value) -> CoreResult<PersistedSession> {
    #[derive(Deserialize)]
    struct Tokens {
        mid: i64,
        access_token: String,
        #[serde(default)]
        refresh_token: String,
        expires_in: i64,
    }
    let tokens: Tokens = serde_json::from_value(value["token_info"].clone())
        .map_err(|_| CoreError::Decode("登录响应缺少有效身份信息".into()))?;
    let cookies: super::CookieInfo = serde_json::from_value(value["cookie_info"].clone())
        .map_err(|_| CoreError::Decode("登录响应缺少 Cookie".into()))?;
    if tokens.mid <= 0
        || tokens.access_token.is_empty()
        || !cookies
            .cookies
            .iter()
            .any(|c| c.name == "SESSDATA" && !c.value.is_empty())
    {
        return Err(CoreError::Decode("登录凭证不完整".into()));
    }
    Ok(PersistedSession {
        mid: tokens.mid,
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        expires_at_secs: now() + tokens.expires_in.max(0),
        web_cookies: cookies
            .cookies
            .into_iter()
            .map(|c| (c.name, c.value))
            .collect(),
    })
}

fn sms_result(response: ApiEnvelope<Value>) -> CoreResult<LoginResult> {
    let value = data(response)?;
    let key = str_field(&value, "captcha_key");
    require(key, "短信响应缺少验证码标识")?;
    Ok(LoginResult::SmsSent {
        captcha_key: key.into(),
    })
}

fn pre_captcha(http: &HttpClient) -> CoreResult<CaptchaChallenge> {
    let value = data(post(http, "/x/safecenter/captcha/pre", vec![], None)?)?;
    challenge(
        str_field(&value, "gee_gt"),
        str_field(&value, "gee_challenge"),
        str_field(&value, "recaptcha_token"),
    )
}

fn challenge_from_url(raw: &str) -> CoreResult<CaptchaChallenge> {
    let url = passport_url(raw)?;
    let params: std::collections::HashMap<_, _> = url.query_pairs().collect();
    challenge(
        params.get("gee_gt").map(|s| s.as_ref()).unwrap_or(""),
        params
            .get("gee_challenge")
            .map(|s| s.as_ref())
            .unwrap_or(""),
        params
            .get("recaptcha_token")
            .map(|s| s.as_ref())
            .unwrap_or(""),
    )
}

fn challenge(gt: &str, value: &str, token: &str) -> CoreResult<CaptchaChallenge> {
    if gt.is_empty() || value.is_empty() || token.is_empty() {
        return Err(CoreError::Decode("人机验证参数不完整，请重试".into()));
    }
    Ok(CaptchaChallenge {
        gt: gt.into(),
        challenge: value.into(),
        token: token.into(),
    })
}

fn passport_url(raw: &str) -> CoreResult<url::Url> {
    let url = url::Url::parse(raw).map_err(|_| CoreError::Decode("无效的安全验证地址".into()))?;
    if url.scheme() != "https"
        || url.host_str() != Some("passport.bilibili.com")
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(CoreError::InvalidArgument(
            "安全验证地址不属于哔哩哔哩".into(),
        ));
    }
    Ok(url)
}

fn checked_risk(risk: Option<&PhoneRisk>) -> CoreResult<&PhoneRisk> {
    let risk = risk.ok_or_else(|| CoreError::InvalidArgument("缺少手机号验证上下文".into()))?;
    passport_url(&risk.url)?;
    for field in [&risk.tmp_code, &risk.request_id, &risk.source] {
        require(field, "手机号验证参数不完整")?;
    }
    Ok(risk)
}

fn parse_cookie_header(header: &str) -> CoreResult<Vec<(String, String)>> {
    let mut pairs = Vec::new();
    for segment in header.trim().split(';').filter(|s| !s.trim().is_empty()) {
        let (name, value) = segment.trim().split_once('=').ok_or_else(|| {
            CoreError::InvalidArgument("Cookie 格式应为 name=value; name=value".into())
        })?;
        let name = name.trim();
        if name.is_empty()
            || !name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"_-.".contains(&c))
            || value.bytes().any(|c| c < 0x21 || c >= 0x7f)
            || pairs.iter().any(|(key, _)| key == name)
        {
            return Err(CoreError::InvalidArgument(
                "Cookie 包含无效或重复字段".into(),
            ));
        }
        pairs.push((name.to_owned(), value.to_owned()));
    }
    if !pairs
        .iter()
        .any(|(name, value)| name == "SESSDATA" && !value.is_empty())
    {
        return Err(CoreError::InvalidArgument("Cookie 中缺少 SESSDATA".into()));
    }
    Ok(pairs)
}

fn validate_phone(country: &str, tel: &str) -> CoreResult<()> {
    if country.is_empty()
        || country.len() > 5
        || tel.is_empty()
        || tel.len() > 20
        || !country
            .bytes()
            .chain(tel.bytes())
            .all(|c| c.is_ascii_digit())
    {
        return Err(CoreError::InvalidArgument(
            "请输入有效的国际区号和手机号".into(),
        ));
    }
    Ok(())
}
fn require(value: &str, message: &str) -> CoreResult<()> {
    if value.is_empty() {
        Err(CoreError::InvalidArgument(message.into()))
    } else {
        Ok(())
    }
}
fn str_field<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or("")
}
fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn device_id_matches_upstream_date_and_checksum_layout() {
        let date = time::OffsetDateTime::from_unix_timestamp(0).unwrap();
        let bytes = hex::decode(make_device_id(date)).unwrap();
        assert_eq!(&bytes[16..23], &[0x19, 0x70, 0x01, 0x01, 0, 0, 0]);
        assert_eq!(
            bytes[31],
            bytes[..31]
                .iter()
                .fold(0u8, |sum, byte| sum.wrapping_add(*byte))
        );
    }
    #[test]
    fn cookies_preserve_equals_and_reject_injection() {
        assert_eq!(
            parse_cookie_header(" SESSDATA=a=b==; bili_jct=test ").unwrap()[0].1,
            "a=b=="
        );
        for value in [
            "",
            "bili_jct=x",
            "SESSDATA=x\r\nHost:evil",
            "SESSDATA=a; SESSDATA=b",
        ] {
            assert!(parse_cookie_header(value).is_err());
        }
    }
    #[test]
    fn captcha_requires_official_host_and_all_fields() {
        let path = "/captcha?gee_gt=g&gee_challenge=c&recaptcha_token=t";
        assert!(challenge_from_url(&format!("{PASSPORT}{path}")).is_ok());
        assert!(
            challenge_from_url(&format!("https://passport.bilibili.com.evil.test{path}")).is_err()
        );
        assert!(challenge_from_url(&format!("{PASSPORT}/?gee_gt=g")).is_err());
    }
    #[test]
    fn incomplete_login_is_not_success() {
        assert!(session_from_value(&json!({"status": 2})).is_err());
        let value = json!({"token_info":{"mid":42,"access_token":"test","expires_in":60},
            "cookie_info":{"cookies":[{"name":"SESSDATA","value":"cookie"}]}});
        let session = session_from_value(&value).unwrap();
        assert_eq!(session.mid, 42);
        assert_eq!(session.web_cookies[0].1, "cookie");
    }
    #[test]
    fn encrypts_salted_password_with_server_public_key() {
        use rsa::{pkcs8::EncodePublicKey, RsaPrivateKey};
        let private = RsaPrivateKey::new(&mut rand::thread_rng(), 1024).unwrap();
        let pem = RsaPublicKey::from(&private)
            .to_public_key_pem(Default::default())
            .unwrap();
        let cipher = encrypt(&pem, "salt password ").unwrap();
        let plain = private
            .decrypt(
                Pkcs1v15Encrypt,
                &base64::engine::general_purpose::STANDARD
                    .decode(cipher)
                    .unwrap(),
            )
            .unwrap();
        assert_eq!(plain, b"salt password ");
    }
}
