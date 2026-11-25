//! Native checkpoint acceptance over real HTTP, WebSocket, Gateway, Node and
//! agent processes. Unlike the snapshot suite this has no Linux-only golden
//! transcript and never substitutes the unconfined fake-srt for isolation.
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use pirc_conformance::{
    Api, Cluster, FirstSend, GatewayOptions, HOST, Reply, Response, USER, WORKSPACE_ID, WebSocket,
    browser_headers,
};
use serde_json::{Value, json};

type Headers = Vec<(&'static str, String)>;

// Each fixture has an independent HOME/registry, but Linux's /proc/net/unix
// spans them all. A sibling fixture tearing down its inference socket while
// another builds a native sandbox can fail the latter's deny mount. Serialize
// fixture lifetimes (as the dedicated native CI does), not the concurrent
// devices, writers, or requests exercised inside each scenario.
static NATIVE_FIXTURE: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn native_available() -> bool {
    let available = if cfg!(target_os = "macos") {
        Path::new("/usr/bin/sandbox-exec").exists()
    } else if cfg!(target_os = "linux") {
        Command::new("bwrap").arg("--version").output().is_ok()
            && Command::new("bwrap")
                .args([
                    "--ro-bind",
                    "/",
                    "/",
                    "--dev",
                    "/dev",
                    "--proc",
                    "/proc",
                    "--unshare-pid",
                    "--",
                    "/bin/true",
                ])
                .output()
                .is_ok_and(|output| output.status.success())
    } else {
        false
    };
    assert!(
        available || std::env::var_os("PIRC_CHECKPOINT_NATIVE_REQUIRED").is_none(),
        "native checkpoint acceptance requires Seatbelt or bubblewrap"
    );
    if !available {
        eprintln!("native checkpoint acceptance skipped: a usable Seatbelt/bubblewrap unavailable");
    }
    available
}

async fn cluster() -> Option<Cluster> {
    if !native_available() {
        return None;
    }
    Cluster::start_with(GatewayOptions {
        agent_core_only: false,
        env: vec![("PIRC_ALLOWED_USERS", format!("{USER},other@example.com"))],
        node_env: vec![
            ("PIRC_SANDBOX_SRT", String::new()),
            ("PIRC_AGENT_FEATURES", "workspace-memory".into()),
            ("PIRC_CHECKPOINT_WORKSPACES", r#"["test"]"#.into()),
            ("PIRC_ALLOWED_USERS", format!("{USER},other@example.com")),
        ],
        ..Default::default()
    })
    .await
}
#[track_caller]
fn ok(response: Response, expected: u16) -> Value {
    assert_eq!(response.status, expected, "{}", response.body);
    response.body
}
static NEXT_OPERATION: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);

async fn create(api: &Api, headers: &Headers, workspace: &str) -> String {
    let operation = NEXT_OPERATION.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    FirstSend::new(api, headers)
        .workspace(workspace)
        .operation(format!("first-{operation}"))
        .start_idle()
        .await
        .id
}
async fn control(api: &Api, headers: &Headers, id: &str, client: &str) -> Value {
    ok(
        api.send(
            "POST",
            &format!("/api/sessions/{id}/control/acquire"),
            headers,
            Some(json!({"clientId":client,"force":true})),
        )
        .await,
        200,
    )["lease"]["generation"]
        .clone()
}
async fn events(api: &Api, headers: &Headers, id: &str) -> WebSocket {
    let snapshot = ok(
        api.send(
            "GET",
            &format!("/api/sessions/{id}/snapshot"),
            headers,
            None,
        )
        .await,
        200,
    );
    let watermark = &snapshot["watermark"];
    api.connect(
        &format!(
            "/api/events?sessionId={id}&cursor={}:{}",
            watermark["epoch"], watermark["sequence"]
        ),
        headers,
    )
    .await
    .open()
}
async fn prompt(
    api: &Api,
    headers: &Headers,
    id: &str,
    client: &str,
    generation: &Value,
    command: &str,
) -> Response {
    let environment = api
        .send(
            "GET",
            &format!("/api/sessions/{id}/environment"),
            headers,
            None,
        )
        .await;
    api.send(
        "POST",
        &format!("/api/sessions/{id}/commands"),
        headers,
        Some(
            json!({"commandId":command,"clientId":client,"generation":generation,
            "expectedBinding":environment.body["binding"],
            "payload":{"type":"prompt","message":command}}),
        ),
    )
    .await
}
fn settled(frame: &Value) -> bool {
    frame["type"] == "pi_event" && frame["data"]["type"] == "agent_settled"
}
async fn run_write(
    cluster: &Cluster,
    api: &Api,
    headers: &Headers,
    id: &str,
    generation: &Value,
    name: &str,
    contents: &str,
) {
    let mut live = events(api, headers, id).await;
    cluster.llm.push([
        Reply::Tool {
            id: format!("{name}-write"),
            name: "write".into(),
            args: json!({"path":"main.txt","content":contents}),
        },
        Reply::Text("Done.".into()),
    ]);
    ok(prompt(api, headers, id, "web", generation, name).await, 202);
    let frames = live.until(settled).await;
    assert!(
        !frames.iter().any(|f| f["type"] == "runner_error"),
        "{frames:#?}"
    );
    live.close().await;
}
async fn list(api: &Api, headers: &Headers, id: &str) -> Value {
    ok(
        api.send(
            "GET",
            &format!("/api/sessions/{id}/checkpoints"),
            headers,
            None,
        )
        .await,
        200,
    )
}
fn selected(page: &Value) -> (String, String) {
    let capture = &page["captures"][0];
    assert_eq!(capture["state"], "observational", "{page}");
    let operation = &capture["operations"][0];
    assert_eq!(operation["state"], "observed", "{page}");
    (
        capture["id"].as_str().unwrap().into(),
        operation["id"].as_str().unwrap().into(),
    )
}
fn base(id: &str, capture: &str) -> String {
    format!("/api/sessions/{id}/checkpoints/{capture}")
}
async fn preview(api: &Api, headers: &Headers, base: &str, operation: &str) -> Value {
    ok(
        api.send(
            "POST",
            &format!("{base}/preview"),
            headers,
            Some(json!({"operations":[operation],"reviewObservational":true})),
        )
        .await,
        200,
    )
}
fn prepare_body(preview: &Value, operation: &str, key: &str, generation: &Value) -> Value {
    json!({"version":1,"key":key,"previewRevision":preview["revision"],"operations":[operation],
        "reviewObservational":true,"clientId":"web","generation":generation})
}
fn continue_body(job: &Value, client: &str, generation: &Value, accept: bool) -> Value {
    json!({"revision":job["revision"],"acceptUnresolved":accept,"clientId":client,"generation":generation})
}
fn root(cluster: &Cluster, job: &Value) -> PathBuf {
    cluster
        .dir
        .path()
        .join("node-state/checkpoints/workspaces")
        .join(job["id"].as_str().unwrap())
        .join("root")
}
fn git(root: &Path, args: &[&str]) {
    let result = Command::new("git")
        .current_dir(root)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("HOME", root.parent().unwrap())
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .args(args)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&result.stderr)
    );
}
fn tree(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    fn walk(root: &Path, path: &Path, out: &mut BTreeMap<PathBuf, Vec<u8>>) {
        for entry in fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                walk(root, &path, out);
            } else {
                out.insert(
                    path.strip_prefix(root).unwrap().into(),
                    fs::read(path).unwrap(),
                );
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(root, root, &mut out);
    out
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn native_recovery_preserves_dirty_git_and_continues_once_across_devices_and_restarts() {
    let _fixture = NATIVE_FIXTURE.lock().await;
    let Some(mut cluster) = cluster().await else {
        return;
    };
    let api = cluster.api();
    let web = browser_headers();
    let source = cluster.dir.path().join("workspace");
    fs::write(source.join("main.txt"), "committed\n").unwrap();
    git(&source, &["init", "-q"]);
    git(&source, &["add", "main.txt"]);
    git(
        &source,
        &[
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.com",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "baseline",
        ],
    );
    fs::write(source.join("main.txt"), "user staged baseline\r\n").unwrap();
    git(&source, &["add", "main.txt"]);
    fs::write(source.join("untracked.txt"), "user untracked\n").unwrap();
    let git_before = tree(&source.join(".git"));
    // Capture user files before Linux creates its temporary deny-path mount
    // points. A node restart legitimately removes those recorded placeholders;
    // the user's own empty protected file must still survive unchanged.
    fs::write(source.join(".bashrc"), b"").unwrap();
    let mut expected_source = tree(&source);
    let id = create(&api, &web, WORKSPACE_ID).await;
    let generation = control(&api, &web, &id, "web").await;
    run_write(
        &cluster,
        &api,
        &web,
        &id,
        &generation,
        "SOURCE_ONLY_PRIVATE_PROMPT",
        "agent edit\n",
    )
    .await;
    assert_eq!(fs::read(source.join("main.txt")).unwrap(), b"agent edit\n");
    let page = list(&api, &web, &id).await;
    let (capture, operation) = selected(&page);
    let base = base(&id, &capture);
    let recorded = ok(
        api.send(
            "GET",
            &format!("{base}/file?operation={operation}&side=before"),
            &web,
            None,
        )
        .await,
        200,
    );
    assert_eq!(recorded["text"], "user staged baseline\r\n");
    let paired = ok(
        api.send(
            "POST",
            "/api/devices",
            &web,
            Some(json!({"name":"Checkpoint phone"})),
        )
        .await,
        201,
    );
    let phone = vec![
        ("host", HOST.into()),
        ("x-pirc-client", pirc_conformance::CLIENT.to_owned()),
        (
            "authorization",
            format!("Bearer {}", paired["token"].as_str().unwrap()),
        ),
    ];
    let mut web_events = events(&api, &web, &id).await;
    let mut phone_events = events(&api, &phone, &id).await;
    let preview = preview(&api, &web, &base, &operation).await;
    let body = prepare_body(&preview, &operation, "same-preparation", &generation);
    let prepare_url = format!("{base}/recoveries");
    let (a, b) = tokio::join!(
        api.send("POST", &prepare_url, &web, Some(body.clone())),
        api.send("POST", &prepare_url, &phone, Some(body.clone()))
    );
    let job = ok(a, 200);
    let repeated = ok(b, 200);
    assert_eq!(job["id"], repeated["id"]);
    // The simultaneous retry can observe preparing while the first request
    // copies. Clients refresh the authoritative job before confirming its revision.
    let job = ok(
        api.send(
            "GET",
            &format!("{base}/recoveries/{}", job["id"].as_str().unwrap()),
            &phone,
            None,
        )
        .await,
        200,
    );
    assert_eq!(job["state"], "ready");
    for (side, expected) in [
        ("before", "user staged baseline\r\n"),
        ("after", "agent edit\n"),
        ("current", "agent edit\n"),
        ("candidate", "user staged baseline\r\n"),
    ] {
        let suffix = if matches!(side, "current" | "candidate") {
            format!("&job={}", job["id"].as_str().unwrap())
        } else {
            String::new()
        };
        let response = ok(
            api.send(
                "GET",
                &format!("{base}/file?operation={operation}&side={side}{suffix}"),
                &phone,
                None,
            )
            .await,
            200,
        );
        assert_eq!(response["text"], expected);
        assert!(response.get("output").is_none());
    }
    for invalid in [
        format!("operation={operation}&side=current"),
        format!("operation={operation}&side=before&side=after"),
        format!("operation={operation}&side=before&job="),
        format!("operation={operation}&side=after&path=/etc/passwd"),
    ] {
        assert_eq!(
            api.send("GET", &format!("{base}/file?{invalid}"), &phone, None)
                .await
                .status,
            400
        );
    }
    assert!(job.get("output").is_none());
    assert!(
        !job.to_string()
            .contains(cluster.dir.path().to_str().unwrap())
    );
    assert_eq!(
        fs::read(root(&cluster, &job).join("main.txt")).unwrap(),
        b"user staged baseline\r\n"
    );
    assert_eq!(tree(&source.join(".git")), git_before);
    let is_changed = |f: &Value| f["type"] == "checkpoints_changed";
    for frames in [
        web_events.until(is_changed).await,
        phone_events.until(is_changed).await,
    ] {
        assert!(
            frames
                .iter()
                .any(|f| f["type"] == "checkpoints_changed" && f["data"]["sessionId"] == id)
        );
    }
    web_events.close().await;
    phone_events.close().await;
    let phone_generation = control(&api, &phone, &id, "phone").await;
    let continue_url = format!("{base}/recoveries/{}/continue", job["id"].as_str().unwrap());
    assert_eq!(
        api.send(
            "POST",
            &continue_url,
            &web,
            Some(continue_body(&job, "web", &generation, true))
        )
        .await
        .status,
        409
    );
    let body = continue_body(&job, "phone", &phone_generation, true);
    let (a, b) = tokio::join!(
        api.send("POST", &continue_url, &phone, Some(body.clone())),
        api.send("POST", &continue_url, &phone, Some(body))
    );
    let continued = ok(a, 200);
    let repeated = ok(b, 200);
    assert_eq!(continued["session"]["id"], repeated["session"]["id"]);
    let next = continued["session"]["id"].as_str().unwrap().to_owned();
    assert_ne!(next, id);
    let workspace = continued["workspaceId"].as_str().unwrap().to_owned();
    let candidate = root(&cluster, &job);
    fs::write(candidate.join("main.txt"), "user later recovery edit\n").unwrap();
    fs::write(source.join("main.txt"), "user later original edit\n").unwrap();
    expected_source.insert(
        PathBuf::from("main.txt"),
        b"user later original edit\n".to_vec(),
    );
    let mut other = browser_headers();
    other.retain(|(k, _)| *k != "x-pirc-user");
    other.push(("x-pirc-user", "other@example.com".into()));
    let visible = ok(api.send("GET", "/api/workspaces", &other, None).await, 200);
    assert!(!visible.to_string().contains(&workspace));
    assert!(
        api.send(
            "GET",
            &format!("/api/sessions/{next}/checkpoints"),
            &other,
            None
        )
        .await
        .status
            >= 400
    );
    cluster.restart_gateway(true).await;
    assert_eq!(
        list(&api, &phone, &id).await["jobs"][0]["continuation"]["sessionId"],
        next
    );
    cluster.restart_node(true).await;
    let generation = control(&api, &phone, &id, "phone").await;
    let repeated = ok(
        api.send(
            "POST",
            &continue_url,
            &phone,
            Some(continue_body(&job, "phone", &generation, true)),
        )
        .await,
        200,
    );
    assert_eq!(repeated["session"]["id"], next);
    assert_eq!(list(&api, &phone, &next).await["origin"]["sessionId"], id);
    assert_eq!(tree(&source), expected_source);
    assert_eq!(
        fs::read(candidate.join("main.txt")).unwrap(),
        b"user later recovery edit\n"
    );
    let requests_before = cluster.llm.requests().len();
    let generation = control(&api, &phone, &next, "phone").await;
    let mut live = events(&api, &phone, &next).await;
    cluster.llm.push([
        Reply::Tool {
            id: "recovered-write".into(),
            name: "write".into(),
            args: json!({"path":"continued.txt","content":"new isolated agent\n"}),
        },
        Reply::Text("Recovered conversation works.".into()),
    ]);
    ok(
        prompt(
            &api,
            &phone,
            &next,
            "phone",
            &generation,
            "fresh recovery prompt",
        )
        .await,
        202,
    );
    live.until(settled).await;
    live.close().await;
    assert_eq!(
        fs::read(candidate.join("continued.txt")).unwrap(),
        b"new isolated agent\n"
    );
    assert_eq!(
        fs::read(candidate.join("main.txt")).unwrap(),
        b"user later recovery edit\n"
    );
    assert_eq!(tree(&source), expected_source);
    let panel = ok(
        api.send(
            "GET",
            &format!("/api/sessions/{next}/panel/state"),
            &phone,
            None,
        )
        .await,
        200,
    );
    assert_eq!(panel["workspaceMemory"]["writeState"], "disabled");
    assert_eq!(panel["workspaceMemory"]["pendingMutations"], 0);
    assert_eq!(panel["workspaceMemory"]["errors"], json!({}));
    for request in cluster.llm.requests().into_iter().skip(requests_before) {
        assert!(
            !request.to_string().contains("SOURCE_ONLY_PRIVATE_PROMPT"),
            "old conversation was replayed"
        );
    }
    let second = create(&api, &phone, &workspace).await;
    let second_generation = control(&api, &phone, &second, "phone").await;
    let refused = prompt(
        &api,
        &phone,
        &second,
        "phone",
        &second_generation,
        "must not start second writer",
    )
    .await;
    assert!(
        refused.status >= 400,
        "second writer started: {}",
        refused.body
    );
    // A recovery never removes the user's files.
    assert!(candidate.join("continued.txt").exists());
    let generation = control(&api, &phone, &id, "phone").await;
    let reopened = ok(
        api.send(
            "POST",
            &continue_url,
            &phone,
            Some(continue_body(&job, "phone", &generation, true)),
        )
        .await,
        200,
    );
    assert_eq!(reopened["session"]["id"], next);
    assert_eq!(tree(&source), expected_source);
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stale_previews_and_conflicts_require_fresh_review_and_preserve_later_writes() {
    let _fixture = NATIVE_FIXTURE.lock().await;
    let Some(cluster) = cluster().await else {
        return;
    };
    let api = cluster.api();
    let web = browser_headers();
    let source = cluster.dir.path().join("workspace/main.txt");
    fs::write(&source, "dirty baseline\n").unwrap();
    let id = create(&api, &web, WORKSPACE_ID).await;
    let generation = control(&api, &web, &id, "web").await;
    run_write(
        &cluster,
        &api,
        &web,
        &id,
        &generation,
        "initial edit",
        "agent edit\n",
    )
    .await;
    let (capture, operation) = selected(&list(&api, &web, &id).await);
    let base = base(&id, &capture);
    let initial = preview(&api, &web, &base, &operation).await;
    fs::write(&source, "external user same-hunk edit\n").unwrap();
    assert_eq!(
        api.send(
            "POST",
            &format!("{base}/recoveries"),
            &web,
            Some(prepare_body(
                &initial,
                &operation,
                "stale-preview",
                &generation
            ))
        )
        .await
        .status,
        409
    );
    let latest = preview(&api, &web, &base, &operation).await;
    let job = ok(
        api.send(
            "POST",
            &format!("{base}/recoveries"),
            &web,
            Some(prepare_body(&latest, &operation, "conflict", &generation)),
        )
        .await,
        200,
    );
    assert_eq!(job["manifest"]["paths"][0]["status"], "conflict");
    let continue_url = format!("{base}/recoveries/{}/continue", job["id"].as_str().unwrap());
    assert_eq!(
        api.send(
            "POST",
            &continue_url,
            &web,
            Some(continue_body(&job, "web", &generation, false))
        )
        .await
        .status,
        409
    );
    fs::write(&source, "newer source after preparation\n").unwrap();
    assert_eq!(
        api.send(
            "POST",
            &continue_url,
            &web,
            Some(continue_body(&job, "web", &generation, true))
        )
        .await
        .status,
        409
    );
    let stale = ok(
        api.send(
            "GET",
            &format!("{base}/recoveries/{}", job["id"].as_str().unwrap()),
            &web,
            None,
        )
        .await,
        200,
    );
    assert_eq!(stale["state"], "stale");
    let latest = preview(&api, &web, &base, &operation).await;
    let job = ok(
        api.send(
            "POST",
            &format!("{base}/recoveries"),
            &web,
            Some(prepare_body(
                &latest,
                &operation,
                "fresh-conflict",
                &generation,
            )),
        )
        .await,
        200,
    );
    let continued = ok(
        api.send(
            "POST",
            &format!("{base}/recoveries/{}/continue", job["id"].as_str().unwrap()),
            &web,
            Some(continue_body(&job, "web", &generation, true)),
        )
        .await,
        200,
    );
    assert!(continued["session"]["id"].is_string());
    assert_eq!(
        fs::read(&source).unwrap(),
        b"newer source after preparation\n"
    );
    assert_eq!(
        fs::read(root(&cluster, &job).join("main.txt")).unwrap(),
        b"newer source after preparation\n"
    );
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn killed_node_marks_unfinished_capture_incomplete_instead_of_inventing_a_postimage() {
    let _fixture = NATIVE_FIXTURE.lock().await;
    let Some(mut cluster) = cluster().await else {
        return;
    };
    let api = cluster.api();
    let web = browser_headers();
    let source = cluster.dir.path().join("workspace/main.txt");
    fs::write(&source, "user baseline\n").unwrap();
    let id = create(&api, &web, WORKSPACE_ID).await;
    let generation = control(&api, &web, &id, "web").await;
    let live = events(&api, &web, &id).await;
    cluster.llm.push([
        Reply::Tool {
            id: "captured-write".into(),
            name: "write".into(),
            args: json!({"path":"main.txt","content":"completed write before crash\n"}),
        },
        Reply::Tool {
            id: "pending-shell".into(),
            name: "bash".into(),
            args: json!({"command":"sleep 30"}),
        },
        Reply::Text("Should not invent a completed run.".into()),
    ]);
    ok(
        prompt(&api, &web, &id, "web", &generation, "interrupted run").await,
        202,
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let page = list(&api, &web, &id).await;
        if page["captures"][0]["gaps"] == true {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "capture never entered uncovered shell: {page}"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    cluster.restart_node(true).await;
    let page = list(&api, &web, &id).await;
    assert_eq!(page["captures"][0]["state"], "incomplete", "{page}");
    assert_eq!(page["captures"][0]["gaps"], true);
    assert_eq!(
        fs::read(&source).unwrap(),
        b"completed write before crash\n"
    );
    assert!(page["jobs"].as_array().unwrap().is_empty());
    live.close().await;
}
