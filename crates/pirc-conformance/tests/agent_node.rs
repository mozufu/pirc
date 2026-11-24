//! The agent under a real node (features off): a session through the
//! gateway's API with tool calls, so the node's inference socket, write
//! broker and event relay meet the agent.

use pirc_conformance::{
    Cluster, GatewayOptions, Normalizer, Reply, Transcript, WORKSPACE_ID, browser_headers,
};
use serde_json::{Value, json};

fn settled(frame: &Value) -> bool {
    frame["type"] == "pi_event" && frame["data"]["type"] == "agent_settled"
}

#[ignore = "pirc 2: needs a session created through first-send instead of the removed POST /api/sessions; rewritten after M4 (plans/roadmap.md M2.9)"]
#[tokio::test(flavor = "multi_thread")]
async fn agent_under_node() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        agent_core_only: true,
        ..GatewayOptions::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let headers = browser_headers();
    let mut t = Transcript::new(cluster.volatile());
    let created = api
        .send(
            "POST",
            "/api/sessions",
            &headers,
            Some(json!({ "workspaceId": WORKSPACE_ID })),
        )
        .await;
    let id = created.body["session"]["id"].as_str().unwrap().to_owned();
    let session = format!("/api/sessions/{id}");
    let acquired = api
        .send(
            "POST",
            &format!("{session}/control/acquire"),
            &headers,
            Some(json!({ "clientId": "browser" })),
        )
        .await;
    let generation = acquired.body["lease"]["generation"].clone();
    let before = api
        .send("GET", &format!("{session}/snapshot"), &headers, None)
        .await;
    let watermark = &before.body["watermark"];
    let cursor = format!("{}:{}", watermark["epoch"], watermark["sequence"]);
    let mut live = api
        .connect(
            &format!("/api/events?sessionId={id}&cursor={cursor}"),
            &headers,
        )
        .await
        .open();
    cluster.llm.push([
        Reply::Tool {
            id: "w1".to_owned(),
            name: "write".to_owned(),
            args: json!({ "path": "notes.txt", "content": "from the agent\n" }),
        },
        Reply::Tool {
            id: "r1".to_owned(),
            name: "read".to_owned(),
            args: json!({ "path": "notes.txt" }),
        },
        // Not bash: the cluster runs agents with the host's /bin/bash,
        // which some machines (NixOS) lack.
        Reply::Tool {
            id: "e1".to_owned(),
            name: "edit".to_owned(),
            args: json!({ "path": "notes.txt", "oldText": "from", "newText": "edited by" }),
        },
        Reply::Text("All done.".to_owned()),
    ]);
    let sent = api
        .send(
            "POST",
            &format!("{session}/commands"),
            &headers,
            Some(
                json!({ "commandId": "c1", "clientId": "browser", "generation": generation,
                "payload": { "type": "prompt", "message": "Write, read and edit" } }),
            ),
        )
        .await;
    t.response("prompt", "POST /api/sessions/:id/commands", &sent);
    let events = live.until(settled).await;
    live.close().await;
    let events: Vec<Value> = events
        .into_iter()
        .filter(|frame| frame["type"] == "pi_event")
        .map(|frame| frame["data"].clone())
        .collect();
    t.note(
        "agent events",
        Normalizer::new(cluster.volatile()).value(&json!(events)),
    );
    let requests: Vec<Value> = cluster
        .llm
        .requests()
        .into_iter()
        .map(|request| {
            json!({ "messages": request["messages"], "tools": request["tools"]
            .as_array().map(|tools| tools.iter().map(|t| t["function"]["name"].clone())
            .collect::<Vec<_>>()) })
        })
        .collect();
    t.note("model requests (messages and tool names)", json!(requests));
    let after = api
        .send("GET", &format!("{session}/snapshot"), &headers, None)
        .await;
    t.note("history after the run", after.body["history"].clone());
    let content =
        std::fs::read_to_string(cluster.dir.path().join("workspace/notes.txt")).unwrap_or_default();
    t.note("the written file", json!(content));
    insta::assert_json_snapshot!("agent_under_node", t.into_value());
}
