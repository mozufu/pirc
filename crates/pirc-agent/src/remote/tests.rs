//! `inference-transport.test.ts` (the agent's side) and the catalog part of
//! `agent-remote-inference.test.ts`, against a stand-in for the node's
//! inference socket.

use std::sync::{Arc, Mutex};

use pirc_protocol::{Message, ThinkingLevel, UserContent};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;

use super::*;
use crate::signal::{AbortController, AbortSignal};

const TOKEN: &str = "inference-token";

#[derive(Clone, Debug)]
struct Seen {
    head: String,
    body: Vec<u8>,
}

/// What the stand-in answers: raw pieces written in order, then either
/// closing or holding the connection until the client goes.
#[derive(Clone)]
struct Reply {
    pieces: Vec<Vec<u8>>,
    hang: bool,
}

fn ndjson(lines: &[Value]) -> Reply {
    let body: String = lines.iter().map(|line| format!("{line}\n")).collect();
    Reply {
        pieces: vec![
            format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nContent-Length: {}\r\n\r\n",
                body.len()
            )
            .into_bytes(),
            body.into_bytes(),
        ],
        hang: false,
    }
}

/// A chunked response whose chunks are these byte pieces.
fn chunked(pieces: &[&[u8]], hang: bool) -> Reply {
    let mut out = vec![b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".to_vec()];
    for piece in pieces {
        let mut chunk = format!("{:x};ext=1\r\n", piece.len()).into_bytes();
        chunk.extend_from_slice(piece);
        chunk.extend_from_slice(b"\r\n");
        out.push(chunk);
    }
    if !hang {
        out.push(b"0\r\nTrailer: x\r\n\r\n".to_vec());
    }
    Reply { pieces: out, hang }
}

struct Server {
    config: InferenceConfig,
    seen: Arc<Mutex<Vec<Seen>>>,
    closed: Arc<tokio::sync::Notify>,
    _dir: tempfile::TempDir,
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

async fn serve(reply: impl Fn(&Seen) -> Reply + Send + Sync + 'static) -> Server {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("inference.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let closed = Arc::new(tokio::sync::Notify::new());
    let reply = Arc::new(reply);
    {
        let (seen, closed) = (seen.clone(), closed.clone());
        tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    return;
                };
                let (seen, closed, reply) = (seen.clone(), closed.clone(), reply.clone());
                tokio::spawn(async move {
                    let mut buffer = Vec::new();
                    let mut chunk = [0u8; 4096];
                    let end = loop {
                        if let Some(at) = find(&buffer, b"\r\n\r\n") {
                            break at;
                        }
                        let n = stream.read(&mut chunk).await.unwrap();
                        assert!(n > 0, "client closed early");
                        buffer.extend_from_slice(&chunk[..n]);
                    };
                    let head = String::from_utf8(buffer[..end].to_vec()).unwrap();
                    let length = head
                        .lines()
                        .find_map(|line| line.strip_prefix("Content-Length: "))
                        .map_or(0, |n| n.parse::<usize>().unwrap());
                    let mut body = buffer[end + 4..].to_vec();
                    while body.len() < length {
                        let n = stream.read(&mut chunk).await.unwrap();
                        assert!(n > 0);
                        body.extend_from_slice(&chunk[..n]);
                    }
                    let request = Seen { head, body };
                    seen.lock().unwrap().push(request.clone());
                    let answer = reply(&request);
                    for piece in answer.pieces {
                        if stream.write_all(&piece).await.is_err() {
                            break;
                        }
                        stream.flush().await.unwrap();
                        tokio::time::sleep(std::time::Duration::from_millis(1)).await;
                    }
                    if answer.hang {
                        // Until the agent gives the request up.
                        let _ = stream.read(&mut chunk).await;
                        closed.notify_one();
                    }
                });
            }
        });
    }
    Server {
        config: InferenceConfig {
            socket_path: socket.display().to_string(),
            token: TOKEN.to_owned(),
        },
        seen,
        closed,
        _dir: dir,
    }
}

fn models() -> Models {
    parse_models(&json!({ "providers": { "test": {
        "api": "openai-chat", "baseUrl": "https://secret.invalid", "apiKey": "provider-secret",
        "headers": { "authorization": "header-secret" }, "models": [{ "id": "model" }] } } }))
    .unwrap()
}

fn request(signal: AbortSignal) -> StreamRequest {
    let models = models();
    let provider = models.providers["test"].clone();
    StreamRequest {
        purpose: Default::default(),
        provider_name: "test".to_owned(),
        model: provider.models[0].clone(),
        provider,
        system_prompt: "system".to_owned(),
        messages: vec![Message::User {
            content: UserContent::Text("hello".to_owned()),
            timestamp: 1,
        }],
        tools: Vec::new(),
        thinking: ThinkingLevel::Off,
        session_id: "session".to_owned(),
        signal,
        max_tokens: None,
        tool_choice: None,
    }
}

fn final_message() -> Value {
    json!({ "role": "assistant", "api": "openai-chat", "provider": "test", "model": "model",
        "content": [{ "type": "text", "text": "hello", "textSignature": "sig" }],
        "usage": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0 },
        "stopReason": "stop", "timestamp": 1, "responseId": "response", "canonicalProvider": "openai" })
}

fn assistant(value: &Value) -> AssistantMessage {
    match serde_json::from_value(value.clone()).unwrap() {
        Message::Assistant(message) => message,
        other => panic!("{other:?}"),
    }
}

async fn stream(server: &Server, signal: AbortSignal) -> (AssistantMessage, Vec<String>) {
    let remote = RemoteStream {
        config: server.config.clone(),
    };
    let mut deltas = Vec::new();
    let mut on_delta = |delta: &AssistantDelta| {
        deltas.push(
            serde_json::to_value(delta).unwrap()["type"]
                .as_str()
                .unwrap()
                .to_owned(),
        );
    };
    let message = remote.stream(request(signal), &mut on_delta).await;
    (message, deltas)
}

#[tokio::test]
async fn authenticates_projects_requests_and_keeps_replay_metadata() {
    let server = serve(|seen| {
        if !seen
            .head
            .contains(&format!("Authorization: Bearer {TOKEN}"))
        {
            // As the node answers: 401 with an error event.
            let body = "{\"type\":\"model_error\",\"code\":\"unavailable\"}\n";
            return Reply {
                pieces: vec![
                    format!(
                        "HTTP/1.1 401 Unauthorized\r\nContent-Length: {}\r\n\r\n{body}",
                        body.len()
                    )
                    .into_bytes(),
                ],
                hang: false,
            };
        }
        if seen.head.starts_with("GET /models ") {
            let body =
                json!({ "providers": {}, "inference": { "socketPath": "/s", "token": "t" } })
                    .to_string();
            return Reply {
                pieces: vec![
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}",
                        body.len()
                    )
                    .into_bytes(),
                ],
                hang: false,
            };
        }
        ndjson(&[
            json!({ "type": "model_delta", "delta": { "type": "text_delta", "contentIndex": 0,
                "delta": "hello", "extra": true } }),
            json!({ "type": "model_end", "message": final_message() }),
        ])
    })
    .await;
    let catalog = fetch_remote_models(&server.config).await.unwrap();
    assert_eq!(catalog.inference.unwrap().socket_path, "/s");
    let (message, deltas) = stream(&server, AbortSignal::never()).await;
    assert_eq!(message, assistant(&final_message()));
    assert_eq!(deltas, ["text_delta"]);
    let seen = server.seen.lock().unwrap().clone();
    let sent = String::from_utf8(seen[1].body.clone()).unwrap();
    assert!(seen[1].head.starts_with("POST /inference HTTP/1.1\r\n"));
    assert!(seen[1].head.contains("Content-Type: application/json"));
    for secret in [
        "provider-secret",
        "header-secret",
        "secret.invalid",
        "apiKey",
        "baseUrl",
    ] {
        assert!(!sent.contains(secret), "{sent}");
    }
    assert_eq!(
        sent,
        r#"{"providerName":"test","modelId":"model","systemPrompt":"system","messages":[{"role":"user","content":"hello","timestamp":1}],"tools":[],"thinking":"off","sessionId":"session"}"#
    );

    let wrong = InferenceConfig {
        token: "wrong".to_owned(),
        ..server.config.clone()
    };
    assert_eq!(
        fetch_remote_models(&wrong).await.unwrap_err(),
        "Node model catalog is unavailable"
    );
    let remote = RemoteStream { config: wrong };
    let message = remote
        .stream(request(AbortSignal::never()), &mut |_| {})
        .await;
    assert_eq!(
        message.error_message.as_deref(),
        Some("Gateway inference is unavailable")
    );
}

#[tokio::test]
async fn abort_gives_the_request_up() {
    let server = serve(|_| {
        chunked(
            &[
                br#"{"type":"model_delta","delta":{"type":"text_start","contentIndex":0}}"#,
                b"\n",
            ],
            true,
        )
    })
    .await;
    let controller = AbortController::new();
    let signal = controller.signal();
    let remote = RemoteStream {
        config: server.config.clone(),
    };
    let mut started = false;
    let mut on_delta = |_: &AssistantDelta| started = true;
    let pending = remote.stream(request(signal), &mut on_delta);
    let abort = async {
        tokio::time::sleep(std::time::Duration::from_millis(30)).await;
        controller.abort();
    };
    let (message, ()) = tokio::join!(pending, abort);
    assert!(started);
    assert_eq!(message.stop_reason, StopReason::Aborted);
    assert_eq!(
        message.error_message.as_deref(),
        Some("Inference request cancelled")
    );
    assert!(message.completed_at.is_some());
    assert!(message.content.is_empty());
    assert_eq!(
        (message.api.as_str(), message.provider.as_str()),
        ("openai-chat", "test")
    );
    // The node sees the connection close (and cancels upstream).
    tokio::time::timeout(std::time::Duration::from_secs(5), server.closed.notified())
        .await
        .unwrap();
    assert_eq!(server.seen.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn failures_become_error_messages() {
    let cases: Vec<(Reply, &str)> = vec![
        (
            ndjson(&[json!({ "type": "model_error", "code": "timeout" })]),
            "Inference request timed out",
        ),
        (
            ndjson(&[json!({ "type": "model_error", "code": "inference_failed" })]),
            "Model inference failed",
        ),
        // Ends without model_end.
        (
            ndjson(&[json!({ "type": "model_delta",
                "delta": { "type": "text_start", "contentIndex": 0 } })]),
            "Gateway inference is unavailable",
        ),
        // Not an event.
        (
            ndjson(&[json!({ "type": "model_delta",
                "delta": { "type": "text_start", "contentIndex": -1 } })]),
            "Gateway inference is unavailable",
        ),
        (
            ndjson(&[
                json!({ "type": "model_delta", "delta": { "type": "toolcall_end",
                "contentIndex": 0, "toolCall": { "type": "text", "text": "x" } } }),
            ]),
            "Gateway inference is unavailable",
        ),
        (
            ndjson(&[json!({ "type": "model_end", "message": { "role": "user",
                "content": "x", "timestamp": 1 } })]),
            "Gateway inference is unavailable",
        ),
        (
            ndjson(&[json!({ "type": "model_error", "code": "nope" })]),
            "Gateway inference is unavailable",
        ),
        (
            chunked(&[b"{not json\n"], false),
            "Gateway inference is unavailable",
        ),
        // A final line without its newline.
        (
            chunked(&[final_line().trim_end().as_bytes()], false),
            "Gateway inference is unavailable",
        ),
        // The connection ends mid-chunk.
        (
            Reply {
                pieces: vec![
                    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\nabc".to_vec(),
                ],
                hang: false,
            },
            "Gateway inference is unavailable",
        ),
        // A redirect is refused.
        (
            Reply {
                pieces: vec![
                    b"HTTP/1.1 307 Temporary Redirect\r\nLocation: /x\r\nContent-Length: 0\r\n\r\n"
                        .to_vec(),
                ],
                hang: false,
            },
            "Gateway inference is unavailable",
        ),
    ];
    for (reply, expected) in cases {
        let server = serve(move |_| reply.clone()).await;
        let (message, _) = stream(&server, AbortSignal::never()).await;
        assert_eq!(message.stop_reason, StopReason::Error, "{expected}");
        assert_eq!(message.error_message.as_deref(), Some(expected));
    }
    // Nobody listening.
    let server = serve(|_| ndjson(&[])).await;
    let gone = RemoteStream {
        config: InferenceConfig {
            socket_path: format!("{}-missing", server.config.socket_path),
            token: TOKEN.to_owned(),
        },
    };
    let message = gone
        .stream(request(AbortSignal::never()), &mut |_| {})
        .await;
    assert_eq!(
        message.error_message.as_deref(),
        Some("Gateway inference is unavailable")
    );
}

fn final_line() -> String {
    format!(
        "{}\n",
        json!({ "type": "model_end", "message": final_message() })
    )
}

#[tokio::test]
async fn reassembles_lines_and_characters_split_across_chunks() {
    let text = json!({ "type": "model_delta", "delta": { "type": "text_delta",
        "contentIndex": 0, "delta": "☃ snow" } })
    .to_string();
    let bytes = format!("\n{text}\n\n{}", final_line()).into_bytes();
    // Split inside the snowman's three bytes and inside the final line.
    let at = bytes.iter().position(|b| *b == 0xe2).unwrap() + 1;
    let (a, rest) = bytes.split_at(at);
    let (b, c) = rest.split_at(rest.len() - 20);
    let reply = chunked(&[a, b, c], false);
    let server = serve(move |_| reply.clone()).await;
    let remote = RemoteStream {
        config: server.config.clone(),
    };
    let mut texts = Vec::new();
    let message = remote
        .stream(request(AbortSignal::never()), &mut |delta| {
            if let AssistantDelta::TextDelta { delta, .. } = delta {
                texts.push(delta.clone());
            }
        })
        .await;
    assert_eq!(texts, ["☃ snow"]);
    assert_eq!(message, assistant(&final_message()));
}

#[tokio::test]
async fn refuses_oversize_requests_locally() {
    let server = serve(|_| ndjson(&[])).await;
    let remote = RemoteStream {
        config: server.config.clone(),
    };
    let mut large = request(AbortSignal::never());
    large.system_prompt = "x".repeat(INFERENCE_REQUEST_MAX_BYTES);
    let message = remote.stream(large, &mut |_| {}).await;
    assert_eq!(
        message.error_message.as_deref(),
        Some("Inference transport limit exceeded")
    );
    assert!(server.seen.lock().unwrap().is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_request_past_the_deadline_times_out() {
    let server = serve(|_| chunked(&[], true)).await;
    let (message, _) = stream(&server, AbortSignal::never()).await;
    assert_eq!(message.stop_reason, StopReason::Error);
    assert_eq!(
        message.error_message.as_deref(),
        Some("Inference request timed out")
    );
}

#[tokio::test]
async fn the_catalog_needs_a_good_answer() {
    let server = serve(|seen| {
        if seen.head.contains("Bearer bad-status") {
            return Reply {
                pieces: vec![b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 2\r\n\r\n{}".to_vec()],
                hang: false,
            };
        }
        let body =
            r#"{"providers":{"p":{"api":"openai-completions","baseUrl":"https://x","models":[]}}}"#;
        Reply {
            pieces: vec![format!("HTTP/1.1 200 OK\r\n\r\n{body}").into_bytes()],
            hang: false,
        }
    })
    .await;
    let bad = InferenceConfig {
        token: "bad-status".to_owned(),
        ..server.config.clone()
    };
    assert_eq!(
        fetch_remote_models(&bad).await.unwrap_err(),
        "Node model catalog is unavailable"
    );
    // Read to the end of the connection, then checked.
    assert_eq!(
        fetch_remote_models(&server.config).await.unwrap_err(),
        "providers.p.models: Expected at least one entry"
    );
}

#[test]
fn checks_catalogs_as_the_models_schema_does() {
    let provider = |extra: Value| {
        let mut provider = json!({ "api": "openai-completions", "baseUrl": "https://x",
            "models": [{ "id": "m" }] });
        for (key, value) in extra.as_object().unwrap() {
            provider[key] = value.clone();
        }
        json!({ "providers": { "p": provider } })
    };
    let models = parse_models(&provider(json!({}))).unwrap();
    let model = &models.providers["p"].models[0];
    assert_eq!(
        (model.context_window, model.max_tokens, &model.input),
        (200_000, 32_000, &vec!["text".to_owned()])
    );
    for (extra, error) in [
        (
            json!({ "baseUrl": "not a url" }),
            "providers.p.baseUrl: Expected a URL",
        ),
        (
            json!({ "models": [{ "id": "" }] }),
            "providers.p.models.0.id: Expected a non-empty string",
        ),
        (
            json!({ "models": [{ "id": "m", "contextWindow": 0 }] }),
            "providers.p.models.0.contextWindow: Expected a positive number",
        ),
        (
            json!({ "models": [{ "id": "m", "input": ["text", "audio"] }] }),
            "providers.p.models.0.input.1: Expected 'text' or 'image'",
        ),
    ] {
        assert_eq!(parse_models(&provider(extra)).unwrap_err(), error);
    }
    assert!(parse_models(&json!({ "providers": { "p": { "api": "zzz" } } })).is_err());
    assert_eq!(
        parse_models(&json!({ "inference": { "socketPath": "/s", "token": "" } })).unwrap_err(),
        "inference.token: Expected a non-empty string"
    );
    // Unknown keys are dropped, as zod strips them.
    assert!(parse_models(&json!({ "extra": 1 })).is_ok());
}

#[test]
fn parses_events_as_the_wire_schema_does() {
    assert_eq!(
        parse_event(r#"{"type":"model_error","code":"cancelled"}"#),
        Some(InferenceEvent::Error(InferenceErrorCode::Cancelled))
    );
    assert!(matches!(
        parse_event(&final_line()),
        Some(InferenceEvent::End(_))
    ));
    let call = json!({ "type": "model_delta", "delta": { "type": "toolcall_end", "contentIndex": 1,
        "toolCall": { "type": "toolCall", "id": "c", "name": "read", "arguments": { "path": "a" } } } });
    assert!(matches!(
        parse_event(&call.to_string()),
        Some(InferenceEvent::Delta(AssistantDelta::ToolcallEnd { .. }))
    ));
    assert_eq!(parse_event(r#"{"type":"model_start"}"#), None);
    assert_eq!(parse_event("\r"), None);
}
