//! Public source lookup carries replay provenance through PTC stores and restarts.
use pirc_conformance::{AgentOptions, AgentRun, ModelReply};
use serde_json::{Value, json};
fn options() -> AgentOptions {
    AgentOptions {
        env: vec![("PIRC_GATEWAY".into(), "1".into())],
        ..Default::default()
    }
    .features("observational-memory")
}
async fn script(agent: &mut AgentRun, code: &str) {
    agent.push([
        ModelReply::tool("script", "ptc", json!({"code":code})),
        ModelReply::Text("Done".into()),
    ]);
    assert_eq!(
        agent
            .call(json!({"type":"prompt","message":"Look up earlier evidence"}))
            .await["success"],
        true
    );
    agent.settle().await;
}
fn ptc_result(entries: &[Value]) -> &Value {
    entries
        .iter()
        .rev()
        .find(|e| e["message"]["role"] == "toolResult" && e["message"]["toolName"] == "ptc")
        .unwrap()
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn history_replay_taint_survives_ptc_store_and_process_restart() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    agent.answers.lock().unwrap().gateway.insert("history.search".into(),json!({"ok":true,"result":{"sources":[{"entryId":"evidence","role":"user","text":"Earlier source"}],"cursor":null,"memoryReplay":true,"limitations":"Public text"}}));
    script(&mut agent,"const result = await tools.history_search({query:'earlier'}); store('evidence',result); return 'Stored';").await;
    let entries = agent.session_entries();
    assert!(entries.iter().any(|e| {
        e["customType"] == "ptc.store"
            && e["data"]["untrusted"]
                .as_array()
                .is_some_and(|a| a.contains(&json!("history_search")))
    }));
    assert_eq!(
        ptc_result(&entries)["message"]["details"]["memoryReplay"],
        true
    );
    let Some(mut agent) = agent.restart(options()).await else {
        panic!("restart failed")
    };
    script(&mut agent, "return load('evidence');").await;
    assert_eq!(
        ptc_result(&agent.session_entries())["message"]["details"]["memoryReplay"],
        true
    );
}
