//! Editing is a durable branch operation, not an in-place transcript rewrite.
mod node_sessions_support;

use node_sessions_support::{HeldLlm, Session, Step, held_cluster};
use pirc_conformance::GatewayOptions;
use serde_json::{Value, json};

fn text(message: &Value) -> String {
    match &message["content"] {
        Value::String(text) => text.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|block| block["text"].as_str())
            .collect(),
        _ => String::new(),
    }
}

fn history(snapshot: &Value) -> Vec<String> {
    snapshot["history"]
        .as_array()
        .unwrap()
        .iter()
        .map(text)
        .collect()
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn edited_messages_preserve_switchable_history_and_model_context() {
    let llm = HeldLlm::start().await;
    llm.push([Step::text("original answer"), Step::text("edited answer")]);
    let models = tempfile::tempdir().unwrap();
    let Some(cluster) = held_cluster(&llm, models.path(), GatewayOptions::default()).await else {
        return;
    };
    let (mut session, _) = Session::create(&cluster.api()).await;
    session.acquire().await;
    let response = session
        .command(json!({"type":"prompt", "message":"original question"}))
        .await;
    assert_eq!(
        response.body["command"]["status"], "accepted",
        "{response:?}"
    );
    let original = session
        .snapshot_until("original reply", |snapshot| {
            history(snapshot).contains(&"original answer".to_owned())
                && snapshot["run"]["status"] == "succeeded"
        })
        .await;
    let original_id = original.body["history"][0]["entryId"]
        .as_str()
        .unwrap()
        .to_owned();
    let response = session
        .command(
            json!({"type":"edit_message", "entryId": original_id, "message":"edited question"}),
        )
        .await;
    assert_eq!(
        response.body["command"]["status"], "accepted",
        "{response:?}"
    );
    let edited = session
        .snapshot_until("edited reply", |snapshot| {
            history(snapshot).contains(&"edited answer".to_owned())
                && snapshot["run"]["status"] == "succeeded"
        })
        .await;
    assert_eq!(history(&edited.body), ["edited question", "edited answer"]);
    let edited_id = edited.body["history"][0]["entryId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_ne!(edited_id, original_id);
    assert_eq!(
        edited.body["history"][0]["branches"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    let requests = llm.requests();
    let request = requests.last().unwrap();
    let messages = request["messages"].as_array().unwrap();
    let context: Vec<_> = messages
        .iter()
        .filter(|m| m["role"] == "user" || m["role"] == "assistant")
        .map(text)
        .collect();
    assert_eq!(context, ["edited question"]);

    let response = session
        .command(json!({"type":"switch_branch", "entryId": original_id}))
        .await;
    assert_eq!(
        response.body["command"]["status"], "accepted",
        "{response:?}"
    );
    let restored = session.snapshot().await;
    assert_eq!(
        history(&restored.body),
        ["original question", "original answer"]
    );
    let response = session
        .command(json!({"type":"switch_branch", "entryId": edited_id}))
        .await;
    assert_eq!(
        response.body["command"]["status"], "accepted",
        "{response:?}"
    );
    assert_eq!(
        history(&session.snapshot().await.body),
        ["edited question", "edited answer"]
    );
    assert_eq!(
        llm.requests().len(),
        2,
        "switching branches must not invoke the model"
    );

    // Branch targets are user messages, never arbitrary paths or missing IDs.
    let response = session
        .command(json!({"type":"switch_branch", "entryId":"does-not-exist"}))
        .await;
    assert_ne!(response.body["command"]["status"], "accepted");
    assert_eq!(
        history(&session.snapshot().await.body),
        ["edited question", "edited answer"]
    );
}
