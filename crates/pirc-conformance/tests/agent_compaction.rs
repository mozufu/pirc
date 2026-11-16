//! Native handoff integration: real process, persistence and inference transport.
use pirc_conformance::{AgentOptions, AgentRun, ModelReply};
use serde_json::{Value, json};
fn options() -> AgentOptions {
    AgentOptions {
        config: json!({"features":{"compaction":{"keepRecentTokens":1,"warmCache":false}}}),
        ..Default::default()
    }
}
async fn turn(agent: &mut AgentRun, text: &str) {
    assert_eq!(
        agent.call(json!({"type":"prompt","message":text})).await["success"],
        true
    );
    agent.settle().await;
}
fn handoff() -> ModelReply {
    ModelReply::computed(|body| {
        let content = &body["messages"][0]["content"];
        let payload: Value = serde_json::from_str(content.as_str().unwrap()).unwrap();
        let source = &payload["sources"][0];
        ModelReply::Text(json!({"state":{"goal":[{"text":"Continue the repository task","sources":[{"sessionId":source["sessionId"],"entryId":source["entryId"]}]}],"activeConstraints":[],"progress":[],"decisions":[],"openQuestions":[],"nextSteps":[]},"resolvedConstraints":[]}).to_string())
    })
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn native_manual_handoff_is_atomic_and_raw_sources_survive_restart() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    agent.push([ModelReply::Text("First answer".into())]);
    turn(&mut agent, &"Original raw context ".repeat(500)).await;
    agent.push([ModelReply::Text("Second answer".into())]);
    turn(&mut agent, "Continue").await;
    agent.push([handoff()]);
    let compacted = agent.call(json!({"type":"compact"})).await;
    assert_eq!(compacted["success"], true, "{compacted}");
    let entries = agent.session_entries();
    assert_eq!(
        entries.iter().filter(|e| e["type"] == "compaction").count(),
        1
    );
    assert!(entries.iter().any(|e| {
        e["message"]["content"]
            .as_str()
            .is_some_and(|s| s.contains("Original raw context"))
    }));
    let old = entries
        .iter()
        .find(|e| e["type"] == "compaction")
        .unwrap()
        .clone();
    let Some(mut agent) = agent.restart(options()).await else {
        panic!("restart failed")
    };
    agent.push([ModelReply::Text("After restart".into())]);
    turn(&mut agent, "Resume").await;
    assert!(agent.session_entries().contains(&old));
    assert!(!agent.take_requests().is_empty());
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn native_invalid_handoff_never_replaces_raw_context() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    agent.push([ModelReply::Text("Ready".into())]);
    turn(&mut agent, &"Original source ".repeat(500)).await;
    agent.push([ModelReply::Text("Next".into())]);
    turn(&mut agent, "Continue").await;
    let before = agent
        .session_entries()
        .iter()
        .filter(|e| e["type"] == "message")
        .cloned()
        .collect::<Vec<_>>();
    agent.push([ModelReply::Text("invalid structured output".into())]);
    let result = agent.call(json!({"type":"compact"})).await;
    assert_eq!(result["success"], false);
    let after = agent.session_entries();
    assert!(!after.iter().any(|e| e["type"] == "compaction"));
    assert_eq!(
        before,
        after
            .into_iter()
            .filter(|e| e["type"] == "message")
            .collect::<Vec<_>>()
    );
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn native_overflow_uses_the_same_handoff_engine_once() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    agent.push([ModelReply::Text("Ready".into())]);
    turn(&mut agent, &"Original source ".repeat(500)).await;
    agent.push([
        ModelReply::Failed("context length exceeded".into()),
        handoff(),
        ModelReply::Text("Recovered".into()),
    ]);
    turn(&mut agent, "Continue after overflow").await;
    let entries = agent.session_entries();
    assert_eq!(
        entries
            .iter()
            .filter(|e| e["type"] == "compaction" && e["details"]["kind"] == "handoff")
            .count(),
        1
    );
    assert!(entries.iter().any(|e| {
        e["message"]["content"]
            .as_array()
            .is_some_and(|a| a.iter().any(|p| p["text"] == "Recovered"))
    }));
}
