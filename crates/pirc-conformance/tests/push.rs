//! Push notifications (`apps/gateway/src/daemon/push.ts`, `push-routes.ts`):
//! the VAPID key, subscribing and unsubscribing, what a push service
//! receives (headers, the VAPID JWT and the decrypted payload) and how its
//! answers are handled, a phone's subscription going with its device token,
//! and the push a session sends when it starts waiting for its user. The
//! test plays the node and a push service on loopback
//! (`PIRC_PUSH_ALLOW_HTTP=1`).

use std::os::unix::fs::PermissionsExt;

use pirc_conformance::{
    Cluster, FakePush, FirstSend, GatewayOptions, HOST, NODE_ID, NODE_TOKEN, Transcript, WebSocket,
    assert_node_frame, browser_headers,
};
use serde_json::{Value, json};

/// RFC 8291's example application server key pair (appendix A).
const VAPID_PUBLIC: &str =
    "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8";
const VAPID_PRIVATE: &str = "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw";

fn node_headers() -> Vec<(&'static str, String)> {
    vec![
        ("x-pirc-node-id", NODE_ID.to_owned()),
        ("authorization", format!("Bearer {NODE_TOKEN}")),
    ]
}

async fn send(socket: &mut WebSocket, frame: Value) {
    assert_node_frame(&frame);
    socket.send_json(&frame).await;
}

/// The test's node: one directory workspace.
async fn register(cluster: &Cluster) -> WebSocket {
    let mut node = cluster
        .api()
        .connect("/node/connect", &node_headers())
        .await
        .open();
    send(
        &mut node,
        json!({
            "type": "register",
            "role": "node",
            "protocol": pirc_protocol::NODE_PROTOCOL_VERSION, "modes": ["directory"],
            "workspaces": [{ "id": "ws", "displayName": "Fake workspace", "mode": "directory" }],
        }),
    )
    .await;
    let registered = node.next_json().await.expect("registered");
    assert_eq!(registered["type"], "registered");
    assert_eq!(node.next_json().await.expect("modes")["type"], "modes");
    node
}

/// `topicOf` of the TS gateway, to name the Topic header of a session's
/// pushes in the transcript (its tag holds the session's random id).
fn topic_of(tag: &str) -> String {
    let mut hash: i32 = 0;
    for c in tag.chars() {
        let mut units = [0; 2];
        hash = hash
            .wrapping_mul(31)
            .wrapping_add(i32::from(c.encode_utf16(&mut units)[0]));
    }
    let base36 = |mut n: u64| {
        let mut digits = Vec::new();
        loop {
            digits.push(b"0123456789abcdefghijklmnopqrstuvwxyz"[(n % 36) as usize]);
            n /= 36;
            if n == 0 {
                break String::from_utf8(digits.into_iter().rev().collect()).unwrap();
            }
        }
    };
    let topic = format!(
        "t{}{}",
        base36(u64::from(hash as u32)),
        base36(tag.encode_utf16().count() as u64)
    );
    topic.chars().take(32).collect()
}

/// `hex_utf8` of the gateway, for the tag of an exact interaction push.
fn hex_utf8(text: &str) -> String {
    text.as_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn push_notifications() {
    let push = FakePush::start().await.expect("fake push service");
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        env: vec![
            ("PIRC_PUSH_ALLOW_HTTP", "1".to_owned()),
            ("PIRC_VAPID_PUBLIC_KEY", VAPID_PUBLIC.to_owned()),
            ("PIRC_VAPID_PRIVATE_KEY", VAPID_PRIVATE.to_owned()),
        ],
        without_node: true,
        ..GatewayOptions::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let browser = browser_headers();
    let mut node = register(&cluster).await;
    let (started, ()) = tokio::join!(
        FirstSend::new(&api, &browser)
            .workspace("test:ws")
            .start_idle(),
        pirc_conformance::serve_first_send_idle(&mut node, "remote-1"),
    );
    let session = started.id;
    let mut volatile = cluster.volatile();
    volatile.push((push.url().to_owned(), "<push>"));
    volatile.push((
        push.url().trim_start_matches("http://").to_owned(),
        "<push-host>",
    ));
    volatile.push((VAPID_PUBLIC.to_owned(), "<vapid-public-key>"));
    // The Topic header of the session's pushes (its tag holds the session's id).
    volatile.push((
        topic_of(&format!("session:{session}")),
        "<topic of session:<session id>>",
    ));
    // Exact question pushes have the session's id and the interaction's id in
    // their tag, both as hex.
    let interaction_tag =
        |id: &str| format!("interaction:{}:0:{}", hex_utf8(&session), hex_utf8(id));
    volatile.push((
        topic_of(&interaction_tag("i1")),
        "<topic of interaction i1>",
    ));
    volatile.push((interaction_tag("i1"), "<tag of interaction i1>"));
    volatile.push((
        topic_of(&interaction_tag("i2")),
        "<topic of interaction i2>",
    ));
    volatile.push((interaction_tag("i2"), "<tag of interaction i2>"));
    let mut t = Transcript::new(volatile);
    let subscriptions = "/api/push/subscriptions";

    let shown = api.send("GET", "/api/push", &browser, None).await;
    t.response("the key to subscribe with", "GET /api/push", &shown);

    // What the subscription schema refuses.
    let laptop = push.subscribe("laptop", 201, 16);
    let base = laptop.body();
    let with = |change: &dyn Fn(&mut Value)| {
        let mut body = base.clone();
        change(&mut body);
        body
    };
    let invalid: Vec<(&str, Option<Value>)> = vec![
        ("no body", None),
        ("an unknown field", Some(with(&|b| b["extra"] = json!(1)))),
        (
            "an unknown key field",
            Some(with(&|b| b["keys"]["x"] = json!("y"))),
        ),
        (
            "a short p256dh",
            Some(with(&|b| b["keys"]["p256dh"] = json!("A".repeat(79)))),
        ),
        (
            "a p256dh in standard base64",
            Some(with(&|b| {
                b["keys"]["p256dh"] = json!(format!("{}+", "A".repeat(86)))
            })),
        ),
        (
            "a long auth",
            Some(with(&|b| b["keys"]["auth"] = json!("A".repeat(33)))),
        ),
        (
            "an unknown kind",
            Some(with(&|b| b["kind"] = json!("apns"))),
        ),
        ("a null name", Some(with(&|b| b["name"] = Value::Null))),
        (
            "a long name",
            Some(with(&|b| b["name"] = json!("n".repeat(101)))),
        ),
        (
            "an endpoint that is no URL",
            Some(with(&|b| b["endpoint"] = json!("push service"))),
        ),
        (
            "a long endpoint",
            Some(with(&|b| {
                b["endpoint"] = json!(format!("https://p.example/{}", "x".repeat(2000)))
            })),
        ),
        (
            "an ftp endpoint",
            Some(with(&|b| b["endpoint"] = json!("ftp://p.example/x"))),
        ),
        (
            "an endpoint with credentials",
            Some(with(&|b| {
                b["endpoint"] = json!("https://user:secret@p.example/x")
            })),
        ),
    ];
    for (step, body) in invalid {
        let response = api.send("POST", subscriptions, &browser, body).await;
        t.response(
            &format!("subscribe with {step}"),
            "POST /api/push/subscriptions",
            &response,
        );
    }

    let added = api
        .send(
            "POST",
            subscriptions,
            &browser,
            Some(with(&|b| b["name"] = json!("  Laptop  "))),
        )
        .await;
    t.response(
        "subscribe a browser (name trimmed)",
        "POST /api/push/subscriptions",
        &added,
    );
    let again = api
        .send(
            "POST",
            subscriptions,
            &browser,
            Some(with(&|b| {
                b["name"] = json!("   ");
                b["kind"] = json!("unifiedpush");
            })),
        )
        .await;
    t.response(
        "the same endpoint again: refreshed, blank name shows the host",
        "POST /api/push/subscriptions",
        &again,
    );
    let mut ids = vec![added.body["subscription"]["id"].clone()];
    for (name, status, auth) in [
        ("gone", 410, 16),
        ("broken", 500, 16),
        ("moved", 302, 16),
        ("missing", 404, 16),
        // 12 bytes of auth: the schema takes it, the encryption does not.
        ("short-auth", 201, 12),
    ] {
        let subscription = push.subscribe(name, status, auth);
        let mut body = subscription.body();
        body["name"] = json!(name);
        let response = api.send("POST", subscriptions, &browser, Some(body)).await;
        assert_eq!(response.status, 201, "{name}: {}", response.body);
        ids.push(response.body["subscription"]["id"].clone());
    }
    let listed = api.send("GET", "/api/push", &browser, None).await;
    t.response("six places to notify", "GET /api/push", &listed);

    let tested = api.send("POST", "/api/push/test", &browser, None).await;
    t.response("a test notification", "POST /api/push/test", &tested);
    t.note(
        "what the push service received (by path)",
        json!(push.take()),
    );
    let listed = api.send("GET", "/api/push", &browser, None).await;
    t.response(
        "404 and 410 removed the subscription, other failures are counted",
        "GET /api/push",
        &listed,
    );

    // A phone subscribes with its device token; the subscription goes with it.
    let paired = api
        .send(
            "POST",
            "/api/devices",
            &browser,
            Some(json!({ "name": "Phone" })),
        )
        .await;
    let token = paired.body["token"].as_str().unwrap().to_owned();
    let device_id = paired.body["device"]["id"].as_str().unwrap().to_owned();
    let phone = vec![
        ("host", HOST.to_owned()),
        ("x-pirc-client", pirc_conformance::CLIENT.to_owned()),
        ("authorization", format!("Bearer {token}")),
    ];
    let mut body = push.subscribe("phone", 201, 16).body();
    body["kind"] = json!("unifiedpush");
    let response = api.send("POST", subscriptions, &phone, Some(body)).await;
    t.response(
        "a phone subscribes with its device token",
        "POST /api/push/subscriptions",
        &response,
    );
    let response = api.send("GET", "/api/push", &phone, None).await;
    t.response("the phone's view", "GET /api/push", &response);
    let revoked = api
        .send(
            "DELETE",
            &format!("/api/devices/{device_id}"),
            &browser,
            None,
        )
        .await;
    assert_eq!(revoked.status, 204);
    let listed = api.send("GET", "/api/push", &browser, None).await;
    t.response(
        "the phone's subscription went with its token",
        "GET /api/push",
        &listed,
    );

    // A session waiting for its user pushes to them.
    // Three subscriptions are left that the gateway sends to.
    for (step, data) in [
        (
            "an interaction with a title",
            json!({ "id": "i1", "runnerEpoch": 0, "request": { "title": "Allow rm -rf build?" } }),
        ),
        (
            "an interaction with a blank title",
            json!({ "id": "i2", "runnerEpoch": 0, "request": { "title": "  " } }),
        ),
    ] {
        send(
            &mut node,
            json!({ "type": "event", "sessionId": "remote-1",
                "event": { "type": "interaction_created", "data": data } }),
        )
        .await;
        push.wait_for(3).await;
        t.note(&format!("{step}: pushed"), json!(push.take()));
    }

    // Unsubscribing.
    for (step, body) in [
        ("no body", None),
        ("neither endpoint nor id", Some(json!({}))),
        ("an empty endpoint", Some(json!({ "endpoint": "" }))),
        (
            "an unknown field",
            Some(json!({ "id": "x", "extra": true })),
        ),
        ("a long id", Some(json!({ "id": "x".repeat(101) }))),
        ("an unknown id", Some(json!({ "id": "push_unknown" }))),
        (
            "the browser's endpoint",
            Some(json!({ "endpoint": laptop.endpoint })),
        ),
        ("an id", Some(json!({ "id": ids[2] }))),
    ] {
        let response = api.send("DELETE", subscriptions, &browser, body).await;
        t.response(
            &format!("unsubscribe: {step}"),
            "DELETE /api/push/subscriptions",
            &response,
        );
    }
    let listed = api.send("GET", "/api/push", &browser, None).await;
    t.response("what is left", "GET /api/push", &listed);
    let tested = api.send("POST", "/api/push/test", &browser, None).await;
    t.response("nothing delivered", "POST /api/push/test", &tested);
    t.note("received", json!(push.take()));

    insta::assert_json_snapshot!("push_notifications", t.into_value());
}

/// Without configured keys the gateway makes a key pair once and keeps it
/// in its state directory; plain http endpoints are refused by default.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn push_key_and_https() {
    let push = FakePush::start().await.expect("fake push service");
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        without_node: true,
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let browser = browser_headers();
    let mut volatile = cluster.volatile();
    volatile.push((push.url().to_owned(), "<push>"));
    let mut t = Transcript::new(volatile);

    let shown = api.send("GET", "/api/push", &browser, None).await;
    let file = cluster.dir.path().join("gateway-state/vapid.json");
    let stored: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
    let key = shown.body["publicKey"].as_str().unwrap();
    let mut keys: Vec<&String> = stored.as_object().unwrap().keys().collect();
    keys.sort();
    t.note(
        "the generated key pair",
        json!({
            "shown key is the stored one": stored["publicKey"] == key,
            "public key length": key.len(),
            "public key prefix (uncompressed point)": &key[..1],
            "private key length": stored["privateKey"].as_str().unwrap().len(),
            "file keys": keys,
            "file mode": format!("{:o}", std::fs::metadata(&file).unwrap().permissions().mode() & 0o777),
            "subscriptions": shown.body["subscriptions"],
        }),
    );
    let response = api
        .send(
            "POST",
            "/api/push/subscriptions",
            &browser,
            Some(push.subscribe("x", 201, 16).body()),
        )
        .await;
    t.response(
        "a plain http endpoint",
        "POST /api/push/subscriptions",
        &response,
    );
    let tested = api.send("POST", "/api/push/test", &browser, None).await;
    t.response("nowhere to deliver", "POST /api/push/test", &tested);

    insta::assert_json_snapshot!("push_key_and_https", t.into_value());
}
