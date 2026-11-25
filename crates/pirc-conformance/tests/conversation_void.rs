//! A first-message command id refused for good, by a real Node process. The test
//! plays the Gateway: it asks the Node to void an admission it never received,
//! then lets the delayed original arrive, across real process crashes. The
//! Gateway side of the journey (unknown outcome, void, explicit retry) runs
//! against the Node's own code in `pirc-gateway`'s recovery tests.
use pirc_conformance::{FakeGateway, LoneNode, NODE_ID, NodeOptions, USER};
use serde_json::{Value, json};

async fn register(gateway: &FakeGateway) -> pirc_conformance::NodeLink {
    let mut link = gateway.accept().await;
    link.recv_where(|frame| frame["type"] == "register").await;
    link.send(
        &json!({"type":"registered","nodeId":NODE_ID,"models":{"providers":{}},"mirrors":{}}),
    )
    .await;
    link
}
fn admission(command: &str, message: &str) -> Value {
    json!({"method":"POST","url":"/api/session-creations/void-first/admission","user":USER,"payload":{"commandId":command,"submissionHash":"a".repeat(64),"model":{"provider":"fake","id":"fake-model"},"thinking":"low","message":message,"uploadIds":[],"clientId":"phone","generation":1}})
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn a_voided_first_message_is_refused_when_the_delayed_original_arrives_even_after_crashes() {
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
        capabilities["data"]["body"]["canVoidInitialAdmission"],
        true
    );
    let create = json!({"method":"POST","url":"/api/session-creations","user":USER,"payload":{"operationId":"void-first","workspaceId":"test","submissionHash":"a".repeat(64)}});
    let created = link.request("create", create.clone()).await;
    assert_eq!(created["data"]["status"], 200, "{created}");
    let session = created["data"]["body"]["creation"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();

    // The Gateway sent an admission that has not arrived and asks to void it.
    let void = json!({"method":"POST","url":"/api/session-creations/void-first/admission/void","user":USER,"payload":{"commandId":"lost-command","submissionHash":"a".repeat(64),"inputHash":"b".repeat(64)}});
    let voided = link.request("void", void.clone()).await;
    assert_eq!(voided["data"]["status"], 200, "{voided}");
    assert_eq!(voided["data"]["body"]["void"]["result"], "voided");
    // A lost reply: the same void again gives the same answer.
    let again = link.request("void-again", void.clone()).await;
    assert_eq!(again["data"]["body"], voided["data"]["body"]);

    // The delayed original arrives, with a lease and as the first admission.
    let lease = link
        .request(
            "lease",
            json!({"method":"POST","url":format!("/api/sessions/{session}/control/acquire"),"user":USER,"payload":{"clientId":"phone"}}),
        )
        .await;
    assert_eq!(lease["data"]["status"], 200, "{lease}");
    let generation = lease["data"]["body"]["lease"]["generation"]
        .as_i64()
        .unwrap();
    let mut late = admission("lost-command", "Never execute this lost first input");
    late["payload"]["generation"] = json!(generation);
    for round in 0..2 {
        let refused = link.request(&format!("late-{round}"), late.clone()).await;
        assert_eq!(refused["data"]["status"], 409, "{refused}");
        assert_eq!(refused["data"]["body"]["error"]["code"], "command_voided");
        // Nothing was created or started for it.
        let receipt = link
            .request(
                &format!("receipt-{round}"),
                json!({"method":"GET","url":"/api/session-creations/void-first/admission","user":USER}),
            )
            .await;
        assert_eq!(
            receipt["data"]["body"]["admission"]["state"],
            "not_submitted"
        );
        assert!(receipt["data"]["body"]["admission"]["command"].is_null());
        let command = link
            .request(
                &format!("command-{round}"),
                json!({"method":"GET","url":format!("/api/sessions/{session}/commands/lost-command"),"user":USER}),
            )
            .await;
        assert_eq!(command["data"]["status"], 404, "{command}");
        let snapshot = link
            .request(
                &format!("blank-{round}"),
                json!({"method":"GET","url":format!("/api/sessions/{session}/snapshot"),"user":USER}),
            )
            .await;
        assert_eq!(snapshot["data"]["body"]["history"], json!([]));
        if round == 0 {
            // The void is durable: a crash and restart keeps it.
            node.restart(true);
            drop(link);
            link = register(&gateway).await;
            let lease = link
                .request(
                    "lease-after-crash",
                    json!({"method":"POST","url":format!("/api/sessions/{session}/control/acquire"),"user":USER,"payload":{"clientId":"phone"}}),
                )
                .await;
            late["payload"]["generation"] = lease["data"]["body"]["lease"]["generation"].clone();
            let same = link.request("void-after-crash", void.clone()).await;
            assert_eq!(same["data"]["body"]["void"]["result"], "voided");
        }
    }

    // A retry that names a command the Node never voided or admitted, or that
    // changes the content, is refused and creates nothing.
    let retry = |predecessor: &str, command: &str, message: &str| {
        let mut body = admission(command, message);
        body["url"] = json!("/api/session-creations/void-first/admission/retry");
        body["payload"] = json!({"previousCommandId":predecessor,"admission":body["payload"]});
        body
    };
    let unknown = link
        .request("retry-unknown", retry("never-seen", "second", "Retry text"))
        .await;
    assert_eq!(unknown["data"]["status"], 409, "{unknown}");
    let changed = link
        .request(
            "retry-changed",
            retry("lost-command", "second", "Different text"),
        )
        .await;
    assert_eq!(changed["data"]["status"], 409, "{changed}");
    let missing = link
        .request(
            "second-missing",
            json!({"method":"GET","url":format!("/api/sessions/{session}/commands/second"),"user":USER}),
        )
        .await;
    assert_eq!(missing["data"]["status"], 404, "{missing}");
    assert!(link.skipped.iter().all(|f| f["type"] != "model_start"));
}
