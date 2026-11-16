use std::sync::Mutex;

use axum::body::Bytes;
use axum::http::{HeaderMap, StatusCode, Uri};
use p256::ecdsa::VerifyingKey;
use p256::ecdsa::signature::Verifier;

use super::*;

fn b64(text: &str) -> Vec<u8> {
    URL_SAFE_NO_PAD.decode(text).unwrap()
}

/// RFC 8188 decryption of a single-record message, as a browser reads it.
fn decrypt(ua: &SecretKey, auth: &[u8], body: &[u8]) -> Vec<u8> {
    let salt = &body[..16];
    assert_eq!(&body[16..20], &4096u32.to_be_bytes());
    let idlen = body[20] as usize;
    let as_public = &body[21..21 + idlen];
    let shared = p256::ecdh::diffie_hellman(
        ua.to_nonzero_scalar(),
        PublicKey::from_sec1_bytes(as_public).unwrap().as_affine(),
    );
    let ua_public = ua.public_key().to_encoded_point(false);
    let mut ikm = [0; 32];
    Hkdf::<Sha256>::new(Some(auth), shared.raw_secret_bytes())
        .expand(&webpush_info(ua_public.as_bytes(), as_public), &mut ikm)
        .unwrap();
    let (key, nonce) = content_key(&ikm, salt);
    let mut plain = Aes128Gcm::new(&key.into())
        .decrypt(Nonce::from_slice(&nonce), &body[21 + idlen..])
        .unwrap();
    assert_eq!(plain.pop(), Some(2), "the last record's delimiter");
    plain
}

#[test]
fn rfc8291_example() {
    // RFC 8291, appendix A.
    let as_private =
        SecretKey::from_slice(&b64("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")).unwrap();
    let ua_public = b64(
        "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
    );
    let ua_private =
        SecretKey::from_slice(&b64("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94")).unwrap();
    let auth = b64("BTBZMqHH6r4Tts7J_aSIgg");
    let salt: [u8; 16] = b64("DGv6ra1nlYgDCS1FRnbzlw").try_into().unwrap();
    let plaintext = b"When I grow up, I want to be a watermelon";
    let message = encrypt(&ua_public, &auth, plaintext, &salt, &as_private).unwrap();
    assert_eq!(
        URL_SAFE_NO_PAD.encode(&message),
        "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
    );
    assert_eq!(
        URL_SAFE_NO_PAD.encode(as_private.public_key().to_encoded_point(false).as_bytes()),
        "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
    );
    assert_eq!(decrypt(&ua_private, &auth, &message), plaintext);
}

#[test]
fn long_payloads_span_records() {
    let ua = SecretKey::from_slice(&random_bytes::<32>()).unwrap();
    let ua_public = ua.public_key().to_encoded_point(false);
    let auth = random_bytes::<16>();
    let plaintext = vec![b'x'; 5000];
    let local = SecretKey::from_slice(&random_bytes::<32>()).unwrap();
    let message = encrypt(ua_public.as_bytes(), &auth, &plaintext, &[7; 16], &local).unwrap();
    // Header, one full record (4079 bytes + delimiter 1 + tag), the rest (+ delimiter 2 + tag).
    assert_eq!(message.len(), 86 + 4096 + (5000 - 4079) + 17);
    let shared = p256::ecdh::diffie_hellman(ua.to_nonzero_scalar(), local.public_key().as_affine());
    let mut ikm = [0; 32];
    Hkdf::<Sha256>::new(Some(&auth), shared.raw_secret_bytes())
        .expand(
            &webpush_info(
                ua_public.as_bytes(),
                local.public_key().to_encoded_point(false).as_bytes(),
            ),
            &mut ikm,
        )
        .unwrap();
    let (key, nonce) = content_key(&ikm, &[7; 16]);
    let cipher = Aes128Gcm::new(&key.into());
    let first = cipher
        .decrypt(
            Nonce::from_slice(&record_nonce(&nonce, 0)),
            &message[86..86 + 4096],
        )
        .unwrap();
    let second = cipher
        .decrypt(
            Nonce::from_slice(&record_nonce(&nonce, 1)),
            &message[86 + 4096..],
        )
        .unwrap();
    assert_eq!((first.len(), first[4079]), (4080, 1));
    assert_eq!(second.last(), Some(&2));
}

#[test]
fn vapid_keys_are_kept_or_taken_from_the_environment() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let none = Env::new([], "/");
    let first = load_vapid_keys(&state, &none).unwrap();
    assert_eq!(load_vapid_keys(&state, &none).unwrap(), first);
    let file = state.join("vapid.json");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        fs::metadata(&file).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let stored: Value = serde_json::from_str(&fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(stored["publicKey"], first.public_key.as_str());
    assert_eq!(b64(&first.public_key).len(), 65);
    assert_eq!(b64(&first.private_key).len(), 32);
    let env = Env::new(
        [
            ("PIRC_VAPID_PUBLIC_KEY", " pub "),
            ("PIRC_VAPID_PRIVATE_KEY", "priv"),
        ],
        "/",
    );
    assert_eq!(
        load_vapid_keys(&state, &env).unwrap(),
        VapidKeys {
            public_key: "pub".into(),
            private_key: "priv".into()
        }
    );
    let error =
        load_vapid_keys(&state, &Env::new([("PIRC_VAPID_PUBLIC_KEY", "pub")], "/")).unwrap_err();
    assert!(error.contains("both"));
    fs::write(&file, "{}").unwrap();
    assert!(
        load_vapid_keys(&state, &none)
            .unwrap_err()
            .contains("holds no VAPID key pair")
    );
}

#[test]
fn vapid_authorization_is_a_signed_jwt() {
    let keys = generate_vapid_keys();
    let header = vapid_authorization(
        "https://push.example",
        "mailto:ops@example.com",
        &keys,
        1_700_000_000_999,
    )
    .unwrap();
    let rest = header.strip_prefix("vapid t=").unwrap();
    let (jwt, key) = rest.split_once(", k=").unwrap();
    assert_eq!(key, keys.public_key);
    let parts: Vec<&str> = jwt.split('.').collect();
    assert_eq!(b64(parts[0]), br#"{"typ":"JWT","alg":"ES256"}"#);
    assert_eq!(
        String::from_utf8(b64(parts[1])).unwrap(),
        r#"{"aud":"https://push.example","exp":1700043200,"sub":"mailto:ops@example.com"}"#
    );
    let verifying = VerifyingKey::from_sec1_bytes(&b64(&keys.public_key)).unwrap();
    let signature = Signature::from_slice(&b64(parts[2])).unwrap();
    verifying
        .verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &signature)
        .unwrap();
    // Keys that do not fit fail the send, not the gateway.
    let bad = VapidKeys {
        public_key: "pub".into(),
        private_key: keys.private_key.clone(),
    };
    assert!(vapid_authorization("https://p", "mailto:a@b", &bad, 0).is_err());
    assert!(vapid_authorization("https://p", "http://a", &keys, 0).is_err());
}

#[test]
fn audiences_topics_and_payloads_as_web_push_made_them() {
    assert_eq!(
        audience("https://Push.Example:443/x").unwrap(),
        "https://push.example:443"
    );
    assert_eq!(
        audience("http://127.0.0.1:8080/a?b").unwrap(),
        "http://127.0.0.1:8080"
    );
    assert_eq!(audience("https://[::1]:99/x").unwrap(), "https://[::1]:99");
    assert_eq!(audience("https://u@h.com/x").unwrap(), "https://h.com");
    // Values from the TS `topicOf`.
    for (tag, topic) in [
        ("test", "t2487m4"),
        (
            "session:session_0b1c6b8e-5d7a-4b55-9a3e-1c2d3e4f5a6b",
            "th8rv5x1g",
        ),
        ("", "t00"),
        ("x😀y", "t139784"),
        ("delegation:abc", "tmhb3f4e"),
    ] {
        assert_eq!(topic_of(tag), topic, "{tag}");
    }
    assert_eq!(js_json_string(&clip("ab😀", 3)), r#""ab…""#);
    assert_eq!(js_json_string(&clip("a   b", 3)), r#""a…""#);
    let message = PushMessage {
        title: format!("{}  tail", "t".repeat(119)),
        body: "b".into(),
        tag: "a\u{1}\"\\\n".into(),
        target: json!({ "sessionId": "s" }),
        interaction: None,
    };
    assert_eq!(
        payload(&message, 5),
        format!(
            r#"{{"title":"{}…","body":"b","tag":"a\u0001\"\\\n","target":{{"sessionId":"s"}},"at":5}}"#,
            "t".repeat(119)
        )
    );
    let revoke = PushMessage {
        title: String::new(),
        body: String::new(),
        tag: "interaction:7331:0:6d656d6f72793a703a30".into(),
        target: json!({ "sessionId": "s1" }),
        interaction: Some(InteractionPush {
            kind: "interaction_answered",
            session_id: "s1".into(),
            interaction_id: Some("memory:p:0".into()),
            interaction_epoch: Some("0".into()),
        }),
    };
    let revoke: Value = serde_json::from_str(&payload(&revoke, 6)).unwrap();
    assert_eq!(revoke["kind"], "interaction_answered");
    assert_eq!(revoke["sessionId"], "s1");
    assert_eq!(revoke["interactionId"], "memory:p:0");
    assert_eq!(revoke["interactionEpoch"], "0");
    assert_eq!(revoke["tag"], "interaction:7331:0:6d656d6f72793a703a30");
    // Half a surrogate pair, as `JSON.stringify` writes it.
    assert_eq!(js_json_string(&clip("a😀bc", 3)), r#""a\ud83d…""#);
    assert!(key_shaped(&"a".repeat(80), 80, 100));
    assert!(key_shaped(&format!("{}==", "a".repeat(87)), 80, 100));
    assert!(!key_shaped(&format!("{}===", "a".repeat(87)), 80, 100));
    assert!(!key_shaped(&"a".repeat(79), 80, 100));
    assert!(!key_shaped(&format!("{}+", "a".repeat(87)), 80, 100));
}

/// A browser's push subscription keys.
struct Subscriber {
    secret: SecretKey,
    auth: [u8; 16],
}

impl Subscriber {
    fn new() -> Self {
        Self {
            secret: SecretKey::from_slice(&random_bytes::<32>()).unwrap(),
            auth: random_bytes(),
        }
    }

    fn keys(&self) -> SubscriptionKeys {
        SubscriptionKeys {
            p256dh: URL_SAFE_NO_PAD
                .encode(self.secret.public_key().to_encoded_point(false).as_bytes()),
            auth: URL_SAFE_NO_PAD.encode(self.auth),
        }
    }

    fn read(&self, body: &[u8]) -> Value {
        serde_json::from_slice(&decrypt(&self.secret, &self.auth, body)).unwrap()
    }
}

#[derive(Default)]
struct Service {
    status: u16,
    received: Vec<(String, HeaderMap, Bytes)>,
}

/// A push service on loopback that records what it receives and answers `status`.
async fn push_service() -> (String, Arc<Mutex<Service>>) {
    let service = Arc::new(Mutex::new(Service {
        status: 201,
        received: Vec::new(),
    }));
    let state = service.clone();
    let app = Router::new().fallback(move |uri: Uri, headers: HeaderMap, body: Bytes| {
        let state = state.clone();
        async move {
            let mut service = state.lock().unwrap();
            service
                .received
                .push((uri.path().to_owned(), headers, body));
            StatusCode::from_u16(service.status).unwrap()
        }
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await });
    (url, service)
}

fn setup() -> Arc<Push> {
    Arc::new(Push::new(
        Arc::new(Db::memory()),
        generate_vapid_keys(),
        "mailto:ops@example.com".into(),
        true,
    ))
}

fn input(
    endpoint: &str,
    keys: SubscriptionKeys,
    kind: &str,
    name: Option<&str>,
) -> SubscriptionInput {
    SubscriptionInput {
        endpoint: endpoint.into(),
        keys,
        kind: Some(kind.into()),
        name: name.map(Into::into),
    }
}

fn message(tag: &str) -> PushMessage {
    PushMessage {
        title: "t".into(),
        body: "b".into(),
        tag: tag.into(),
        target: json!({ "memory": true }),
        interaction: None,
    }
}

#[tokio::test]
async fn sends_encrypted_signed_notifications_only_the_subscriber_can_read() {
    let push = setup();
    let (url, service) = push_service().await;
    let browser = Subscriber::new();
    push.subscribe(
        "me",
        &input(&format!("{url}/me"), browser.keys(), "web", None),
        None,
    )
    .unwrap();
    let delivered = push
        .notify(
            "me",
            &PushMessage {
                title: "CI check failed".into(),
                body: "Scheduled run: open it to read the result.".into(),
                tag: "session:s1".into(),
                target: json!({ "sessionId": "s1" }),
                interaction: None,
            },
        )
        .await;
    assert_eq!(delivered, 1);
    let (path, headers, body) = service.lock().unwrap().received[0].clone();
    assert_eq!(path, "/me");
    let header = |name: &str| headers.get(name).unwrap().to_str().unwrap().to_owned();
    assert_eq!(header("content-encoding"), "aes128gcm");
    assert_eq!(header("content-type"), "application/octet-stream");
    assert_eq!(header("ttl"), "86400");
    assert_eq!(header("urgency"), "normal");
    assert_eq!(header("topic"), topic_of("session:s1"));
    assert!(header("authorization").starts_with("vapid t="));
    assert!(!String::from_utf8_lossy(&body).contains("CI check"));
    let read = browser.read(&body);
    assert_eq!(read["title"], "CI check failed");
    assert_eq!(read["tag"], "session:s1");
    assert_eq!(read["target"], json!({ "sessionId": "s1" }));
    assert!(read["at"].is_i64());

    // Nobody else's notifications.
    assert_eq!(push.notify("someone-else", &message("t")).await, 0);
    assert_eq!(service.lock().unwrap().received.len(), 1);
}

#[tokio::test]
async fn lists_refreshes_and_removes_subscriptions_and_drops_dead_ones() {
    let push = setup();
    let (url, service) = push_service().await;
    let browser = Subscriber::new();
    let strict = Push::new(
        Arc::new(Db::memory()),
        generate_vapid_keys(),
        "mailto:a@b.c".into(),
        false,
    );
    let refused = strict
        .subscribe(
            "me",
            &input("http://push.example/x", browser.keys(), "web", None),
            None,
        )
        .unwrap_err();
    assert!(refused.message.contains("https"));
    let refused = strict
        .subscribe(
            "me",
            &input("https://u:p@push.example/x", browser.keys(), "web", None),
            None,
        )
        .unwrap_err();
    assert!(refused.message.contains("credentials"));

    let a = format!("{url}/a");
    let first = push
        .subscribe(
            "me",
            &input(&a, browser.keys(), "web", Some("Firefox")),
            None,
        )
        .unwrap();
    // The same endpoint again refreshes it rather than adding one.
    let again = push
        .subscribe(
            "me",
            &input(&a, browser.keys(), "web", Some("Firefox")),
            None,
        )
        .unwrap();
    assert_eq!(again["id"], first["id"]);
    push.subscribe(
        "me",
        &input(
            &format!("{url}/b"),
            Subscriber::new().keys(),
            "unifiedpush",
            Some("Pixel"),
        ),
        None,
    )
    .unwrap();
    let listed: Vec<(Value, Value)> = push
        .list("me")
        .unwrap()
        .into_iter()
        .map(|item| (item["kind"].clone(), item["name"].clone()))
        .collect();
    assert_eq!(
        listed,
        [
            (json!("web"), json!("Firefox")),
            (json!("unifiedpush"), json!("Pixel"))
        ]
    );

    // The push service says the subscription is gone: it goes here too.
    service.lock().unwrap().status = 410;
    assert_eq!(push.notify("me", &message("x")).await, 0);
    assert!(push.list("me").unwrap().is_empty());

    // A failing service is counted, not thrown.
    let c = format!("{url}/c");
    let added = push
        .subscribe("me", &input(&c, browser.keys(), "web", None), None)
        .unwrap();
    assert_eq!(added["name"], url.trim_start_matches("http://"));
    service.lock().unwrap().status = 500;
    assert_eq!(push.notify("me", &message("x")).await, 0);
    assert_eq!(push.list("me").unwrap()[0]["failing"], true);

    // Another user's subscription of the endpoint replaces it.
    let taken = push
        .subscribe("you", &input(&c, browser.keys(), "web", None), None)
        .unwrap();
    assert_ne!(taken["id"], added["id"]);
    assert!(push.list("me").unwrap().is_empty());
    assert!(push.unsubscribe("you", Some(&c), None).unwrap());
    assert!(!push.unsubscribe("you", None, Some("push_none")).unwrap());
    assert!(push.list("you").unwrap().is_empty());
}

#[tokio::test]
async fn drops_a_subscription_after_twenty_failures() {
    let push = setup();
    let (url, service) = push_service().await;
    service.lock().unwrap().status = 500;
    push.subscribe(
        "me",
        &input(&format!("{url}/x"), Subscriber::new().keys(), "web", None),
        None,
    )
    .unwrap();
    for _ in 0..19 {
        push.notify("me", &message("x")).await;
    }
    assert_eq!(push.list("me").unwrap().len(), 1);
    push.notify("me", &message("x")).await;
    assert!(push.list("me").unwrap().is_empty());
}

#[test]
fn drops_a_phone_subscription_with_its_device_token() {
    let push = setup();
    push.db
            .lock()
            .execute(
                "INSERT INTO device_tokens (id, owner_user, name, token_hash, created_at, expires_at, last_used_at) VALUES ('dev1','me','Pixel','h',1,9999999999999,1)",
                [],
            )
            .unwrap();
    push.subscribe(
        "me",
        &input(
            "http://127.0.0.1:1/p",
            Subscriber::new().keys(),
            "unifiedpush",
            None,
        ),
        Some("dev1"),
    )
    .unwrap();
    assert_eq!(push.list("me").unwrap().len(), 1);
    push.db
        .lock()
        .execute("DELETE FROM device_tokens WHERE id='dev1'", [])
        .unwrap();
    assert!(push.list("me").unwrap().is_empty());
}

#[test]
fn validates_subscriptions_like_the_schema() {
    let keys = Subscriber::new().keys();
    let parse = |body: Value| {
        crate::http::Body::Json(body)
            .parse::<SubscriptionInput>()
            .and_then(SubscriptionInput::validate)
    };
    let valid = parse(json!({ "endpoint": "https://p.example/x", "keys": { "p256dh": keys.p256dh, "auth": keys.auth }, "name": "  Laptop " })).unwrap();
    assert_eq!(
        (valid.kind.as_deref(), valid.name.as_deref()),
        (Some("web"), Some("Laptop"))
    );
    for body in [
        json!({ "endpoint": "not a url", "keys": { "p256dh": keys.p256dh, "auth": keys.auth } }),
        json!({ "endpoint": "https://p/x", "keys": { "p256dh": "short", "auth": keys.auth } }),
        json!({ "endpoint": "https://p/x", "keys": { "p256dh": keys.p256dh, "auth": keys.auth, "x": 1 } }),
        json!({ "endpoint": "https://p/x", "keys": { "p256dh": keys.p256dh, "auth": keys.auth }, "kind": "apns" }),
        json!({ "endpoint": "https://p/x", "keys": { "p256dh": keys.p256dh, "auth": keys.auth }, "name": null }),
        json!({ "endpoint": "https://p/x", "keys": { "p256dh": keys.p256dh, "auth": keys.auth }, "name": "n".repeat(101) }),
        json!({ "endpoint": format!("https://p/{}", "x".repeat(2000)), "keys": { "p256dh": keys.p256dh, "auth": keys.auth } }),
    ] {
        assert!(parse(body.clone()).is_err(), "{body}");
    }
}

#[tokio::test]
async fn pushes_when_a_session_starts_waiting_for_its_user() {
    let push = setup();
    let (url, service) = push_service().await;
    let browser = Subscriber::new();
    push.subscribe(
        "me",
        &input(&format!("{url}/me"), browser.keys(), "web", None),
        None,
    )
    .unwrap();
    let session = {
        let conn = push.db.lock();
        conn.sync_remote_workspaces(
            "work",
            &[(
                "pirc".into(),
                "pirc".into(),
                crate::db::ModeId::new("directory").unwrap(),
            )],
        )
        .unwrap();
        conn.create_session("work:pirc", "node://work/r1", "work", "r1", "me")
            .unwrap()
    };
    let events = EventHub::new(100);
    watch_interactions(&events, push.db.clone(), push.clone());
    events.publish(
        &session.id,
        17,
        "interaction_created",
        json!({ "id": "i1", "runnerEpoch": 0, "request": { "title": "Allow rm -rf build?" } }),
    );
    events.publish(
        &session.id,
        17,
        "interaction_answered",
        json!({ "interactionId": "i1", "interactionEpoch": 0 }),
    );
    events.publish("unknown", 0, "interaction_created", json!({}));
    for _ in 0..100 {
        if service.lock().unwrap().received.len() >= 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    tokio::time::sleep(Duration::from_millis(100)).await;
    let received = service.lock().unwrap().received.clone();
    assert_eq!(received.len(), 2);
    let payloads: Vec<Value> = received.iter().map(|item| browser.read(&item.2)).collect();
    let created = payloads
        .iter()
        .find(|payload| payload["kind"] == "interaction_created")
        .unwrap();
    assert_eq!(
        created["title"],
        format!("{} is waiting for you", session.name)
    );
    assert_eq!(created["body"], "Allow rm -rf build?");
    assert_eq!(created["interactionId"], "i1");
    assert_eq!(created["interactionEpoch"], "0");
    assert_eq!(
        created["tag"],
        format!("interaction:{}:0:6931", hex_utf8(&session.id))
    );
    assert_eq!(created["target"], json!({ "sessionId": session.id }));
    let answered = payloads
        .iter()
        .find(|payload| payload["kind"] == "interaction_answered")
        .unwrap();
    assert_eq!(answered["title"], "");
    assert_eq!(answered["interactionId"], "i1");
    assert_eq!(answered["interactionEpoch"], "0");
    assert_eq!(answered["tag"], created["tag"]);
    assert_eq!(answered["target"], json!({ "sessionId": session.id }));

    let conn = push.db.lock();
    let (_, refresh) =
        answered_message(&conn, &session.id, Some(&json!({ "interactionId": "i1" }))).unwrap();
    assert_eq!(
        refresh.interaction.as_ref().unwrap().kind,
        "interaction_refresh"
    );
    assert_eq!(refresh.tag, format!("session:{}", session.id));
    assert_eq!(refresh.interaction.as_ref().unwrap().interaction_id, None);

    let (_, untitled) = waiting_message(
        &conn,
        &session.id,
        Some(&json!({ "request": { "title": "  " } })),
    )
    .unwrap();
    assert_eq!(untitled.body, "It needs your answer to go on.");
    let (_, no_data) = waiting_message(&conn, &session.id, None).unwrap();
    assert_eq!(no_data.body, "It needs your answer to go on.");
}

#[tokio::test]
async fn the_test_notification_needs_the_request_shape() {
    use crate::request_shape::tests::{
        USER, accepted_empty, fixture, forged, identities, is_shape_rejection, send,
    };
    let (app, _dir) = fixture();
    app.slots.set(Arc::new(Push::new(
        app.db.clone(),
        generate_vapid_keys(),
        "mailto:ops@example.com".into(),
        true,
    )));
    let (url, service) = push_service().await;
    let browser = Subscriber::new();
    let push = app.slots.get::<Push>().unwrap();
    push.subscribe(
        USER,
        &input(&format!("{url}/me"), browser.keys(), "web", None),
        None,
    )
    .unwrap();
    let received = || service.lock().unwrap().received.len();
    for who in identities(&app, USER) {
        let untouched = received();
        for form in forged() {
            let (status, body) = send(&app, &who, "POST", "/api/push/test", &form).await;
            assert!(
                is_shape_rejection(status, &body),
                "{}: {status} {body}",
                form.name
            );
            assert_eq!(received(), untouched, "{} sent a notification", form.name);
        }
        for shape in accepted_empty() {
            let before = received();
            let (status, body) = send(&app, &who, "POST", "/api/push/test", &shape).await;
            assert_eq!(status, 200, "{}: {body}", shape.name);
            assert_eq!(body["delivered"], 1);
            assert_eq!(received(), before + 1);
        }
    }
}
