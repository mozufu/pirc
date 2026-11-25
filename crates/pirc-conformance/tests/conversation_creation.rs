//! Real Node process/link proof for durable first-send file transfer. The test
//! acts as Gateway; no provider or browser runs. Full client acceptance is separate.
use pirc_conformance::{FakeGateway, LoneNode, NODE_ID, NodeOptions, USER};
use serde_json::json;

async fn register(gateway: &FakeGateway) -> pirc_conformance::NodeLink {
    let mut link = gateway.accept().await;
    link.recv_where(|frame| frame["type"] == "register").await;
    link.send(
        &json!({"type":"registered","nodeId":NODE_ID,"models":{"providers":{}},"mirrors":{}}),
    )
    .await;
    link
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn pre_allocation_stop_survives_a_process_crash_and_fences_late_initial_admission() {
    let gateway = FakeGateway::bind().await;
    let Some(mut node) = LoneNode::start_with(
        gateway.port(),
        NodeOptions {
            agent_core_only: true,
            env: vec![("PIRC_BROWSER", "false".into())],
            ..Default::default()
        },
    ) else {
        return;
    };
    let mut link = register(&gateway).await;
    let capabilities = link
        .request(
            "capabilities",
            json!({"method":"GET","url":"/api/session-creations/capabilities","user":USER}),
        )
        .await;
    assert_eq!(
        capabilities["data"]["body"]["canStopBeforeAllocation"],
        true
    );
    let stop = json!({"method":"POST","url":"/api/session-creations/stopped-first/stop","user":USER,"payload":{"workspaceId":"test","submissionHash":"a".repeat(64)}});
    let response = link.request("stop-before-allocation", stop.clone()).await;
    assert_eq!(response["data"]["status"], 200, "{response}");
    let proof = response["data"]["body"]["stop"].clone();
    assert_eq!(proof["confirmed"], true);
    assert!(proof["sessionId"].is_null());
    // No allocation or files are a side effect of this Stop.
    let missing = link
        .request(
            "no-allocation",
            json!({"method":"GET","url":"/api/session-creations/stopped-first","user":USER}),
        )
        .await;
    assert_eq!(missing["data"]["status"], 404, "{missing}");
    node.restart(true);
    drop(link);
    let mut link = register(&gateway).await;
    let recovered = link
        .request(
            "stop-after-crash",
            json!({"method":"GET","url":"/api/session-creations/stopped-first/stop","user":USER}),
        )
        .await;
    assert_eq!(recovered["data"]["status"], 200, "{recovered}");
    assert_eq!(recovered["data"]["body"]["stop"], proof);
    let create = json!({"method":"POST","url":"/api/session-creations","user":USER,"payload":{"operationId":"stopped-first","workspaceId":"test","submissionHash":"a".repeat(64)}});
    let allocated = link
        .request("late-or-explicit-allocation", create.clone())
        .await;
    assert_eq!(allocated["data"]["status"], 200, "{allocated}");
    let session = allocated["data"]["body"]["creation"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let old_input = json!({"method":"POST","url":"/api/session-creations/stopped-first/admission","user":USER,"payload":{"commandId":"late-first-command","submissionHash":"a".repeat(64),"model":{"provider":"fake","id":"fake-model"},"thinking":"low","message":"Never execute this old first input","uploadIds":[],"clientId":"late-client","generation":1}});
    // Even without a current lease, this is a receipt for an already fenced
    // first input, not permission to infer or launch an Agent.
    let delayed = link.request("late-initial-input", old_input.clone()).await;
    assert_eq!(delayed["data"]["status"], 200, "{delayed}");
    let admission = &delayed["data"]["body"]["admission"];
    assert_eq!(admission["state"], "stopped");
    assert_eq!(admission["stopConfirmed"], true);
    assert!(admission["command"].is_null());
    let command = link.request("no-initial-command", json!({"method":"GET","url":format!("/api/sessions/{session}/commands/late-first-command"),"user":USER})).await;
    assert_eq!(command["data"]["status"], 404, "{command}");
    let snapshot = link
        .request(
            "blank-conversation",
            json!({"method":"GET","url":format!("/api/sessions/{session}/snapshot"),"user":USER}),
        )
        .await;
    assert_eq!(snapshot["data"]["status"], 200, "{snapshot}");
    assert_eq!(snapshot["data"]["body"]["history"], json!([]));
    let repeated = link.request("duplicate-stop", stop).await;
    assert_eq!(repeated["data"]["body"]["stop"]["sessionId"], session);
    node.restart(true);
    drop(link);
    let mut link = register(&gateway).await;
    let same = link.request("same-allocation", create).await;
    assert_eq!(same["data"]["body"]["creation"]["sessionId"], session);
    let still_stopped = link.request("still-fenced", old_input).await;
    assert_eq!(
        still_stopped["data"]["body"]["admission"]["state"],
        "stopped"
    );
    assert!(
        link.skipped
            .iter()
            .all(|frame| frame["type"] != "model_start")
    );
}
