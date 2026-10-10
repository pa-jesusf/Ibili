//! Interactive story nodes are distinct from the archive's ordinary page list.
use crate::{Core, CoreError, CoreResult};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct InteractiveInfo {
    pub graph_version: i64,
    pub history_node: Option<InteractiveHistoryNode>,
    pub msg: String,
    pub need_reload: i64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct InteractiveHistoryNode {
    pub node_id: i64,
    pub cid: i64,
    pub title: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct InteractiveNode {
    pub edge_id: i64,
    pub title: String,
    pub is_leaf: i64,
    #[serde(deserialize_with = "null_default")]
    pub no_backtracking: i64,
    #[serde(deserialize_with = "null_default")]
    pub story_list: Vec<InteractiveStory>,
    #[serde(deserialize_with = "null_default")]
    pub hidden_vars: Vec<InteractiveVariable>,
    #[serde(deserialize_with = "null_default")]
    pub edges: InteractiveEdges,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct InteractiveStory {
    pub edge_id: i64,
    pub cid: i64,
    pub title: String,
    pub start_pos: i64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct InteractiveEdges {
    #[serde(deserialize_with = "null_default")]
    pub questions: Vec<InteractiveQuestion>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct InteractiveQuestion {
    pub id: i64,
    #[serde(rename = "type")]
    pub kind: i64,
    pub start_time: i64,
    pub start_time_r: i64,
    pub duration: i64,
    pub pause_video: i64,
    pub title: String,
    #[serde(deserialize_with = "null_default")]
    pub choices: Vec<InteractiveChoice>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct InteractiveChoice {
    pub id: i64,
    pub cid: i64,
    pub option: String,
    pub condition: String,
    pub native_action: String,
    pub platform_action: String,
    #[serde(deserialize_with = "null_default")]
    pub is_default: i64,
    #[serde(deserialize_with = "null_default")]
    pub is_hidden: i64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct InteractiveVariable {
    pub id: String,
    pub id_v2: String,
    #[serde(rename = "type")]
    pub kind: i64,
    pub name: String,
    pub value: f64,
    pub is_show: i64,
}

fn null_default<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(d)?.unwrap_or_default())
}

impl Core {
    pub fn video_interactive_node(
        &self,
        bvid: &str,
        graph_version: i64,
        edge_id: i64,
        choices: &[i64],
        portal: i64,
    ) -> CoreResult<InteractiveNode> {
        if bvid.len() != 12
            || !bvid.starts_with("BV")
            || !bvid.bytes().all(|c| c.is_ascii_alphanumeric())
            || graph_version <= 0
            || edge_id < 0
            || choices.len() > 128
            || choices.iter().any(|id| *id <= 0)
            || !(0..=1).contains(&portal)
        {
            return Err(CoreError::InvalidArgument(
                "invalid interactive node request".into(),
            ));
        }
        // Matches the public web player's node transition protocol. `choices`
        // contains mid-video decisions; the destination itself is `edge_id`.
        let params = vec![
            ("bvid".into(), bvid.to_owned()),
            ("graph_version".into(), graph_version.to_string()),
            ("edge_id".into(), edge_id.to_string()),
            ("platform".into(), "pc".into()),
            ("portal".into(), portal.to_string()),
            ("screen".into(), "0".into()),
            (
                "choices".into(),
                choices
                    .iter()
                    .map(i64::to_string)
                    .collect::<Vec<_>>()
                    .join(","),
            ),
        ];
        let node: InteractiveNode = self
            .http
            .get_web("https://api.bilibili.com/x/stein/edgeinfo_v2", &params)?;
        if node.edge_id <= 0 || (edge_id > 0 && node.edge_id != edge_id) {
            return Err(CoreError::Decode(
                "interactive node identity mismatch".into(),
            ));
        }
        Ok(node)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn story_choices_keep_graph_ids_separate_from_cids() {
        let node: InteractiveNode = serde_json::from_str(r#"{"edge_id":1,"hidden_vars":[{"id_v2":"$loop","value":1,"type":1}],"edges":{"questions":[{"type":2,"duration":-1,"choices":[{"id":22453494,"cid":245681715,"option":"继续","condition":"$loop>=1","native_action":"$loop=$loop+1","is_default":null}]}]}}"#).unwrap();
        let c = &node.edges.questions[0].choices[0];
        assert_eq!(c.id, 22453494);
        assert_eq!(c.cid, 245681715);
        assert_eq!(c.native_action, "$loop=$loop+1");
        assert_eq!(node.hidden_vars[0].value, 1.0);
    }
    #[test]
    fn leaf_accepts_missing_or_null_edges() {
        for json in [
            r#"{"edge_id":5,"is_leaf":1}"#,
            r#"{"edge_id":5,"is_leaf":1,"edges":null,"hidden_vars":null,"no_backtracking":null}"#,
        ] {
            let n: InteractiveNode = serde_json::from_str(json).unwrap();
            assert!(n.edges.questions.is_empty());
        }
    }
}
