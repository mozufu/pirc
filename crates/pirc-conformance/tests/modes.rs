//! A custom mode through a real gateway, node and agent. Assertion-based so
//! this security scenario does not depend on platform-specific snapshots.

use pirc_conformance::{Cluster, FirstSend, GatewayOptions, Reply, browser_headers};
use pirc_protocol::mode::{AssistantAccess, ModeId, PromptSection, ScheduleScope, default_chat};
use serde_json::{Value, json};
use std::time::Duration;

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn custom_mode_catalog_prompt_capabilities_and_removal() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        agent_core_only: true,
        node_env: vec![("PIRC_MODES", "directory,research".into())],
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let headers = browser_headers();
    let dir = cluster.dir.path().join("gateway-config/modes");
    let mut mode = default_chat();
    mode.id = ModeId::new("research").unwrap();
    mode.label = "Research".into();
    mode.assistant = AssistantAccess::User;
    mode.delegate = false;
    mode.schedule_scope = ScheduleScope::Own;
    mode.project_files = false;
    mode.project_instructions = false;
    mode.prompt = vec![PromptSection::Body];
    mode.body = "CUSTOM-MODE-PROMPT-SECTION".into();
    mode.tools = Some(vec!["read".into()]);
    mode.validate().unwrap();
    let mut meta = serde_json::to_value(&mode).unwrap();
    meta.as_object_mut().unwrap().remove("id");
    meta.as_object_mut().unwrap().remove("body");
    std::fs::write(
        dir.join("research.md"),
        format!("---\n{}\n---\n{}\n", meta, mode.body),
    )
    .unwrap();
    std::fs::write(dir.join("broken.md"), "---\nlabel: [\n---\n").unwrap();
    cluster.reload_gateway();
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            let response = api.send("GET", "/api/modes", &headers, None).await;
            if response
                .body
                .to_string()
                .contains("CUSTOM-MODE-PROMPT-SECTION")
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .expect("catalog reload");
    assert!(cluster.gateway_log().contains("broken.md"));

    let workspace = api.send("POST", "/api/workspaces", &headers,
        Some(json!({"nodeId":pirc_conformance::NODE_ID,"mode":"research","displayName":"Research"}))).await;
    assert_eq!(workspace.status, 201, "{}", workspace.body);
    assert_eq!(workspace.body["workspace"]["kind"], "chat");
    assert_eq!(workspace.body["workspace"]["mode"], "research");
    let workspace_id = workspace.body["workspace"]["id"].as_str().unwrap();
    let started = FirstSend::new(&api, &headers)
        .workspace(workspace_id)
        .start_idle()
        .await;
    let id = &started.id;
    let base = started.base;
    let acquired = api
        .send(
            "POST",
            &format!("{base}/control/acquire"),
            &headers,
            Some(json!({"clientId":"modes-test"})),
        )
        .await;
    assert_eq!(acquired.status, 200, "{}", acquired.body);
    let generation = acquired.body["lease"]["generation"].clone();
    let binding = api
        .send("GET", &format!("{base}/environment"), &headers, None)
        .await
        .body["binding"]
        .clone();
    let mut live = api
        .connect(&format!("/api/events?sessionId={id}"), &headers)
        .await
        .open();
    cluster.llm.push([Reply::Text("Mode verified.".into())]);
    let command = |command_id: &str| {
        json!({"commandId":command_id,"clientId":"modes-test",
        "generation":generation,"expectedBinding":binding.clone(),
        "payload":{"type":"prompt","message":"Check the custom mode"}})
    };
    let sent = api
        .send(
            "POST",
            &format!("{base}/commands"),
            &headers,
            Some(command("mode-first")),
        )
        .await;
    assert_eq!(sent.status, 202, "{}", sent.body);
    live.until(|event| event["type"] == "pi_event" && event["data"]["type"] == "agent_settled")
        .await;
    live.close().await;
    let requests = cluster.llm.requests();
    assert!(
        requests
            .iter()
            .any(|request| request["messages"].to_string().contains(&mode.body))
    );
    for request in &requests {
        if let Some(tools) = request["tools"].as_array() {
            let names: Vec<_> = tools
                .iter()
                .filter_map(|tool| tool["function"]["name"].as_str())
                .collect();
            assert!(
                !names.contains(&"bash"),
                "restricted mode exposed bash: {names:?}"
            );
        }
    }
    // A browser cannot invoke a capability simply because this mode uses a
    // per-session working directory like Chat.
    let files = api
        .send(
            "GET",
            &format!("/api/workspaces/{workspace_id}/files"),
            &headers,
            None,
        )
        .await;
    assert!((400..500).contains(&files.status), "{}", files.body);

    std::fs::remove_file(dir.join("research.md")).unwrap();
    cluster.reload_gateway();
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            let workspaces = api.send("GET", "/api/workspaces", &headers, None).await;
            let unavailable = workspaces.body["workspaces"]
                .as_array()
                .is_some_and(|items| {
                    items.iter().any(|item| {
                        item["id"] == workspace_id && item["available"] == Value::Bool(false)
                    })
                });
            if unavailable {
                break;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .expect("workspace unavailable after mode removal");
    let denied = api
        .send(
            "POST",
            &format!("{base}/commands"),
            &headers,
            Some(command("mode-removed")),
        )
        .await;
    assert_eq!(denied.status, 409, "{}", denied.body);
    let stopped = api
        .send(
            "POST",
            &format!("{base}/commands"),
            &headers,
            Some(json!({
                "commandId":"mode-stop", "clientId":"modes-test", "generation":generation,
                "payload":{"type":"stop"}
            })),
        )
        .await;
    // Reload may already have stopped the runner; Stop must pass the mode
    // guard without trying to start a replacement in an unavailable mode.
    assert!(matches!(stopped.status, 202 | 503), "{}", stopped.body);
    if stopped.status == 503 {
        assert_eq!(stopped.body["error"]["code"], "runner_unavailable");
    }
    let history = api
        .send("GET", &format!("{base}/snapshot"), &headers, None)
        .await;
    assert_eq!(history.status, 200, "{}", history.body);
    let denied = api
        .send(
            "POST",
            "/api/conversation-submissions/prepare",
            &headers,
            Some(json!({"operationId": "removed-mode", "submission": {
                "workspaceId": workspace_id, "message": "Hello" }})),
        )
        .await;
    assert!(
        matches!(denied.status, 404 | 409),
        "{} {}",
        denied.status,
        denied.body
    );
}
