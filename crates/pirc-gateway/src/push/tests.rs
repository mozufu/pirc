use std::sync::Mutex;

use axum::body::Bytes;
use axum::http::{HeaderMap, StatusCode, Uri};
use p256::ecdsa::VerifyingKey;
use p256::ecdsa::signature::Verifier;

use super::*;
use crate::db::Store;
use crate::events::EventHub;

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
        category: None,
        interaction: None,
    };
    assert_eq!(
        payload(&message, 5, Delivery::default()),
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
        category: Some(Category::NeedsYou),
        interaction: Some(InteractionPush {
            kind: "interaction_answered",
            session_id: "s1".into(),
            interaction_id: Some("memory:p:0".into()),
            interaction_epoch: Some("0".into()),
            answered_by: Some(json!({ "deviceName": "Pixel 9", "at": 7 })),
            ..InteractionPush::default()
        }),
    };
    let revoke: Value = serde_json::from_str(&payload(
        &revoke,
        6,
        Delivery {
            silent: false,
            lock_screen: Some(LockScreen::Hidden),
        },
    ))
    .unwrap();
    assert_eq!(revoke["category"], "needs_you");
    assert_eq!(revoke["lockScreen"], "hidden");
    assert_eq!(
        revoke["answeredBy"],
        json!({ "deviceName": "Pixel 9", "at": 7 })
    );
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
pub(crate) struct Subscriber {
    secret: SecretKey,
    auth: [u8; 16],
}

impl Subscriber {
    pub(crate) fn new() -> Self {
        Self {
            secret: SecretKey::from_slice(&random_bytes::<32>()).unwrap(),
            auth: random_bytes(),
        }
    }

    pub(crate) fn keys(&self) -> SubscriptionKeys {
        SubscriptionKeys {
            p256dh: URL_SAFE_NO_PAD
                .encode(self.secret.public_key().to_encoded_point(false).as_bytes()),
            auth: URL_SAFE_NO_PAD.encode(self.auth),
        }
    }

    pub(crate) fn read(&self, body: &[u8]) -> Value {
        serde_json::from_slice(&decrypt(&self.secret, &self.auth, body)).unwrap()
    }
}

#[derive(Default)]
pub(crate) struct Service {
    status: u16,
    pub(crate) received: Vec<(String, HeaderMap, Bytes)>,
}

/// A push service on loopback that records what it receives and answers `status`.
pub(crate) async fn push_service() -> (String, Arc<Mutex<Service>>) {
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

pub(crate) fn input(
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
        category: None,
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
                category: Some(Category::NeedsYou),
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
    crate::clients::record(
        &push.db.lock(),
        &crate::auth::Identity {
            user: "me".into(),
            device_id: None,
            management_authorized: false,
        },
        "web-1",
        Some("Office iMac"),
        &axum::http::HeaderMap::new(),
    )
    .unwrap();
    events.publish(
        &session.id,
        17,
        "interaction_created",
        json!({ "id": "i1", "runnerEpoch": 0, "kind": "select", "expiresAt": 1234,
                "request": { "title": "Allow rm -rf build?", "options": ["Yes", "No", "Ask later"] } }),
    );
    events.publish(
        &session.id,
        17,
        "interaction_answered",
        json!({ "interactionId": "i1", "interactionEpoch": 0, "answeredBy": "web-1", "resolvedAt": 99 }),
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
    assert_eq!(created["category"], "needs_you");
    assert_eq!(created["expiresAt"], 1234);
    assert_eq!(created["lockScreen"], "title");
    assert_eq!(
        created["choices"],
        json!([{ "id": "Yes", "label": "Yes" }, { "id": "No", "label": "No" }, { "id": "Ask later", "label": "Ask later" }])
    );
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
    assert_eq!(
        answered["answeredBy"],
        json!({ "deviceName": "Office iMac", "at": 99 })
    );
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

#[test]
fn only_a_single_choice_with_three_or_fewer_options_gets_buttons() {
    let options =
        |n: usize| json!({ "options": (0..n).map(|i| format!("o{i}")).collect::<Vec<_>>() });
    assert_eq!(single_choices("select", &options(3)).len(), 3);
    assert!(single_choices("select", &options(4)).is_empty());
    assert!(single_choices("select", &options(0)).is_empty());
    let mut multiple = options(2);
    multiple["multiple"] = json!(true);
    assert!(single_choices("select", &multiple).is_empty());
    assert!(single_choices("confirm", &options(2)).is_empty());
    assert!(single_choices("input", &options(2)).is_empty());
    assert!(single_choices("select", &json!({ "options": ["a", "x".repeat(101)] })).is_empty());
}

#[test]
fn the_agents_other_option_is_not_counted() {
    let other = pirc_protocol::ASK_OTHER_LABEL;
    let with_other = |n: usize| {
        let mut list: Vec<String> = (0..n).map(|i| format!("o{i}")).collect();
        list.push(other.to_owned());
        json!({ "options": list })
    };
    let three = single_choices("select", &with_other(3));
    assert_eq!(three.len(), 4);
    assert!(three[..3].iter().all(|choice| !choice.other));
    assert!(three[3].other);
    assert_eq!(three[3].id, other);
    assert_eq!(
        serde_json::to_value(&three[2..]).unwrap(),
        json!([{ "id": "o2", "label": "o2" }, { "id": other, "label": other, "other": true }])
    );
    assert_eq!(single_choices("select", &with_other(2)).len(), 3);
    assert!(single_choices("select", &with_other(4)).is_empty());
    assert!(
        single_choices("select", &with_other(0)).is_empty(),
        "Other alone"
    );
    // Only a last "Other" is the agent's; elsewhere it is an ordinary option.
    let first = json!({ "options": [other, "a", "b", "c"] });
    assert!(single_choices("select", &first).is_empty());
}

/// 2030-01-01T10:00:00Z.
const T0: i64 = 1_893_492_000_000;
const MINUTE: i64 = 60_000;

fn kind(category: Category, tag: &str) -> PushMessage {
    PushMessage {
        title: format!("{} item", category.as_str()),
        body: "b".into(),
        tag: tag.into(),
        target: json!({ "activity": true }),
        category: Some(category),
        interaction: None,
    }
}

/// One subscriber on a loopback service, its summaries handled up to `mark`.
async fn subscribed(
    patch: Value,
    mark: i64,
) -> (Arc<Push>, Arc<Mutex<Service>>, Subscriber, String) {
    let push = setup();
    let (url, service) = push_service().await;
    let phone = Subscriber::new();
    let added = push
        .subscribe(
            "me",
            &input(&format!("{url}/p"), phone.keys(), "unifiedpush", None),
            None,
        )
        .unwrap();
    let id = added["id"].as_str().unwrap().to_owned();
    let mut patch = patch;
    patch["revision"] = added["revision"].clone();
    let patch: preferences::PreferencesPatch = serde_json::from_value(patch).unwrap();
    push.update_preferences("me", &id, &patch).unwrap();
    push.db
        .lock()
        .execute("UPDATE push_subscriptions SET summary_mark=?", [mark])
        .unwrap();
    (push, service, phone, id)
}

fn received(service: &Mutex<Service>, phone: &Subscriber) -> Vec<Value> {
    service
        .lock()
        .unwrap()
        .received
        .iter()
        .map(|(_, _, body)| phone.read(body))
        .collect()
}

#[tokio::test]
async fn a_category_set_to_off_is_never_sent() {
    let (push, service, phone, _) =
        subscribed(json!({ "levels": { "needs_you": "off" } }), T0).await;
    assert_eq!(
        push.notify_at("me", &kind(Category::NeedsYou, "a"), T0)
            .await,
        0
    );
    // Progress is off by default.
    assert_eq!(
        push.notify_at("me", &kind(Category::Progress, "b"), T0)
            .await,
        0
    );
    assert_eq!(
        push.notify_at("me", &kind(Category::Calendar, "c"), T0)
            .await,
        1
    );
    let got = received(&service, &phone);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0]["category"], "calendar");
    // Nothing was kept for a summary either.
    assert_eq!(push.send_summaries(T0 + 24 * 60 * MINUTE).await, 0);
}

#[tokio::test]
async fn turning_a_category_off_discards_its_queued_summary_items() {
    let (push, service, phone, id) = subscribed(
        json!({
            "timeZone": "UTC",
            "digestAt": "10:10",
            "levels": { "done": "digest", "calendar": "digest" },
        }),
        T0,
    )
    .await;
    assert_eq!(
        push.notify_at("me", &kind(Category::Done, "d1"), T0 + MINUTE)
            .await,
        0
    );
    assert_eq!(
        push.notify_at("me", &kind(Category::Calendar, "c1"), T0 + MINUTE)
            .await,
        0
    );
    assert_eq!(waiting(&push), 2);
    push.update_preferences_at(
        "me",
        &id,
        &patch(2, json!({ "levels": { "done": "off" } })),
        T0 + 2 * MINUTE,
    )
    .unwrap();
    assert_eq!(
        waiting(&push),
        1,
        "only the muted category's item is dropped"
    );
    assert_eq!(
        push.notify_at("me", &kind(Category::Done, "d2"), T0 + 3 * MINUTE)
            .await,
        0,
        "an item decided after the change is skipped"
    );
    assert_eq!(waiting(&push), 1);
    assert_eq!(push.send_summaries(T0 + 10 * MINUTE).await, 1);
    let summary = received(&service, &phone).pop().unwrap();
    assert_eq!(summary["title"], "1 new update");
    assert_eq!(summary["body"], "calendar item");
    assert_eq!(summary["target"]["summary"]["count"], 1);
    assert_eq!(
        summary["target"]["summary"]["categories"],
        json!({ "calendar": 1 })
    );
}

#[tokio::test]
async fn turning_a_category_back_on_does_not_revive_old_summary_items() {
    let (push, service, phone, id) =
        subscribed(json!({ "timeZone": "UTC", "digestAt": "10:10" }), T0).await;
    let mut old = kind(Category::Done, "old");
    old.title = "old done item".into();
    assert_eq!(
        push.notify_at("me", &old, T0 + MINUTE).await,
        0,
        "queued for the digest"
    );
    push.update_preferences_at(
        "me",
        &id,
        &patch(2, json!({ "levels": { "done": "off" } })),
        T0 + 2 * MINUTE,
    )
    .unwrap();
    assert_eq!(waiting(&push), 0, "muting drops the queued item");
    // Turning it back on before the digest does not revive anything either.
    push.update_preferences_at(
        "me",
        &id,
        &patch(3, json!({ "levels": { "done": "digest" } })),
        T0 + 3 * MINUTE,
    )
    .unwrap();
    assert_eq!(push.send_summaries(T0 + 10 * MINUTE).await, 0);
    assert!(received(&service, &phone).is_empty());
    // A new item after the flip is kept and sent normally.
    let mut fresh = kind(Category::Done, "fresh");
    fresh.title = "new done item".into();
    assert_eq!(push.notify_at("me", &fresh, T0 + 11 * MINUTE).await, 0);
    assert_eq!(
        push.send_summaries(T0 + 24 * 60 * MINUTE + 10 * MINUTE)
            .await,
        1
    );
    let summary = received(&service, &phone).pop().unwrap();
    assert_eq!(summary["title"], "1 new update");
    assert_eq!(summary["body"], "new done item");
}

#[tokio::test]
async fn unrelated_preference_changes_keep_queued_summary_items() {
    let (push, service, phone, id) =
        subscribed(json!({ "timeZone": "UTC", "digestAt": "10:10" }), T0).await;
    assert_eq!(
        push.notify_at("me", &kind(Category::Done, "d"), T0 + MINUTE)
            .await,
        0,
        "queued for the digest"
    );
    // A lock-screen or digest-time change does not mute the category, so
    // what waits stays queued.
    push.update_preferences_at(
        "me",
        &id,
        &patch(2, json!({ "lockScreen": "full", "digestAt": "20:00" })),
        T0 + 2 * MINUTE,
    )
    .unwrap();
    assert_eq!(waiting(&push), 1);
    assert_eq!(push.send_summaries(T0 + 10 * 60 * MINUTE).await, 1);
    let summary = received(&service, &phone).pop().unwrap();
    assert_eq!(summary["title"], "1 new update");
    assert_eq!(summary["body"], "done item");
    assert_eq!(summary["lockScreen"], "full");
}

#[tokio::test]
async fn turning_a_category_off_leaves_other_targets_alone() {
    let (push, _service, _phone, id) =
        subscribed(json!({ "timeZone": "UTC", "digestAt": "10:10" }), T0).await;
    let other = push
        .subscribe(
            "me",
            &input(
                "http://127.0.0.1:1/p2",
                Subscriber::new().keys(),
                "web",
                None,
            ),
            None,
        )
        .unwrap();
    let other_id = other["id"].as_str().unwrap().to_owned();
    assert_eq!(
        push.notify_at("me", &kind(Category::Done, "d"), T0 + MINUTE)
            .await,
        0
    );
    push.update_preferences_at(
        "me",
        &id,
        &patch(2, json!({ "levels": { "done": "off" } })),
        T0 + 2 * MINUTE,
    )
    .unwrap();
    let items = |subscription: &str| {
        push.db
            .lock()
            .query_row(
                "SELECT count(*) FROM push_digest_items WHERE subscription_id=?",
                [subscription],
                |r| r.get::<_, i64>(0),
            )
            .unwrap()
    };
    assert_eq!(items(&id), 0);
    assert_eq!(items(&other_id), 1, "the other target keeps its item");
}

#[tokio::test]
async fn quiet_hours_send_questions_silently_and_hold_the_rest_until_they_end() {
    // 09:00–11:00 UTC; T0 is 10:00.
    let (push, service, phone, _) = subscribed(
        json!({
            "quietHours": { "start": "09:00", "end": "11:00" },
            "timeZone": "UTC",
            "levels": { "done": "immediate" },
            "digestAt": "20:00",
        }),
        T0 - 5 * MINUTE,
    )
    .await;
    assert_eq!(
        push.notify_at("me", &kind(Category::NeedsYou, "q"), T0)
            .await,
        1
    );
    assert_eq!(
        push.notify_at("me", &kind(Category::Calendar, "c"), T0)
            .await,
        1
    );
    assert_eq!(
        push.notify_at("me", &kind(Category::Done, "d"), T0).await,
        0,
        "held"
    );
    let got = received(&service, &phone);
    assert_eq!(got.len(), 2);
    assert_eq!(got[0]["silent"], true, "needs_you is silent");
    assert_eq!(got[1].get("silent"), None, "calendar at its own level");
    // No summary while quiet hours last.
    assert_eq!(push.send_summaries(T0 + 30 * MINUTE).await, 0);
    // When they end, one summary lists the held item and nothing else.
    assert_eq!(push.send_summaries(T0 + 61 * MINUTE).await, 1);
    let summary = received(&service, &phone).pop().unwrap();
    assert_eq!(summary["title"], "1 new update");
    assert_eq!(summary["body"], "done item");
    assert_eq!(summary["target"]["summary"]["count"], 1);
    assert_eq!(summary["lockScreen"], "title");
    assert_eq!(push.send_summaries(T0 + 62 * MINUTE).await, 0, "only once");
}

#[tokio::test]
async fn quiet_hours_may_cross_midnight() {
    let (push, service, phone, _) = subscribed(
        json!({
            "quietHours": { "start": "22:00", "end": "07:00" },
            "timeZone": "+08:00",
            "levels": { "progress": "immediate" },
        }),
        T0,
    )
    .await;
    // T0 is 18:00 at +08:00; 23:30 and 06:30 are quiet, 07:00 is not.
    let at = |hours: i64, minutes: i64| T0 + (hours - 18) * 60 * MINUTE + minutes * MINUTE;
    assert_eq!(
        push.notify_at("me", &kind(Category::Progress, "p1"), at(23, 30))
            .await,
        0
    );
    assert_eq!(
        push.notify_at("me", &kind(Category::Progress, "p2"), at(30, 30))
            .await,
        0
    );
    // The digest time (18:00) fell before; nothing was due then.
    assert_eq!(push.send_summaries(at(30, 59)).await, 0);
    assert_eq!(push.send_summaries(at(31, 0)).await, 1);
    let got = received(&service, &phone);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0]["title"], "2 new updates");
    assert_eq!(
        push.notify_at("me", &kind(Category::Progress, "p3"), at(31, 0))
            .await,
        1
    );
}

#[tokio::test]
async fn the_digest_goes_out_at_its_time_and_after_the_gateway_was_offline() {
    let (push, service, phone, _) =
        subscribed(json!({ "timeZone": "UTC", "digestAt": "10:10" }), T0).await;
    // `done` is at level digest by default.
    assert_eq!(
        push.notify_at("me", &kind(Category::Done, "d1"), T0 + MINUTE)
            .await,
        0
    );
    assert_eq!(
        push.notify_at("me", &kind(Category::Done, "d2"), T0 + MINUTE)
            .await,
        0
    );
    assert_eq!(push.send_summaries(T0 + 5 * MINUTE).await, 0, "not yet");
    assert_eq!(push.send_summaries(T0 + 10 * MINUTE).await, 1);
    let summary = received(&service, &phone).pop().unwrap();
    assert_eq!(summary["title"], "2 new updates");
    assert_eq!(summary["body"], "done item · done item");
    assert_eq!(summary["target"]["summary"]["categories"]["done"], 2);
    // Nothing new at the next digest time: no summary.
    assert_eq!(
        push.send_summaries(T0 + 24 * 60 * MINUTE + 10 * MINUTE)
            .await,
        0
    );
    // The Gateway is offline over the next digest time; its first tick sends it.
    push.notify_at("me", &kind(Category::Done, "d3"), T0 + 25 * 60 * MINUTE)
        .await;
    assert_eq!(push.send_summaries(T0 + 50 * 60 * MINUTE).await, 1);
    assert_eq!(received(&service, &phone).len(), 2);
}

#[tokio::test]
async fn preferences_change_with_a_revision() {
    let (app, _dir) = crate::test_support::app_with_models(json!({}));
    app.slots.set(Arc::new(
        Push::new(
            app.db.clone(),
            generate_vapid_keys(),
            "mailto:ops@example.com".into(),
            true,
        )
        .with_time_zone("Asia/Taipei"),
    ));
    let push = app.slots.get::<Push>().unwrap();
    let added = push
        .subscribe(
            "alice",
            &input(
                "http://127.0.0.1:1/p",
                Subscriber::new().keys(),
                "web",
                None,
            ),
            None,
        )
        .unwrap();
    assert_eq!(
        (
            &added["levels"],
            &added["quietHours"],
            &added["timeZone"],
            &added["lockScreen"],
            &added["digestAt"],
            &added["revision"]
        ),
        (
            &json!({ "needs_you": "immediate", "done": "digest", "progress": "off", "calendar": "immediate" }),
            &Value::Null,
            &json!("Asia/Taipei"),
            &json!("title"),
            &json!("18:00"),
            &json!(1)
        )
    );
    let path = format!("/api/push/subscriptions/{}", added["id"].as_str().unwrap());
    let call = |user: &'static str, body: Value| {
        let (app, path) = (app.clone(), path.clone());
        async move {
            crate::test_support::call(&app, "PATCH", &path, Some(user), None, Some(body)).await
        }
    };
    let (status, changed) = call(
        "alice",
        json!({ "revision": 1, "levels": { "done": "off" }, "quietHours": { "start": "22:30", "end": "07:00" },
                "lockScreen": "hidden", "digestAt": "08:15", "timeZone": "Europe/Berlin" }),
    )
    .await;
    assert_eq!(status, 200, "{changed}");
    let changed = &changed["subscription"];
    assert_eq!(changed["revision"], 2);
    assert_eq!(changed["levels"]["done"], "off");
    assert_eq!(changed["levels"]["needs_you"], "immediate");
    assert_eq!(
        changed["quietHours"],
        json!({ "start": "22:30", "end": "07:00" })
    );
    assert_eq!(changed["lockScreen"], "hidden");
    assert_eq!(changed["digestAt"], "08:15");
    assert_eq!(changed["timeZone"], "Europe/Berlin");
    // A stale revision is refused with the current settings.
    let (status, stale) = call("alice", json!({ "revision": 1, "lockScreen": "full" })).await;
    assert_eq!(status, 409);
    assert_eq!(stale["error"]["details"]["subscription"]["revision"], 2);
    let (status, off) = call("alice", json!({ "revision": 2, "quietHours": null })).await;
    assert_eq!(
        (status, &off["subscription"]["quietHours"]),
        (200, &Value::Null)
    );
    for bad in [
        json!({ "revision": 3, "timeZone": "Mars/Base" }),
        json!({ "revision": 3, "quietHours": { "start": "07:00", "end": "07:00" } }),
        json!({ "revision": 3, "digestAt": "24:00" }),
        json!({ "revision": 3, "levels": { "chat": "off" } }),
        json!({ "revision": 3, "levels": { "done": "loud" } }),
        json!({ "revision": 3, "lockScreen": "none" }),
        json!({ "lockScreen": "full" }),
    ] {
        assert_eq!(call("alice", bad.clone()).await.0, 400, "{bad}");
    }
    assert_eq!(call("bob", json!({ "revision": 3 })).await.0, 404);
}

#[test]
fn quiet_hours_and_summary_moments() {
    let prefs = |quiet: Option<(&str, &str)>, zone: &str| Preferences {
        levels: preferences::levels_from_json("{}"),
        quiet_hours: quiet.map(|(start, end)| preferences::QuietHours {
            start: preferences::ClockTime::parse(start).unwrap(),
            end: preferences::ClockTime::parse(end).unwrap(),
        }),
        time_zone: zone.into(),
        lock_screen: LockScreen::Title,
        digest_at: preferences::ClockTime::DIGEST_DEFAULT,
    };
    let crossing = prefs(Some(("22:00", "07:00")), "UTC");
    let utc = |hours: i64, minutes: i64| T0 + (hours - 10) * 60 * MINUTE + minutes * MINUTE;
    assert!(crossing.quiet_at(utc(23, 0)));
    assert!(crossing.quiet_at(utc(30, 59)));
    assert!(!crossing.quiet_at(utc(31, 0)));
    assert!(!crossing.quiet_at(utc(12, 0)));
    assert_eq!(
        crossing.decide(Category::Done, false, utc(23, 0)),
        Decision::Digest
    );
    assert_eq!(
        crossing.decide(Category::NeedsYou, false, utc(23, 0)),
        Decision::SendSilent
    );
    // An update follows the preferences: silent in quiet hours, sent
    // outside them, never for a category at level digest or off.
    assert_eq!(
        crossing.decide(Category::NeedsYou, true, utc(23, 0)),
        Decision::SendSilent
    );
    assert_eq!(
        crossing.decide(Category::NeedsYou, true, utc(12, 0)),
        Decision::Send
    );
    assert_eq!(
        crossing.decide(Category::Done, true, utc(12, 0)),
        Decision::Skip
    );
    assert_eq!(
        crossing.decide(Category::Progress, true, utc(12, 0)),
        Decision::Skip
    );
    assert_eq!(
        crossing.decide(Category::Progress, false, utc(12, 0)),
        Decision::Skip
    );
    // Digest time 18:00 passed after a mark at 17:00.
    assert!(crossing.summary_due(utc(17, 0), utc(18, 0)));
    assert!(!crossing.summary_due(utc(18, 0), utc(19, 0)));
    // Quiet hours ended at 07:00 the next day.
    assert!(crossing.summary_due(utc(18, 0), utc(31, 0)));
    assert!(!crossing.summary_due(utc(18, 0), utc(30, 0)));
    assert!(preferences::ClockTime::parse("7:00").is_none());
    assert!(preferences::ClockTime::parse("23:59").is_some());
}

fn waiting(push: &Push) -> i64 {
    push.db
        .lock()
        .query_row("SELECT count(*) FROM push_digest_items", [], |r| r.get(0))
        .unwrap()
}

#[tokio::test]
async fn a_summary_that_fails_is_kept_and_sent_once_later() {
    let (push, service, phone, _) =
        subscribed(json!({ "timeZone": "UTC", "digestAt": "10:10" }), T0).await;
    push.notify_at("me", &kind(Category::Done, "d1"), T0 + MINUTE)
        .await;
    service.lock().unwrap().status = 500;
    assert_eq!(push.send_summaries(T0 + 10 * MINUTE).await, 0);
    assert_eq!(waiting(&push), 1, "the items stay");
    service.lock().unwrap().status = 201;
    // Two ticks at once send it once.
    let (a, b) = tokio::join!(
        push.send_summaries(T0 + 11 * MINUTE),
        push.send_summaries(T0 + 11 * MINUTE)
    );
    assert_eq!(a + b, 1);
    assert_eq!(waiting(&push), 0);
    assert_eq!(push.send_summaries(T0 + 12 * MINUTE).await, 0);
    let got = received(&service, &phone);
    assert_eq!(got.len(), 2, "one failed try, one summary");
    assert_eq!(got[1]["title"], "1 new update");
}

fn patch(revision: i64, body: Value) -> preferences::PreferencesPatch {
    let mut body = body;
    body["revision"] = json!(revision);
    serde_json::from_value(body).unwrap()
}

#[tokio::test]
async fn a_new_digest_time_counts_from_the_change() {
    let (push, _service, _phone, id) =
        subscribed(json!({ "timeZone": "UTC", "digestAt": "20:00" }), T0).await;
    push.notify_at("me", &kind(Category::Done, "d1"), T0 + MINUTE)
        .await;
    // At 10:05 the digest moves to 10:02: that moment is already past.
    push.update_preferences_at(
        "me",
        &id,
        &patch(2, json!({ "digestAt": "10:02" })),
        T0 + 5 * MINUTE,
    )
    .unwrap();
    assert_eq!(push.send_summaries(T0 + 6 * MINUTE).await, 0);
    assert_eq!(
        push.send_summaries(T0 + 24 * 60 * MINUTE + 2 * MINUTE)
            .await,
        1
    );
}

#[tokio::test]
async fn ending_quiet_hours_by_a_change_sends_what_they_held() {
    let (push, service, phone, id) = subscribed(
        json!({
            "quietHours": { "start": "09:00", "end": "11:00" },
            "timeZone": "UTC",
            "levels": { "done": "immediate" },
        }),
        T0,
    )
    .await;
    assert_eq!(
        push.notify_at("me", &kind(Category::Done, "d"), T0).await,
        0,
        "held"
    );
    push.update_preferences_at(
        "me",
        &id,
        &patch(2, json!({ "quietHours": null })),
        T0 + 5 * MINUTE,
    )
    .unwrap();
    assert_eq!(push.send_summaries(T0 + 6 * MINUTE).await, 1);
    assert_eq!(received(&service, &phone)[0]["body"], "done item");
    assert_eq!(push.send_summaries(T0 + 7 * MINUTE).await, 0);
}

#[test]
fn a_payload_stays_within_one_record() {
    let question = |target_bytes: usize| PushMessage {
        title: "Session is waiting for you".into(),
        body: "b".repeat(200),
        tag: "t".into(),
        target: json!({ "pad": "x".repeat(target_bytes) }),
        category: Some(Category::NeedsYou),
        interaction: Some(InteractionPush {
            kind: "interaction_created",
            session_id: "s".into(),
            choices: (0..3)
                .map(|i| Choice {
                    id: format!("{i}{}", "é".repeat(99)),
                    label: format!("{i}{}", "é".repeat(99)),
                    other: false,
                })
                .collect(),
            ..InteractionPush::default()
        }),
    };
    let fits = payload(&question(100), 1, Delivery::default());
    assert!(fits.contains("\"choices\""));
    let read = |text: &str| serde_json::from_str::<Value>(text).unwrap();
    let no_choices = payload(&question(2200), 1, Delivery::default());
    assert!(
        no_choices.len() <= MAX_PAYLOAD_BYTES,
        "{}",
        no_choices.len()
    );
    assert_eq!(read(&no_choices).get("choices"), None);
    assert_eq!(read(&no_choices)["body"], "b".repeat(200));
    let short = payload(&question(2800), 1, Delivery::default());
    assert!(short.len() <= MAX_PAYLOAD_BYTES, "{}", short.len());
    assert!(read(&short)["body"].as_str().unwrap().chars().count() < 200);
}

#[tokio::test]
async fn a_change_during_a_summary_send_keeps_its_mark_and_flag() {
    let (push, _service, _phone, id) =
        subscribed(json!({ "timeZone": "UTC", "digestAt": "10:10" }), T0).await;
    let revision: i64 = push
        .db
        .lock()
        .query_row("SELECT revision FROM push_subscriptions", [], |r| r.get(0))
        .unwrap();
    // A PATCH lands while the summary is out: a newer revision, a later
    // mark and a summary due now.
    push.db
        .lock()
        .execute(
            "UPDATE push_subscriptions SET revision=revision+1, summary_mark=?, summary_now=1",
            [T0 + 30 * MINUTE],
        )
        .unwrap();
    summary::settle(&push.db.lock(), &id, None, T0 + 10 * MINUTE, revision).unwrap();
    let (mark, now): (i64, i64) = push
        .db
        .lock()
        .query_row(
            "SELECT summary_mark, summary_now FROM push_subscriptions",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!((mark, now), (T0 + 30 * MINUTE, 1));
    // Without a change in between, the flag clears and the mark moves on.
    summary::settle(&push.db.lock(), &id, None, T0 + 40 * MINUTE, revision + 1).unwrap();
    let (mark, now): (i64, i64) = push
        .db
        .lock()
        .query_row(
            "SELECT summary_mark, summary_now FROM push_subscriptions",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!((mark, now), (T0 + 40 * MINUTE, 0));
}
