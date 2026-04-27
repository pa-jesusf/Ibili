use crate::Core;
use crate::dto::{FeedItem, FeedPage};
use crate::error::{CoreError, CoreResult};
use serde::Deserialize;

const URL_FEED_INDEX: &str = "https://app.bilibili.com/x/v2/feed/index";

#[derive(Deserialize)]
struct FeedRoot {
    #[serde(default)]
    items: Vec<FeedRawItem>,
}

#[derive(Deserialize)]
struct FeedRawItem {
    #[serde(default)] card_type: String,
    #[serde(default)] card_goto: String,
    #[serde(default)] goto: String,
    #[serde(default)] param: String,
    #[serde(default)] bvid: String,
    #[serde(default)] title: String,
    #[serde(default)] cover: String,
    #[serde(default)] cover_left_text_1: String,
    #[serde(default)] desc_button: Option<serde_json::Value>,
    #[serde(default)] args: FeedArgs,
    #[serde(default)] talk_back: String,
    #[serde(default)] mask: Option<MaskWrap>,
    #[serde(default)] player_args: Option<PlayerArgs>,
}

#[derive(Deserialize, Default)]
struct FeedArgs {
    #[serde(default)] aid: i64,
    #[serde(default)] up_id: i64,
    #[serde(default)] up_name: String,
}

#[derive(Deserialize, Default)]
struct MaskWrap {
    #[serde(default)] avatar: Option<Avatar>,
}
#[derive(Deserialize, Default)]
struct Avatar { #[serde(default)] text: String }

#[derive(Deserialize, Default)]
struct PlayerArgs {
    #[serde(default)] aid: i64,
    #[serde(default)] cid: i64,
    #[serde(default)] duration: i64,
}

impl Core {
    pub fn feed_home(&self, idx: i64, ps: i64) -> CoreResult<FeedPage> {
        let access_key = self.session.read().access_key()
            .ok_or(CoreError::AuthRequired)?;
        let params = vec![
            ("access_key".into(), access_key),
            ("build".into(), "2001100".into()),
            ("c_locale".into(), "zh_CN".into()),
            ("channel".into(), "master".into()),
            ("device".into(), "phone".into()),
            ("idx".into(), idx.to_string()),
            ("mobi_app".into(), "android".into()),
            ("platform".into(), "android".into()),
            ("ps".into(), ps.to_string()),
            ("s_locale".into(), "zh_CN".into()),
            ("statistics".into(), r#"{"appId":1,"platform":3,"version":"7.39.0","abtest":""}"#.into()),
        ];
        let raw: FeedRoot = self.http.get_signed_app(URL_FEED_INDEX, params)?;
        let items = raw.items.into_iter()
            .filter(|i| matches!(i.goto.as_str(), "av" | "bangumi") || i.card_goto == "av")
            .filter_map(|i| {
                let pa = i.player_args.as_ref()?;
                if pa.aid == 0 { return None; }
                Some(FeedItem {
                    aid: pa.aid,
                    bvid: i.bvid,
                    cid: pa.cid,
                    title: i.title,
                    cover: i.cover,
                    author: i.mask.as_ref().and_then(|m| m.avatar.as_ref()).map(|a| a.text.clone())
                        .unwrap_or_else(|| i.args.up_name.clone()),
                    duration_sec: pa.duration,
                    play: 0,
                    danmaku: 0,
                })
            })
            .collect();
        Ok(FeedPage { items })
    }
}
