//! A session's life through the browser API, with the real agent answering
//! from the fake model.
//!
//! `session_lifecycle` records what the gateway itself is responsible for:
//! routes, leases, commands, the event envelope, replay and resets. The
//! agent's own event stream (widgets, panels, deltas) is recorded separately
//! in `session_agent_events`, the parity target of the agent port.

use pirc_conformance::{
    Cluster, GatewayOptions, Normalizer, Reply, Transcript, WORKSPACE_ID, browser_headers,
};
use std::collections::BTreeSet;

use serde_json::{Value, json};

fn settled(frame: &Value) -> bool {
    frame["type"] == "pi_event" && frame["data"]["type"] == "agent_settled"
}

fn cursor(watermark: &Value) -> String {
    format!("{}:{}", watermark["epoch"], watermark["sequence"])
}

#[ignore = "pirc 2: needs a session created through first-send instead of the removed POST /api/sessions; rewritten after M4 (plans/roadmap.md M2.9)"]
#[tokio::test(flavor = "multi_thread")]
async fn session_lifecycle() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        node_env: vec![("TMPDIR", "{run_dir}".into())],
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let headers = browser_headers();
    let mut t = Transcript::new(cluster.volatile());

    let workspaces = api.send("GET", "/api/workspaces", &headers, None).await;
    t.response("list workspaces", "GET /api/workspaces", &workspaces);

    let created = api
        .send(
            "POST",
            "/api/sessions",
            &headers,
            Some(json!({ "workspaceId": WORKSPACE_ID })),
        )
        .await;
    t.response("create session", "POST /api/sessions", &created);
    let id = created.body["session"]["id"].as_str().unwrap().to_owned();
    let session = format!("/api/sessions/{id}");

    let listed = api.send("GET", "/api/sessions", &headers, None).await;
    t.response("list sessions", "GET /api/sessions", &listed);

    let path = format!("{session}/control/acquire");
    let acquired = api
        .send(
            "POST",
            &path,
            &headers,
            Some(json!({ "clientId": "browser" })),
        )
        .await;
    t.response("acquire control", &format!("POST {path}"), &acquired);
    let generation = acquired.body["lease"]["generation"].clone();

    let path = format!("{session}/snapshot");
    let before = api.send("GET", &path, &headers, None).await;
    t.response("snapshot before prompting", &format!("GET {path}"), &before);
    let start = cursor(&before.body["watermark"]);

    let events_path = format!("/api/events?sessionId={id}&cursor={start}");
    let mut live = api.connect(&events_path, &headers).await.open();

    cluster
        .llm
        .push([Reply::Text("Hello from the fake model.".to_owned())]);
    let command = json!({
        "commandId": "command-1",
        "clientId": "browser",
        "generation": generation,
        "payload": { "type": "prompt", "message": "Say hello" },
    });
    let path = format!("{session}/commands");
    let sent = api
        .send("POST", &path, &headers, Some(command.clone()))
        .await;
    t.response("prompt", &format!("POST {path}"), &sent);

    let streamed = live.until(settled).await;
    live.close().await;
    t.note("events until the run settles", envelope(&streamed));
    // Its own placeholder numbering: lifecycle steps added later must not
    // renumber the agent-parity snapshot.
    let agent_events = Normalizer::new(cluster.volatile()).value(&Value::Array(streamed.clone()));

    let duplicate = api.send("POST", &path, &headers, Some(command)).await;
    t.response("same command again", &format!("POST {path}"), &duplicate);

    let path = format!("{session}/snapshot");
    let after = api.send("GET", &path, &headers, None).await;
    t.response("snapshot after the run", &format!("GET {path}"), &after);

    let mut replay = api.connect(&events_path, &headers).await.open();
    let replayed = replay.until(settled).await;
    replay.close().await;
    t.note(
        "replay from the same cursor repeats the stream",
        json!(replayed == streamed),
    );

    for (step, bad) in [
        ("cursor from another epoch", "999:0".to_owned()),
        (
            "cursor ahead of the stream",
            format!("{}:999999", before.body["watermark"]["epoch"]),
        ),
    ] {
        let path = format!("/api/events?sessionId={id}&cursor={bad}");
        let mut socket = api.connect(&path, &headers).await.open();
        let first = socket.next_json().await.expect("reset frame");
        t.note(step, first);
        socket.close().await;
    }

    let path = format!("{session}/control/release");
    let released = api
        .send(
            "POST",
            &path,
            &headers,
            Some(json!({ "clientId": "browser", "generation": generation })),
        )
        .await;
    t.response("release control", &format!("POST {path}"), &released);

    let requests = cluster.llm.requests();
    t.note("model requests", json!(requests.len()));

    insta::assert_json_snapshot!("session_lifecycle", t.into_value());
    insta::assert_json_snapshot!("session_agent_events", agent_events);
}

/// The gateway's part of the event stream: one envelope shape, consecutive
/// sequence numbers in one epoch, and the run's start and end.
fn envelope(frames: &[Value]) -> Value {
    let keys: Vec<Vec<&String>> = frames
        .iter()
        .map(|frame| {
            let mut keys: Vec<&String> = frame.as_object().unwrap().keys().collect();
            keys.sort();
            keys
        })
        .collect();
    let sequences: Vec<u64> = frames
        .iter()
        .map(|frame| frame["sequence"].as_u64().unwrap())
        .collect();
    let agent_types: Vec<&Value> = frames
        .iter()
        .filter(|frame| frame["type"] == "pi_event")
        .map(|frame| &frame["data"]["type"])
        .collect();
    let position = |name: &str| agent_types.iter().position(|t| *t == name);
    json!({
        "envelope keys": keys[0],
        "every frame has them": keys.iter().all(|k| *k == keys[0]),
        "epochs": frames
            .iter()
            .map(|f| f["epoch"].as_u64().unwrap())
            .collect::<BTreeSet<_>>(),
        "sequences are consecutive from 1":
            sequences.iter().enumerate().all(|(i, s)| *s == i as u64 + 1),
        "agent_start, agent_end, agent_settled in order": position("agent_start").is_some()
            && position("agent_start") < position("agent_end")
            && position("agent_end") < position("agent_settled"),
        "assistant message": frames
            .iter()
            .rev()
            .find(|f| f["data"]["type"] == "message_end")
            .map(|f| &f["data"]["message"]["content"]),
    })
}
