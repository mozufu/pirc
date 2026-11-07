//! Real Node/Agent admission retry after a known pre-message startup failure.
//! No user provider or browser is used; the link is a synthetic trusted Gateway.
use base64::{Engine as _, engine::general_purpose::STANDARD};
use pirc_conformance::{FakeGateway, LoneNode, NODE_ID, NodeOptions, USER, fake_models};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
async fn register(gateway: &FakeGateway, models: Value) -> pirc_conformance::NodeLink {
    let mut link = gateway.accept().await;
    link.recv_where(|f| f["type"] == "register").await;
    link.send(&json!({"type":"registered","nodeId":NODE_ID,"models":models,"mirrors":{}}))
        .await;
    link
}
#[tokio::test(flavor = "multi_thread")]
async fn rejected_first_attempt_retries_in_the_same_session_with_the_same_file_after_restart() {
    let gateway = FakeGateway::bind().await;
    let Some(mut node) = LoneNode::start_with(
        gateway.port(),
        NodeOptions {
            chat_node: true,
            agent_core_only: true,
            env: vec![("PIRC_BROWSER", "false".into())],
            second_workspace: false,
        },
    ) else {
        return;
    };
    let mut link = register(&gateway, json!({"providers":{}})).await;
    let create = json!({"method":"POST","url":"/api/session-creations","user":USER,"payload":{"operationId":"retry-first","workspaceId":"chats","submissionHash":"a".repeat(64)}});
    let made = link.request("create", create.clone()).await;
    assert_eq!(made["data"]["status"], 200, "{made}");
    let session = made["data"]["body"]["creation"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let bytes = b"Retained attachment bytes\n";
    let hash = format!("{:x}", Sha256::digest(bytes));
    let url = format!(
        "/api/session-creations/retry-first/attachments/file?submissionHash={}&sha256={hash}&byteSize={}&filename=retained.txt",
        "a".repeat(64),
        bytes.len()
    );
    let file=link.request("file",json!({"method":"PUT","url":url,"user":USER,"bodyBase64":STANDARD.encode(bytes),"contentType":"text/plain"})).await;
    assert_eq!(file["data"]["status"], 200, "{file}");
    let upload = file["data"]["body"]["creationAttachment"]["upload"]["id"].clone();
    let held=link.request("control",json!({"method":"POST","url":format!("/api/sessions/{session}/control/acquire"),"user":USER,"payload":{"clientId":"phone"}})).await;
    let mut admission = json!({"commandId":"first","submissionHash":"a".repeat(64),"model":{"provider":"fake","id":"fake-model"},"thinking":"low","message":"Exactly one retained first message","uploadIds":[upload],"clientId":"phone","generation":held["data"]["body"]["lease"]["generation"]});
    let first=link.request("first",json!({"method":"POST","url":"/api/session-creations/retry-first/admission","user":USER,"payload":admission})).await;
    assert_eq!(first["data"]["status"], 200, "{first}");
    assert_eq!(
        first["data"]["body"]["admission"]["command"]["status"], "rejected",
        "{first}"
    );
    assert!(!link.skipped.iter().any(|f| f["type"] == "model_start"));
    // This is a known non-admission. Reopen only after that proof, never an
    // unknown append. Restoring the catalog repairs the synthetic startup cause.
    node.restart(false);
    drop(link);
    let mut link = register(&gateway, fake_models()).await;
    let held=link.request("new-control",json!({"method":"POST","url":format!("/api/sessions/{session}/control/acquire"),"user":USER,"payload":{"clientId":"phone"}})).await;
    admission["commandId"] = json!("second");
    admission["generation"] = held["data"]["body"]["lease"]["generation"].clone();
    let request = json!({"method":"POST","url":"/api/session-creations/retry-first/admission/retry","user":USER,"payload":{"previousCommandId":"first","admission":admission}});
    let second = link.request("retry", request.clone()).await;
    assert_eq!(second["data"]["status"], 200, "{second}");
    assert_eq!(
        second["data"]["body"]["admission"]["command"]["status"], "accepted",
        "{second}"
    );
    assert_eq!(second["data"]["body"]["admission"]["sessionId"], session);
    let same = link.request("repeat", request).await;
    assert_eq!(same["data"]["body"]["admission"]["command"]["id"], "second");
    let same_session = link.request("same-session", create).await;
    assert_eq!(
        same_session["data"]["body"]["creation"]["sessionId"],
        session
    );
    let same_file=link.request("same-file",json!({"method":"GET","url":"/api/session-creations/retry-first/attachments/file","user":USER})).await;
    assert_eq!(
        same_file["data"]["body"]["creationAttachment"]["upload"]["id"],
        upload
    );
    let old=link.request("old-proof",json!({"method":"GET","url":"/api/session-creations/retry-first/admission/attempts/first","user":USER})).await;
    assert_eq!(
        old["data"]["body"]["admission"]["command"]["status"],
        "rejected"
    );
    // Read the actual Agent journal in this owned fixture, not a mock receipt.
    let state = node
        .dir
        .path()
        .join("node-state/sessions")
        .join(&session)
        .join("session.jsonl");
    let lines = std::fs::read_to_string(&state)
        .unwrap_or_else(|e| panic!("{}: {e}; {}", state.display(), node.log()));
    let text = lines
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).expect("valid Agent journal entry"))
        .filter(|v| v["type"] == "message" && v["message"]["role"] == "user")
        .collect::<Vec<_>>();
    assert_eq!(text.len(), 1, "{lines}");
    assert!(
        text[0]
            .to_string()
            .contains("Exactly one retained first message")
    );
}
