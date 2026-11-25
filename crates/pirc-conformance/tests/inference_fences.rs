//! Real Node and Agent processes with a fake Gateway: a transition cancels only
//! the source runner's inference and never delivers its late tool proposal.
mod node_link_side_support;
use node_link_side_support::{Gateway, models, registered, settled_in};
use pirc_conformance::{FakeGateway, LoneNode, NodeOptions};
use serde_json::json;

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn transition_cancels_source_inference_while_peer_finishes_and_context_survives() {
    let server = FakeGateway::bind().await;
    let Some(mut node) = LoneNode::start_with(
        server.port(),
        NodeOptions {
            agent_core_only: true,
            env: vec![
                ("PIRC_BROWSER", "false".into()),
                ("TMPDIR", "{run_dir}".into()),
            ],
            ..Default::default()
        },
    ) else {
        return;
    };
    let mut gw = Gateway::new(server.accept().await);
    gw.link.recv().await;
    gw.link
        .send(&registered(models("fake", "fake-model", "low"), json!({})))
        .await;
    let (a, a_control) = gw.session().await;
    let (b, b_control) = gw.session().await;
    let accepted = gw
        .prompt(&a, &a_control, "source-prompt", "Keep my original question")
        .await;
    assert_eq!(accepted["data"]["status"], 202, "{accepted}");
    let a_start = gw.take(|f| f["type"] == "model_start").await;
    let accepted = gw
        .prompt(&b, &b_control, "peer-prompt", "Finish the independent task")
        .await;
    assert_eq!(accepted["data"]["status"], 202, "{accepted}");
    let b_start = gw.take(|f| f["type"] == "model_start").await;
    assert_ne!(a_start["requestId"], b_start["requestId"]);
    let base = format!("/api/sessions/{a}");
    let before = gw.ask("GET", &format!("{base}/snapshot"), None).await;
    assert_eq!(before["data"]["status"], 200, "{before}");
    let original = node.dir.path().join("workspace/README.md");
    std::fs::write(&original, "user's later edit\n").unwrap();
    let acceptance = json!({"intent":{"operationId":"move-with-inference","planHash":"a".repeat(64),"expectedWorkspaceId":"test","expectedRunnerEpoch":before["data"]["body"]["session"]["runnerEpoch"]},"clientId":"browser","generation":a_control});
    let fenced = gw
        .ask(
            "POST",
            &format!("{base}/execution-fences"),
            Some(acceptance.clone()),
        )
        .await;
    assert_eq!(fenced["data"]["status"], 200, "{fenced}");
    gw.take(|f| f["type"] == "model_cancel" && f["requestId"] == a_start["requestId"])
        .await;
    // The provider can race a cancel; its old answer must not become a file effect.
    gw.reply_tool(
        &a_start,
        "stale-write",
        "write",
        json!({"path":"README.md","content":"must not land"}),
    )
    .await;
    gw.reply_text(&b_start, "The independent task completed.")
        .await;
    gw.take(settled_in(&b)).await;
    let duplicate = gw
        .ask(
            "POST",
            &format!("{base}/execution-fences"),
            Some(acceptance),
        )
        .await;
    assert_eq!(duplicate["data"]["body"], fenced["data"]["body"]);
    let drain = gw
        .ask(
            "POST",
            &format!("{base}/execution-fences/move-with-inference/drain"),
            Some(json!({})),
        )
        .await;
    assert_eq!(
        drain["data"]["body"]["transition"]["state"], "supervisor_drained",
        "{drain}"
    );
    assert_eq!(
        drain["data"]["body"]["transition"]["revocationConfirmed"],
        false
    );
    let evidence = drain["data"]["body"]["transition"]["sandboxProcesses"].clone();
    assert_eq!(evidence["launches"], 1, "{drain}");
    assert_eq!(
        evidence["unresolved"], 1,
        "the fixture uses an untracked wrapper: {drain}"
    );
    assert_eq!(
        evidence["terminated"], 0,
        "wrapper exit is not kernel proof"
    );
    let after = gw.ask("GET", &format!("{base}/snapshot"), None).await;
    assert_eq!(after["data"]["status"], 200, "{after}");
    assert!(
        after["data"]["body"]["history"]
            .to_string()
            .contains("Keep my original question"),
        "{after}"
    );
    let peer = gw
        .ask("GET", &format!("/api/sessions/{b}/snapshot"), None)
        .await;
    assert!(
        peer["data"]["body"]["history"]
            .to_string()
            .contains("The independent task completed."),
        "{peer}"
    );
    assert_eq!(
        std::fs::read_to_string(&original).unwrap(),
        "user's later edit\n"
    );
    assert!(
        !gw.link
            .skipped
            .iter()
            .any(|f| f["type"] == "model_cancel" && f["requestId"] == b_start["requestId"])
    );
    assert!(
        !gw.link.skipped.iter().any(|f| f["type"] == "model_start"),
        "No automatic inference retry after fencing"
    );
    node.restart(true);
    drop(gw);
    let mut gw = Gateway::new(server.accept().await);
    gw.link.recv().await;
    gw.link
        .send(&registered(models("fake", "fake-model", "low"), json!({})))
        .await;
    let receipt = gw
        .ask(
            "GET",
            &format!("{base}/execution-fences/move-with-inference"),
            None,
        )
        .await;
    assert_eq!(receipt["data"]["status"], 200, "{receipt}");
    assert_eq!(
        receipt["data"]["body"]["transition"]["sandboxProcesses"],
        evidence
    );
    let retry = gw
        .ask(
            "POST",
            &format!("{base}/execution-fences/move-with-inference/drain"),
            Some(json!({})),
        )
        .await;
    assert_eq!(
        retry["data"]["body"]["transition"]["sandboxProcesses"],
        evidence
    );
    assert_eq!(
        retry["data"]["body"]["transition"]["revocationConfirmed"],
        false
    );
    let after_restart = gw.ask("GET", &format!("{base}/snapshot"), None).await;
    assert!(
        after_restart["data"]["body"]["history"]
            .to_string()
            .contains("Keep my original question")
    );
    assert_eq!(
        std::fs::read_to_string(&original).unwrap(),
        "user's later edit\n"
    );
}
