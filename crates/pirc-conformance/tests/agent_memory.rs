//! Retired OM settings remain compatible; source lookup and Work blocks are independent.
use pirc_conformance::{AgentOptions, AgentRun, ModelReply};
use serde_json::{Value, json};
use std::time::Duration;
async fn turn(agent: &mut AgentRun, text: &str) {
    agent.push([ModelReply::Text("Done".into())]);
    assert_eq!(
        agent.call(json!({"type":"prompt","message":text})).await["success"],
        true
    );
    agent.settle().await;
    agent.drain(Duration::from_millis(50)).await;
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn work_notes_refresh_and_disappear_on_revocation_without_activating_a_ledger() {
    let options = AgentOptions {
        env: vec![("PIRC_GATEWAY".into(), "1".into())],
        ..Default::default()
    }
    .features("workspace-memory");
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    {
        let mut answers = agent.answers.lock().unwrap();
        answers.gateway_queue.insert("workspace.context".into(),[json!({"ok":true,"result":{"items":[{"id":"aaaaaaaaaaaa","content":"Legacy repository knowledge"}],"legacy":true}}),json!({"ok":false,"error":{"code":"forbidden","message":"Owner changed","status":403}})].into());
        answers.gateway.insert("workspace.next".into(),json!({"ok":false,"error":{"code":"workspace_cold_cutover_required","message":"Cold cutover required","status":409}}));
    }
    turn(&mut agent, "First").await;
    let first = agent.take_requests();
    assert!(
        first[0]["systemPrompt"]
            .as_str()
            .unwrap()
            .contains("Legacy repository knowledge")
    );
    turn(&mut agent, "After revocation").await;
    let second = agent.take_requests();
    assert!(
        !second[0]["systemPrompt"]
            .as_str()
            .unwrap()
            .contains("Legacy repository knowledge")
    );
    assert!(
        second[0]["systemPrompt"]
            .as_str()
            .unwrap()
            .contains("unavailable")
    );
    assert!(
        !agent
            .session_entries()
            .iter()
            .any(|e| e["customType"] == "om.workspace.snapshot")
    );
}
// Keep type imports checked alongside the feature's wire fixture shape.
const _: fn(Value) -> Value = |v| v;
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn independent_extraction_uses_one_call_and_rate_limit_falls_back_on_the_next_sync() {
    let options=AgentOptions{env:vec![("PIRC_GATEWAY".into(),"1".into())],config:json!({"features":{"workspaceMemory":{"model":{"provider":"fake","id":"small-model"},"fallbackModels":[{"provider":"fake","id":"fake-model"}]}}}),..Default::default()}.features("workspace-memory");
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    let job = json!({"jobId":"job","control":{"epoch":"epoch","generation":"generation","revision":1},"sessionId":"original","fromEntryId":"evidence","throughEntryId":"end","sourceHash":"f".repeat(64),"sources":[{"sessionId":"original","entryId":"evidence","role":"user","text":"Use SQLite for this repository","derived":false}],"catchup":false});
    {
        let mut answers = agent.answers.lock().unwrap();
        answers.gateway.insert(
            "workspace.context".into(),
            json!({"ok":true,"result":{"legacy":false,"items":[]}}),
        );
        answers.gateway.insert(
            "workspace.commit".into(),
            json!({"ok":true,"result":{"committed":true}}),
        );
        answers.gateway_queue.insert(
            "workspace.next".into(),
            [
                json!({"ok":true,"result":job.clone()}),
                json!({"ok":true,"result":job}),
                json!({"ok":true,"result":null}),
            ]
            .into(),
        );
    }
    agent.push([
        ModelReply::Text("Main reply".into()),
        ModelReply::Failed("HTTP 429 rate limit".into()),
    ]);
    agent.call(json!({"type":"prompt","message":"First"})).await;
    agent.settle().await;
    agent.drain(Duration::from_millis(300)).await;
    let first = agent.take_requests();
    assert_eq!(first.len(), 2);
    assert_eq!(first[1]["modelId"], "small-model");
    agent.push([ModelReply::Text("Second reply".into()),ModelReply::Text(json!({"items":[{"content":"Use SQLite","sources":[{"sessionId":"original","entryId":"evidence"}]}],"retire":[]}).to_string())]);
    agent
        .call(json!({"type":"prompt","message":"Second"}))
        .await;
    agent.settle().await;
    let events = agent.drain(Duration::from_millis(300)).await;
    let requests = agent.take_requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[1]["modelId"], "fake-model");
    assert!(
        events.iter().any(|e| e["op"] == "workspace.commit"),
        "{events:?}"
    );
    assert!(
        !agent
            .session_entries()
            .iter()
            .any(|e| e["type"] == "compaction" || e["customType"] == "om.observations.recorded")
    );
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn rejected_retirement_recovers_but_ambiguous_postcommit_failure_stays_withheld() {
    for code in [
        "workspace_invalid_retirement",
        "workspace_source_blocked",
        "forbidden",
    ] {
        let options = AgentOptions {
            env: vec![("PIRC_GATEWAY".into(), "1".into())],
            ..Default::default()
        }
        .features("workspace-memory");
        let Some(mut agent) = AgentRun::start(options).await else {
            return;
        };
        let job = json!({"jobId":"original_job","control":{"epoch":"e","generation":"g","revision":1},"sessionId":"s","fromEntryId":"a","throughEntryId":"b","sourceHash":"f".repeat(64),"sources":[{"sessionId":"s","entryId":"a","role":"user","text":"verified convention","derived":false}],"catchup":false});
        {
            let mut answers = agent.answers.lock().unwrap();
            answers.gateway.insert("workspace.context".into(),json!({"ok":true,"result":{"items":[{"id":"aaaaaaaaaaaa","content":"Existing authorized knowledge"}]}}));
            answers.gateway_queue.insert(
                "workspace.next".into(),
                [
                    json!({"ok":true,"result":job.clone()}),
                    json!({"ok":true,"result":job}),
                    json!({"ok":true,"result":null}),
                ]
                .into(),
            );
            answers.gateway_queue.insert("workspace.commit".into(),[json!({"ok":false,"error":{"code":code,"message":"rejected or delivery revoked","status":409}}),json!({"ok":true,"result":{"committed":true}})].into());
        }
        agent.push([
            ModelReply::Text("First".into()),
            ModelReply::Text("{\"items\":[],\"retire\":[]}".into()),
        ]);
        agent.call(json!({"type":"prompt","message":"First"})).await;
        agent.settle().await;
        agent.drain(Duration::from_millis(100)).await;
        agent.take_requests();
        agent.push([
            ModelReply::Text("Second".into()),
            ModelReply::Text("{\"items\":[],\"retire\":[]}".into()),
        ]);
        agent
            .call(json!({"type":"prompt","message":"Second"}))
            .await;
        agent.settle().await;
        let events = agent.drain(Duration::from_millis(100)).await;
        let requests = agent.take_requests();
        let shown = requests[0]["systemPrompt"]
            .as_str()
            .unwrap()
            .contains("Existing authorized knowledge");
        assert_eq!(shown, code != "forbidden", "{code}: {requests:?}");
        assert_eq!(
            events.iter().any(|e| e["op"] == "workspace.commit"),
            code != "forbidden"
        );
    }
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn blocked_sources_are_visible_without_claiming_extraction_or_starting_retries() {
    let options = AgentOptions {
        env: vec![("PIRC_GATEWAY".into(), "1".into())],
        config: json!({"features":{"workspaceMemory":{"passive":true}}}),
        ..Default::default()
    }
    .features("workspace-memory");
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    let message = "Repository memory extraction is blocked for some sources: tool provenance is incomplete or ambiguous.";
    agent.answers.lock().unwrap().gateway.insert("workspace.next".into(),json!({"ok":false,"error":{"status":409,"code":"workspace_source_blocked","message":message}}));
    let id = agent
        .command(json!({"type":"prompt","message":"/om:workspace sync"}))
        .await;
    let mut answered = false;
    let mut notified = false;
    let mut next_requests = 0;
    while !answered || !notified {
        let event = agent
            .next()
            .await
            .expect("agent exited before reporting blocked sources");
        answered |= event["type"] == "response" && event["id"] == id;
        if event["op"] == "workspace.next" {
            next_requests += 1;
        }
        if event["type"] == "extension_ui_request" && event["method"] == "notify" {
            assert_eq!(event["notifyType"], "error");
            assert_eq!(event["message"], message);
            notified = true;
        }
        assert_ne!(event["op"], "workspace.commit");
    }
    assert_eq!(next_requests, 1);
    let panel = agent.call(json!({"type":"get_panel_state"})).await;
    assert_eq!(
        panel["data"]["workspaceMemory"]["errors"]["extraction"],
        message
    );
    assert_eq!(panel["data"]["workspaceMemory"]["pendingMutations"], 0);
    assert!(agent.take_requests().is_empty());
    assert!(
        !agent
            .session_entries()
            .iter()
            .any(|e| e["type"] == "compaction")
    );
    agent.finish().await;
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn cold_cutover_state_is_visible_and_manual_sync_never_claims_success_before_activation() {
    let Some(mut agent) = AgentRun::start(
        AgentOptions {
            env: vec![("PIRC_GATEWAY".into(), "1".into())],
            ..Default::default()
        }
        .features("workspace-memory"),
    )
    .await
    else {
        return;
    };
    {
        let mut answers = agent.answers.lock().unwrap();
        answers.gateway.insert(
            "workspace.context".into(),
            json!({"ok":true,"result":{"legacy":true,"items":[]}}),
        );
        answers.gateway.insert("workspace.next".into(), json!({"ok":false,"error":{"code":"workspace_cold_cutover_required","message":"Cold cutover required","status":409}}));
    }
    turn(&mut agent, "First ordinary conversation before activation").await;
    let panel = agent.call(json!({"type":"get_panel_state"})).await;
    assert_eq!(
        panel["data"]["workspaceMemory"]["writeState"],
        "cutover_required"
    );
    for action in ["sync", "catchup"] {
        agent
            .command(json!({"type":"prompt","message":format!("/om:workspace {action}")}))
            .await;
        let events = agent.drain(Duration::from_millis(300)).await;
        assert!(
            events.iter().any(|e| e["method"] == "notify"
                && e["message"]
                    .as_str()
                    .is_some_and(|s| s.contains("writing is not activated")
                        && s.contains("--writers-stopped"))),
            "{events:?}"
        );
        assert!(!events.iter().any(|e| {
            e["message"]
                .as_str()
                .is_some_and(|s| s.contains("0 complete interactions committed"))
        }));
        assert!(
            !events
                .iter()
                .any(|e| e["op"] == "workspace.commit" || e["op"] == "workspace.cold")
        );
    }
    {
        let mut answers = agent.answers.lock().unwrap();
        answers.gateway.insert(
            "workspace.context".into(),
            json!({"ok":true,"result":{"legacy":false,"items":[]}}),
        );
        answers
            .gateway
            .insert("workspace.next".into(), json!({"ok":true,"result":null}));
    }
    turn(
        &mut agent,
        "After an administrator activated this repository",
    )
    .await;
    let panel = agent.call(json!({"type":"get_panel_state"})).await;
    assert_eq!(panel["data"]["workspaceMemory"]["writeState"], "active");
    assert_eq!(panel["data"]["workspaceMemory"]["errors"], json!({}));
}
