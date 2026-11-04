//! Side-panel terminals on a real node (`apps/gateway/src/node/terminals.ts`,
//! the terminal part of `node/panel-routes.ts`), through a real gateway's
//! REST routes and its terminal stream WebSocket
//! (`/api/sessions/:id/terminals/:terminalId/stream`). The shell is
//! `/bin/sh` (`PIRC_TERMINAL_SHELL`); its prompt and echo are not part of
//! the contract, so output is matched only on markers the typed commands
//! compute (`printf 'MARK-%s\n' $((6*7))` prints `MARK-42`, its echo does
//! not). Recorded from the TS node (docs/development/historical-records.md).

mod node_sessions_support;

use node_sessions_support::{Session, replace_all};
use pirc_conformance::{
    Api, Cluster, Connection, GatewayOptions, Response, Transcript, USER, WebSocket,
    browser_headers,
};
use serde_json::{Value, json};

const OTHER_USER: &str = "other@example.com";

fn terminal_env() -> GatewayOptions {
    let users = format!("{USER},{OTHER_USER}");
    GatewayOptions {
        env: vec![("PIRC_ALLOWED_USERS", users.clone())],
        node_env: vec![
            ("PIRC_TERMINAL_SHELL", "/bin/sh".to_owned()),
            ("PIRC_ALLOWED_USERS", users),
        ],
        ..GatewayOptions::default()
    }
}

/// Terminal ids (8 hex characters) become `<terminal-N>` in transcripts.
#[derive(Default)]
struct Ids(Vec<(String, String)>);

impl Ids {
    fn learn(&mut self, response: &Response) -> String {
        let id = response.body["terminal"]["id"]
            .as_str()
            .expect("terminal id")
            .to_owned();
        if !self.0.iter().any(|(known, _)| *known == id) {
            let name = format!("<terminal-{}>", self.0.len() + 1);
            self.0.push((id.clone(), name));
        }
        id
    }

    fn value(&self, value: &Value) -> Value {
        replace_all(value, &self.0)
    }

    fn response(&self, response: &Response) -> Response {
        Response {
            body: self.value(&response.body),
            ..response.clone()
        }
    }
}

/// Text frames until `marker` shows up in the output; returns the
/// non-output frames and the output.
async fn output_until(socket: &mut WebSocket, marker: &str) -> (Vec<Value>, String) {
    output_when(socket, |output| output.contains(marker)).await
}

/// Text frames until the output holds a whole line printing each prefix;
/// returns the rest of those lines. One read for all of them: a later
/// line may arrive in the same frame as an earlier one.
async fn output_lines(socket: &mut WebSocket, prefixes: &[&str]) -> Vec<String> {
    let (_, output) = output_when(socket, |output| {
        prefixes.iter().all(|prefix| line(output, prefix).is_some())
    })
    .await;
    prefixes
        .iter()
        .map(|prefix| line(&output, prefix).unwrap())
        .collect()
}

async fn output_line(socket: &mut WebSocket, prefix: &str) -> String {
    output_lines(socket, &[prefix]).await.remove(0)
}

/// What follows `prefix` up to the end of its line, in the first complete
/// line printing it (not the echo of the command: there `%s` follows).
fn line(output: &str, prefix: &str) -> Option<String> {
    let complete = &output[..output.rfind('\n')? + 1];
    complete.lines().find_map(|line| {
        let rest = &line[line.find(prefix)? + prefix.len()..];
        (!rest.starts_with("%s")).then(|| rest.trim_end_matches('\r').to_owned())
    })
}

async fn output_when(socket: &mut WebSocket, done: impl Fn(&str) -> bool) -> (Vec<Value>, String) {
    let mut others = Vec::new();
    let mut output = String::new();
    loop {
        match socket.next_json().await {
            Ok(frame) if frame["type"] == "output" => {
                output.push_str(frame["data"].as_str().unwrap_or_default());
                if done(&output) {
                    return (others, output);
                }
            }
            Ok(frame) => others.push(frame),
            Err(close) => panic!("closed with {close:?}; output {output:?}"),
        }
    }
}

/// Frames until one that is not output; returns it and the output before it.
async fn next_event(socket: &mut WebSocket) -> Result<(Value, String), (u16, String)> {
    let mut output = String::new();
    loop {
        let frame = socket.next_json().await?;
        if frame["type"] == "output" {
            output.push_str(frame["data"].as_str().unwrap_or_default());
        } else {
            return Ok((frame, output));
        }
    }
}

/// Non-output frames until the socket closes, and the close.
async fn until_closed(socket: &mut WebSocket) -> (Vec<Value>, (u16, String)) {
    let mut frames = Vec::new();
    loop {
        match next_event(socket).await {
            Ok((frame, _)) => frames.push(frame),
            Err(close) => return (frames, close),
        }
    }
}

/// The `ready` frame without its replay (prompt noise), plus which
/// markers the replay holds.
fn ready(frame: &Value, markers: &[&str]) -> Value {
    let replay = frame["replay"].as_str().unwrap_or_default();
    let mut frame = frame.clone();
    frame.as_object_mut().unwrap().remove("replay");
    let held: Vec<&str> = markers
        .iter()
        .copied()
        .filter(|marker| replay.contains(marker))
        .collect();
    json!({ "frame": frame, "replay holds": held })
}

fn close(close: (u16, String)) -> Value {
    json!({ "code": close.0, "reason": close.1 })
}

async fn stream(
    api: &Api,
    session: &str,
    terminal: &str,
    headers: &[(&str, String)],
) -> Connection {
    api.connect(
        &format!("/api/sessions/{session}/terminals/{terminal}/stream"),
        headers,
    )
    .await
}

#[tokio::test(flavor = "multi_thread")]
async fn node_terminals() {
    let Some(cluster) = Cluster::start_with(terminal_env()).await else {
        return;
    };
    let api = cluster.api();
    let headers = browser_headers();
    let other: Vec<(&str, String)> = headers
        .iter()
        .map(|(name, value)| {
            let value = if *name == "x-pirc-user" {
                OTHER_USER.to_owned()
            } else {
                value.clone()
            };
            (*name, value)
        })
        .collect();
    let mut t = Transcript::new(cluster.volatile());
    let mut ids = Ids::default();
    let (mut s, _) = Session::create(&api).await;
    let lease =
        |s: &Session| json!({ "clientId": s.client.clone(), "generation": s.generation.clone() });

    t.response(
        "list before any terminal",
        "GET /api/sessions/:id/terminals",
        &s.get("/terminals").await,
    );
    let refused = s
        .post(
            "/terminals",
            json!({ "clientId": "browser", "generation": 1 }),
        )
        .await;
    t.response(
        "open without control",
        "POST /api/sessions/:id/terminals",
        &refused,
    );
    let refused = s.post("/terminals", json!({ "clientId": "browser" })).await;
    t.response(
        "open without a generation",
        "POST /api/sessions/:id/terminals",
        &refused,
    );
    s.acquire().await;
    let mut body = lease(&s);
    body["cols"] = json!(100);
    body["rows"] = json!(30);
    let opened = s.post("/terminals", body).await;
    let first = ids.learn(&opened);
    t.response(
        "open a 100x30 terminal",
        "POST /api/sessions/:id/terminals",
        &ids.response(&opened),
    );
    let mut body = lease(&s);
    body["cols"] = json!(5);
    body["rows"] = json!(1000);
    let clamped = s.post("/terminals", body).await;
    let second = ids.learn(&clamped);
    t.response(
        "open a 5x1000 terminal (clamped)",
        "POST /api/sessions/:id/terminals",
        &ids.response(&clamped),
    );
    let mut body = lease(&s);
    body["cols"] = json!("wide");
    let invalid = s.post("/terminals", body).await;
    t.response(
        "open with a non-numeric size",
        "POST /api/sessions/:id/terminals",
        &invalid,
    );
    t.response(
        "list",
        "GET /api/sessions/:id/terminals",
        &ids.response(&s.get("/terminals").await),
    );
    t.response(
        "another user lists",
        "GET /api/sessions/:id/terminals",
        &api.send("GET", &format!("{}/terminals", s.base), &other, None)
            .await,
    );

    // The stream: ready, typed commands, control, resize.
    let mut socket = stream(&api, &s.id, &first, &headers).await.open();
    let (frame, _) = next_event(&mut socket).await.expect("ready");
    t.note("attach: the ready frame", ids.value(&ready(&frame, &[])));
    socket
        .send_json(&json!({ "type": "input", "data": "printf 'NOPE-%s\\n' $((1+1))\n" }))
        .await;
    let (frame, _) = next_event(&mut socket).await.expect("error frame");
    t.note("input without control fields", frame);
    let mut stale = lease(&s);
    stale["generation"] = json!(99);
    stale["type"] = json!("input");
    stale["data"] = json!("printf 'NOPE-%s\\n' $((1+1))\n");
    socket.send_json(&stale).await;
    let (frame, _) = next_event(&mut socket).await.expect("error frame");
    t.note("input with a stale generation", frame);
    let input = |data: &str| {
        let mut message = lease(&s);
        message["type"] = json!("input");
        message["data"] = json!(data);
        message
    };
    socket
        .send_json(&input("printf 'MARK-%s\\n' $((6*7))\n"))
        .await;
    let (frames, output) = output_until(&mut socket, "MARK-42").await;
    t.note(
        "typed command: its output arrives",
        json!({ "other frames": frames, "NOPE-2 ran": output.contains("NOPE-2") }),
    );
    socket
        .send_json(&input("printf 'DIR-%s\\n' \"$(basename \"$PWD\")\"; printf 'TERM-%s-%s\\n' \"$TERM\" \"$PIRC_TERMINAL\"\n"))
        .await;
    let lines = output_lines(&mut socket, &["DIR-", "TERM-"]).await;
    t.note(
        "the shell's working directory and terminal variables",
        json!({ "dir": lines[0], "term": lines[1] }),
    );
    let mut resize = lease(&s);
    resize["type"] = json!("resize");
    resize["cols"] = json!(120);
    resize["rows"] = json!(40);
    socket.send_json(&resize).await;
    socket
        .send_json(&input("printf 'SIZE-%s\\n' \"$(stty size | tr ' ' x)\"\n"))
        .await;
    let (_, output) = output_until(&mut socket, "SIZE-40x120").await;
    t.note(
        "resize to 120x40, then stty size",
        json!(output.contains("SIZE-40x120")),
    );
    resize["cols"] = json!(10000);
    resize["rows"] = json!(1);
    socket.send_json(&resize).await;
    socket
        .send_json(&input("printf 'CLAMP-%s\\n' \"$(stty size | tr ' ' x)\"\n"))
        .await;
    let size = output_line(&mut socket, "CLAMP-").await;
    t.note("resize to 10000x1 (clamped), then stty size", json!(size));
    t.response(
        "list after the resizes",
        "GET /api/sessions/:id/terminals",
        &ids.response(&s.get("/terminals").await),
    );
    let mut bad = lease(&s);
    bad["type"] = json!("resize");
    bad["cols"] = json!("wide");
    bad["rows"] = json!(null);
    socket.send_json(&bad).await;
    socket
        .send_json(&input("printf 'KEPT-%s\\n' \"$(stty size | tr ' ' x)\"\n"))
        .await;
    let size = output_line(&mut socket, "KEPT-").await;
    t.note(
        "a resize with non-numeric sizes keeps the size",
        json!(size),
    );
    let mut unknown = lease(&s);
    unknown["type"] = json!("paste");
    unknown["data"] = json!("printf 'PASTE-%s\\n' $((1+1))\n");
    socket.send_json(&unknown).await;

    // Input over the per-input limit (65536 UTF-16 units) is dropped.
    let mut big = String::from("printf 'OVER-%s\\n' $((2+2))\n:");
    big.push_str(&"x".repeat(65_537 - big.len() - 1));
    big.push('\n');
    assert_eq!(big.len(), 65_537);
    socket.send_json(&input(&big)).await;
    socket
        .send_json(&input("printf 'AFTER-%s\\n' $((3+3))\n"))
        .await;
    let (frames, output) = output_until(&mut socket, "AFTER-6").await;
    t.note(
        "an unknown message type, then input of 65537 characters, then a command",
        json!({ "other frames": frames, "PASTE-2 ran": output.contains("PASTE-2"),
            "OVER-4 ran": output.contains("OVER-4") }),
    );

    // A second socket replays the scrollback; both see new output.
    let mut again = stream(&api, &s.id, &first, &headers).await.open();
    let (frame, _) = next_event(&mut again).await.expect("ready");
    t.note(
        "attach a second socket: scrollback replay",
        ids.value(&ready(
            &frame,
            &["MARK-42", "SIZE-40x120", "AFTER-6", "OVER-4"],
        )),
    );
    socket
        .send_json(&input("printf 'BOTH-%s\\n' $((4+4))\n"))
        .await;
    output_until(&mut socket, "BOTH-8").await;
    output_until(&mut again, "BOTH-8").await;
    t.note("output reaches both sockets", json!(true));

    // The other user, unknown terminals.
    for (step, terminal, headers) in [
        ("another user attaches", first.clone(), other.clone()),
        (
            "attach an unknown terminal",
            "nope".to_owned(),
            headers.clone(),
        ),
    ] {
        match stream(&api, &s.id, &terminal, &headers).await {
            Connection::Open(mut socket) => {
                let (frames, closed) = until_closed(&mut socket).await;
                t.note(step, json!({ "frames": frames, "closed": close(closed) }));
            }
            Connection::Refused(response) => t.response(step, "GET (upgrade)", &response),
        }
    }

    // The shell exits.
    socket.send_json(&input("exit 3\n")).await;
    let (frames, closed) = until_closed(&mut socket).await;
    t.note(
        "exit 3: frames and close",
        json!({ "frames": frames, "closed": close(closed) }),
    );
    let (frames, closed) = until_closed(&mut again).await;
    t.note(
        "exit 3: the second socket",
        json!({ "frames": frames, "closed": close(closed) }),
    );
    t.response(
        "list after the exit",
        "GET /api/sessions/:id/terminals",
        &ids.response(&s.get("/terminals").await),
    );
    let mut exited = stream(&api, &s.id, &first, &headers).await.open();
    let (frame, _) = next_event(&mut exited).await.expect("ready");
    t.note(
        "attach the exited terminal: ready",
        ids.value(&ready(&frame, &["MARK-42", "BOTH-8"])),
    );
    let (frame, _) = next_event(&mut exited).await.expect("exit");
    t.note("attach the exited terminal: then", frame);
    socket = exited;
    socket.send_json(&input("printf 'DEAD-%s\\n' 1\n")).await;
    socket.close().await;

    // At most 4 live terminals per session; opening one drops exited ones.
    let mut opened = vec![second.clone()];
    for step in ["open a third", "open a fourth", "open a fifth (4 live)"] {
        let created = s.post("/terminals", lease(&s)).await;
        opened.push(ids.learn(&created));
        t.response(
            step,
            "POST /api/sessions/:id/terminals",
            &ids.response(&created),
        );
    }
    let refused = s.post("/terminals", lease(&s)).await;
    t.response(
        "a fifth live terminal",
        "POST /api/sessions/:id/terminals",
        &refused,
    );
    let listed = s.get("/terminals").await;
    t.note(
        "the list: the exited terminal is gone",
        ids.value(&json!(
            listed.body["terminals"]
                .as_array()
                .unwrap()
                .iter()
                .map(|t| json!({ "id": t["id"], "exited": t["exited"] }))
                .collect::<Vec<_>>()
        )),
    );

    // Closing: an attached socket learns it, the slot frees.
    let mut attached = stream(&api, &s.id, &second, &headers).await.open();
    next_event(&mut attached).await.expect("ready");
    let path = format!("/terminals/{second}/close");
    t.response(
        "close without control fields",
        "POST /api/sessions/:id/terminals/<terminal-2>/close",
        &s.post(&path, json!({})).await,
    );
    t.response(
        "close with a stale generation",
        "POST /api/sessions/:id/terminals/<terminal-2>/close",
        &s.post(&path, json!({ "clientId": "browser", "generation": 99 }))
            .await,
    );
    t.response(
        "close",
        "POST /api/sessions/:id/terminals/<terminal-2>/close",
        &s.post(&path, lease(&s)).await,
    );
    let (frames, closed) = until_closed(&mut attached).await;
    t.note(
        "the attached socket of the closed terminal",
        json!({ "frames": frames, "closed": close(closed) }),
    );
    t.response(
        "close it again",
        "POST /api/sessions/:id/terminals/<terminal-2>/close",
        &s.post(&path, lease(&s)).await,
    );
    t.response(
        "close an unknown terminal",
        "POST /api/sessions/:id/terminals/nope/close",
        &s.post("/terminals/nope/close", lease(&s)).await,
    );
    let created = tokio::time::timeout(std::time::Duration::from_secs(10), async {
        loop {
            let created = s.post("/terminals", lease(&s)).await;
            if created.status != 409 {
                break created;
            }
            assert_eq!(
                created.body["error"]["message"],
                "At most 4 terminals per session"
            );
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
    })
    .await
    .expect("closed shell releases its capacity");
    ids.learn(&created);
    t.response(
        "open again after closing one",
        "POST /api/sessions/:id/terminals",
        &ids.response(&created),
    );
    match stream(&api, &s.id, &second, &headers).await {
        Connection::Open(mut socket) => {
            let (frames, closed) = until_closed(&mut socket).await;
            t.note(
                "attach the closed terminal",
                json!({ "frames": frames, "closed": close(closed) }),
            );
        }
        Connection::Refused(response) => {
            t.response("attach the closed terminal", "GET (upgrade)", &response)
        }
    }

    // Without control, typing is refused; the terminals stay.
    let third = opened[1].clone();
    let mut socket = stream(&api, &s.id, &third, &headers).await.open();
    next_event(&mut socket).await.expect("ready");
    let released = s.post("/control/release", lease(&s)).await;
    t.response(
        "release control",
        "POST /api/sessions/:id/control/release",
        &released,
    );
    socket
        .send_json(&input("printf 'GONE-%s\\n' $((5+5))\n"))
        .await;
    let (frame, output) = next_event(&mut socket).await.expect("error frame");
    t.note(
        "input after control was released",
        json!({ "frame": frame, "GONE-10 ran": output.contains("GONE-10") }),
    );
    socket.close().await;
    t.response(
        "open without control",
        "POST /api/sessions/:id/terminals",
        &s.post("/terminals", lease(&s)).await,
    );
    let listed = s.get("/terminals").await;
    t.note(
        "terminals without control: still listed",
        json!(listed.body["terminals"].as_array().map(Vec::len)),
    );
    insta::assert_json_snapshot!("node_terminals", t.into_value());
}

#[tokio::test(flavor = "multi_thread")]
async fn node_terminals_disabled() {
    let mut options = terminal_env();
    options.node_env.push(("PIRC_TERMINALS", "0".to_owned()));
    let Some(cluster) = Cluster::start_with(options).await else {
        return;
    };
    let api = cluster.api();
    let mut t = Transcript::new(cluster.volatile());
    let (mut s, _) = Session::create(&api).await;
    s.acquire().await;
    let lease = json!({ "clientId": s.client.clone(), "generation": s.generation.clone() });
    t.response(
        "list",
        "GET /api/sessions/:id/terminals",
        &s.get("/terminals").await,
    );
    t.response(
        "open",
        "POST /api/sessions/:id/terminals",
        &s.post("/terminals", lease.clone()).await,
    );
    t.response(
        "open without control",
        "POST /api/sessions/:id/terminals",
        &s.post(
            "/terminals",
            json!({ "clientId": "browser", "generation": 99 }),
        )
        .await,
    );
    t.response(
        "close",
        "POST /api/sessions/:id/terminals/nope/close",
        &s.post("/terminals/nope/close", lease).await,
    );
    match stream(&api, &s.id, "nope", &browser_headers()).await {
        Connection::Open(mut socket) => {
            let (frames, closed) = until_closed(&mut socket).await;
            t.note(
                "attach",
                json!({ "frames": frames, "closed": close(closed) }),
            );
        }
        Connection::Refused(response) => t.response("attach", "GET (upgrade)", &response),
    }
    insta::assert_json_snapshot!("node_terminals_disabled", t.into_value());
}

#[tokio::test(flavor = "multi_thread")]
async fn isolated_terminal_never_falls_back_to_host_on_an_unsupported_backend() {
    let Some(cluster) = Cluster::start_with(terminal_env()).await else {
        return;
    };
    let api = cluster.api();
    let (mut session, _) = Session::create(&api).await;
    session.acquire().await;
    let request = json!({"clientId":session.client,"generation":session.generation,"executionPath":"isolated_work"});
    let response = session.post("/terminals", request).await;
    assert_eq!(response.status, 503, "{response:?}");
    assert_eq!(
        response.body["error"]["code"],
        "isolated_terminal_unavailable"
    );
    let listed = session.get("/terminals").await;
    assert_eq!(listed.body["terminals"], json!([]));
    // Explicit path selection cannot be used to relabel the compatibility path.
    for path in [
        json!("host_management"),
        json!("unknown"),
        json!(true),
        Value::Null,
    ] {
        let response=session.post("/terminals",json!({"clientId":session.client,"generation":session.generation,"executionPath":path})).await;
        assert_eq!(response.status, 400, "{response:?}");
    }
    assert_eq!(session.get("/terminals").await.body["terminals"], json!([]));
}
