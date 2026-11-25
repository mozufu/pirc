//! A voided environment-switch operation, by a real Node process. The test plays
//! the Gateway: it asks the Node to void an operation whose create request it
//! never saw answered, then lets the delayed original arrive, across real process
//! crashes. The Gateway side of the journey (unknown outcome, cancel, release)
//! runs against the Node's own code in `pirc-gateway`'s coordinator void tests.
//! This is not proof of OS-level revocation, and it is not UI acceptance.
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
fn req(method: &str, path: &str, payload: Value) -> Value {
    json!({"method":method,"url":path,"user":USER,"payload":payload})
}
fn create(base: &str, op: &str, epoch: &Value, generation: &Value) -> Value {
    req(
        "POST",
        &format!("{base}/execution-fences"),
        json!({"intent":{"operationId":op,"planHash":"a".repeat(64),"expectedWorkspaceId":"test","expectedRunnerEpoch":epoch},"clientId":"phone","generation":generation}),
    )
}
fn void(base: &str, op: &str) -> Value {
    req(
        "POST",
        &format!("{base}/execution-fences/{op}/void"),
        json!({"planHash":"a".repeat(64)}),
    )
}

async fn control(link: &mut pirc_conformance::NodeLink, session: &str, id: &str) -> Value {
    let lease = link
        .request(
            id,
            req(
                "POST",
                &format!("/api/sessions/{session}/control/acquire"),
                json!({"clientId":"phone"}),
            ),
        )
        .await;
    assert_eq!(lease["data"]["status"], 200, "{lease}");
    lease["data"]["body"]["lease"]["generation"].clone()
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn a_voided_operation_is_refused_when_the_delayed_create_arrives_even_after_crashes() {
    let gateway = FakeGateway::bind().await;
    let Some(mut node) = LoneNode::start_with(
        gateway.port(),
        NodeOptions {
            agent_core_only: true,
            chat_node: false,
            env: vec![("PIRC_BROWSER", "false".into())],
            second_workspace: false,
        },
    ) else {
        return;
    };
    let mut link = register(&gateway).await;
    let capabilities = link
        .request(
            "capabilities",
            req("GET", "/api/execution-fences/capabilities", Value::Null),
        )
        .await;
    assert_eq!(capabilities["data"]["body"]["transitionVoidVersion"], 1);
    assert_eq!(capabilities["data"]["body"]["transitionReleaseVersion"], 1);
    // The test plays the Gateway, so it creates the session through the
    // Node's internal entry for Gateway-owned conversations.
    let created = link
        .request(
            "session",
            req(
                "POST",
                "/api/session-creations/internal",
                json!({"workspaceId":"test"}),
            ),
        )
        .await;
    assert_eq!(created["data"]["status"], 201, "{created}");
    let session = created["data"]["body"]["session"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let epoch = created["data"]["body"]["session"]["runnerEpoch"].clone();
    let base = format!("/api/sessions/{session}");
    let mut generation = control(&mut link, &session, "lease").await;

    // The Gateway sent a create that has not been answered, and asks to void it.
    let voided = link.request("void", void(&base, "move-1")).await;
    assert_eq!(voided["data"]["status"], 200, "{voided}");
    assert_eq!(voided["data"]["body"]["void"]["result"], "voided");
    assert_eq!(voided["data"]["body"]["void"]["sessionId"], session);
    // A lost reply: the same void again gives the same answer.
    let again = link.request("void-again", void(&base, "move-1")).await;
    assert_eq!(again["data"]["body"], voided["data"]["body"]);

    for round in 0..2 {
        // The delayed original arrives, with a valid lease: refused.
        for (label, plan) in [("same", "a"), ("other-plan", "b")] {
            let mut late = create(&base, "move-1", &epoch, &generation);
            late["payload"]["intent"]["planHash"] = json!(plan.repeat(64));
            let refused = link.request(&format!("late-{round}-{label}"), late).await;
            assert_eq!(refused["data"]["status"], 409, "{refused}");
            assert_eq!(refused["data"]["body"]["error"]["code"], "operation_voided");
        }
        // No fence exists, nothing is blocked and the session still takes work.
        let status = link
            .request(
                &format!("status-{round}"),
                req(
                    "GET",
                    &format!("{base}/execution-fences/move-1"),
                    Value::Null,
                ),
            )
            .await;
        assert_eq!(status["data"]["status"], 404, "{status}");
        let preflight = link
            .request(
                &format!("preflight-{round}"),
                req(
                    "POST",
                    &format!("{base}/execution-fences/preflight"),
                    json!({"expectedWorkspaceId":"test","expectedRunnerEpoch":epoch,"targetWorkspaceId":"test"}),
                ),
            )
            .await;
        assert_eq!(
            preflight["data"]["body"]["evidence"]["activity"]["fenced"], false,
            "{preflight}"
        );
        if round == 0 {
            // The void is durable: a crash and restart keeps it.
            node.restart(true);
            drop(link);
            link = register(&gateway).await;
            generation = control(&mut link, &session, "lease-after-crash").await;
            let same = link
                .request("void-after-crash", void(&base, "move-1"))
                .await;
            assert_eq!(same["data"]["body"]["void"]["result"], "voided");
        }
    }

    // Another operation is a new identity: it creates a fence, and a void of it
    // reports the fence instead of voiding.
    let fenced = link
        .request("create-2", create(&base, "move-2", &epoch, &generation))
        .await;
    assert_eq!(fenced["data"]["status"], 200, "{fenced}");
    let reported = link.request("void-2", void(&base, "move-2")).await;
    assert_eq!(reported["data"]["status"], 200, "{reported}");
    assert_eq!(reported["data"]["body"]["void"]["result"], "fence");
    assert_eq!(reported["data"]["body"]["transition"]["state"], "fenced");
    // Another user cannot void it.
    let mut stranger = void(&base, "move-2");
    stranger["user"] = json!("outsider");
    assert_eq!(
        link.request("stranger", stranger).await["data"]["status"],
        403
    );
    // And the voided identity is still refused after yet another crash.
    node.restart(true);
    drop(link);
    let mut link = register(&gateway).await;
    let generation = control(&mut link, &session, "lease-last").await;
    let refused = link
        .request("late-last", create(&base, "move-1", &epoch, &generation))
        .await;
    assert_eq!(refused["data"]["body"]["error"]["code"], "operation_voided");
    let kept = link
        .request(
            "fence-kept",
            req(
                "GET",
                &format!("{base}/execution-fences/move-2"),
                Value::Null,
            ),
        )
        .await;
    assert_eq!(kept["data"]["body"]["transition"]["state"], "fenced");
}
