//! Real Node process/link proof for durable first-send file transfer. The test
//! acts as Gateway; no provider or browser runs. Full client acceptance is separate.
use base64::{Engine as _, engine::general_purpose::STANDARD};
use pirc_conformance::{FakeGateway, LoneNode, NODE_ID, NodeOptions, USER};
use serde_json::json;
use sha2::{Digest, Sha256};

async fn register(gateway: &FakeGateway) -> pirc_conformance::NodeLink {
    let mut link = gateway.accept().await;
    link.recv_where(|frame| frame["type"] == "register").await;
    link.send(
        &json!({"type":"registered","nodeId":NODE_ID,"models":{"providers":{}},"mirrors":{}}),
    )
    .await;
    link
}
#[tokio::test(flavor = "multi_thread")]
async fn creation_attachment_survives_process_crash_and_does_not_revive_after_delete() {
    let gateway = FakeGateway::bind().await;
    let Some(mut node) = LoneNode::start_with(
        gateway.port(),
        NodeOptions {
            chat_node: true,
            agent_core_only: true,
            env: vec![("PIRC_BROWSER", "false".into())],
            ..Default::default()
        },
    ) else {
        return;
    };
    let mut link = register(&gateway).await;
    let create = json!({"method":"POST","url":"/api/session-creations","user":USER,"payload":{"operationId":"first-send","workspaceId":"chats","submissionHash":"a".repeat(64)}});
    let created = link.request("create", create.clone()).await;
    assert_eq!(created["data"]["status"], 200, "{created}");
    let session = created["data"]["body"]["creation"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let hash = format!("{:x}", Sha256::digest(b"test"));
    let url = format!(
        "/api/session-creations/first-send/attachments/file-1?submissionHash={}&sha256={hash}&byteSize=4&filename=private-name.txt",
        "a".repeat(64)
    );
    let transfer = json!({"method":"PUT","url":url,"user":USER,"bodyBase64":STANDARD.encode(b"test"),"contentType":"text/plain"});
    let first = link.request("transfer", transfer.clone()).await;
    assert_eq!(first["data"]["status"], 200, "{first}");
    let receipt = first["data"]["body"]["creationAttachment"].clone();
    assert_eq!(receipt["state"], "ready");
    assert_eq!(receipt["upload"]["sha256"], hash);
    let retry = link.request("retry-lost-response", transfer.clone()).await;
    assert_eq!(retry["data"]["body"]["creationAttachment"], receipt);
    let upload_id = receipt["upload"]["id"].as_str().unwrap();
    let reference_request = json!({"method":"GET","url":format!("/api/sessions/{session}/uploads/{upload_id}/reference"),"user":USER});
    let reference = link
        .request("saved-reference", reference_request.clone())
        .await;
    assert_eq!(reference["data"]["status"], 200, "{reference}");
    assert_eq!(
        reference["data"]["body"]["reference"]["scope"],
        "conversation"
    );
    assert_eq!(
        reference["data"]["body"]["reference"]["provenance"],
        "recorded"
    );
    node.restart(true);
    drop(link);
    let mut link = register(&gateway).await;
    let lookup = json!({"method":"GET","url":"/api/session-creations/first-send/attachments/file-1","user":USER});
    let recovered = link.request("after-restart", lookup.clone()).await;
    assert_eq!(recovered["data"]["status"], 200, "{recovered}");
    assert_eq!(recovered["data"]["body"]["creationAttachment"], receipt);
    assert_eq!(
        link.request("saved-reference-after-crash", reference_request.clone())
            .await["data"]["body"],
        reference["data"]["body"]
    );
    let same_creation = link.request("same-creation", create.clone()).await;
    assert_eq!(
        same_creation["data"]["body"]["creation"]["sessionId"],
        session
    );
    let mut changed = transfer.clone();
    changed["bodyBase64"] = json!(STANDARD.encode(b"oops"));
    assert_eq!(
        link.request("wrong-bytes", changed).await["data"]["status"],
        409
    );
    let deleted = link
        .request(
            "delete",
            json!({"method":"DELETE","url":format!("/api/sessions/{session}"),"user":USER}),
        )
        .await;
    assert_eq!(deleted["data"]["status"], 204, "{deleted}");
    assert!(
        link.request("deleted-reference", reference_request).await["data"]["status"]
            .as_u64()
            .unwrap()
            >= 400
    );
    let status = link.request("deleted-status", lookup).await;
    assert_eq!(status["data"]["status"], 200);
    let tombstone = status["data"]["body"]["creationAttachment"].clone();
    assert_eq!(tombstone["state"], "deleted");
    assert_eq!(tombstone["upload"], json!({"id":receipt["upload"]["id"]}));
    assert_eq!(
        link.request("delayed-transfer", transfer).await["data"]["body"]["creationAttachment"],
        tombstone
    );
    assert_eq!(
        link.request("delayed-create", create).await["data"]["body"]["creation"]["state"],
        "deleted"
    );
    // A tombstone exposes no former filename or storage path.
    assert!(tombstone["upload"].get("filename").is_none());
    assert!(tombstone["upload"].get("storageName").is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn pre_allocation_stop_survives_a_process_crash_and_fences_late_initial_admission() {
    let gateway = FakeGateway::bind().await;
    let Some(mut node) = LoneNode::start_with(
        gateway.port(),
        NodeOptions {
            chat_node: true,
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
    let stop = json!({"method":"POST","url":"/api/session-creations/stopped-first/stop","user":USER,"payload":{"workspaceId":"chats","submissionHash":"a".repeat(64)}});
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
    let create = json!({"method":"POST","url":"/api/session-creations","user":USER,"payload":{"operationId":"stopped-first","workspaceId":"chats","submissionHash":"a".repeat(64)}});
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
