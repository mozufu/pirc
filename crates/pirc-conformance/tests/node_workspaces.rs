//! Directory workspaces on a coding node (`node/app.ts`), through a real
//! gateway: adding one from the web (path rules: `~/`, absolute only, an
//! existing directory inside the node's `HOME`, never the node's state or a
//! credential store, no duplicates, no chat projects), what registration
//! then reports (with the workspace's roles), and a workspace's project
//! config (`.pirc/config.json`) and its trust, which reaches the agent as
//! `PIRC_PROJECT_TRUST` (seen as the agent's untrusted-config warning).
//! `node_workspaces_on_node` records the node's own answers to the same
//! routes with the test playing the gateway, where the real gateway's own
//! checks would hide them.

#[path = "node_chat_support/mod.rs"]
mod node_chat_support;

use std::fs;

use node_chat_support::{Ids, canonical_json};
use pirc_conformance::{
    Api, Cluster, FakeGateway, FirstSend, GatewayOptions, LoneNode, NODE_ID, Reply, Transcript,
    USER, WORKSPACE_ID, browser_headers,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

/// Records request/response pairs with workspace ids masked.
struct Recorder<'a> {
    api: Api,
    t: &'a mut Transcript,
    ids: &'a mut Ids,
}

impl Recorder<'_> {
    async fn send(&mut self, step: &str, method: &str, path: &str, body: Option<Value>) -> Value {
        let response = self.api.send(method, path, &browser_headers(), body).await;
        let mut masked = self.ids.response(&response);
        engine_neutral(&mut masked.body);
        let request = self.ids.text(&format!("{method} {path}"));
        self.t.response(step, &request, &masked);
        response.body
    }
}

/// A project config's parse error ends in the TS runtime's own wording (Bun's
/// JSON parser, zod's issue list): kept up to that point, the rest masked.
fn engine_neutral(body: &mut Value) {
    let mask = |text: &mut Value, schema: bool| {
        let Some(message) = text.as_str() else {
            return;
        };
        let masked = if let Some(at) = message.find(".pirc/config.json: ") {
            format!(
                "{}<parser message>",
                &message[..at + ".pirc/config.json: ".len()]
            )
        } else if schema {
            // zod's issue list (the TS validation library's own report).
            "<schema message>".to_owned()
        } else {
            return;
        };
        *text = Value::String(masked);
    };
    for (outer, inner, schema) in [("project", "error", true), ("error", "message", false)] {
        if let Some(text) = body.get_mut(outer).and_then(|value| value.get_mut(inner)) {
            mask(text, schema);
        }
    }
}

fn trust_hash(project: &Value) -> String {
    let mut fields = json!({
        "allowedPaths": project["allowedPaths"],
        "env": project["env"],
        "hooks": project["hooks"],
    });
    if !project["defaultModel"].is_null() {
        fields["defaultModel"] = project["defaultModel"].clone();
    }
    let canonical = canonical_json(&fields);
    let digest = Sha256::digest(format!("pirc-project-trust-v1\n{canonical}"));
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn settled(frame: &Value) -> bool {
    frame["type"] == "pi_event" && frame["data"]["type"] == "agent_settled"
}

static NEXT_OPERATION: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);

/// Create a session in `workspace` through first-send, prompt it once and
/// return the agent's notifications from the snapshot after the run.
async fn run_once(cluster: &Cluster, workspace: &str, message: &str) -> (String, Value) {
    let api = cluster.api();
    let headers = browser_headers();
    let operation = NEXT_OPERATION.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let started = FirstSend::new(&api, &headers)
        .workspace(workspace)
        .operation(format!("first-{operation}"))
        .start_idle()
        .await;
    let id = started.id;
    let session = started.base;
    let acquired = api
        .send(
            "POST",
            &format!("{session}/control/acquire"),
            &headers,
            Some(json!({ "clientId": "browser" })),
        )
        .await;
    let generation = acquired.body["lease"]["generation"].clone();
    let before = api
        .send("GET", &format!("{session}/snapshot"), &headers, None)
        .await;
    let watermark = &before.body["watermark"];
    let mut live = api
        .connect(
            &format!(
                "/api/events?sessionId={id}&cursor={}:{}",
                watermark["epoch"], watermark["sequence"]
            ),
            &headers,
        )
        .await
        .open();
    cluster.llm.push([Reply::Text("Done.".to_owned())]);
    let environment = api
        .send("GET", &format!("{session}/environment"), &headers, None)
        .await;
    let sent = api
        .send(
            "POST",
            &format!("{session}/commands"),
            &headers,
            Some(
                json!({ "commandId": format!("command-{message}"), "clientId": "browser", "generation": generation,
                "expectedBinding": environment.body["binding"],
                "payload": { "type": "prompt", "message": message } }),
            ),
        )
        .await;
    assert_eq!(sent.status, 202, "{}", sent.body);
    live.until(settled).await;
    live.close().await;
    let after = api
        .send("GET", &format!("{session}/snapshot"), &headers, None)
        .await;
    let notifications: Vec<Value> = after.body["notifications"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|item| json!({ "message": item["message"], "notifyType": item["notifyType"] }))
        .collect();
    (id, json!(notifications))
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_workspaces() {
    // The node's state inside its HOME (relative to the node's working
    // directory, the run directory), so a workspace can clash with it.
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        node_env: vec![
            ("PIRC_STATE_DIR", "node-home/srv/state".to_owned()),
            ("TMPDIR", "{run_dir}".into()),
        ],
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let root = cluster.dir.path().canonicalize().unwrap();
    let home = root.join("node-home");
    fs::create_dir_all(home.join("proj/.pirc")).unwrap();
    fs::write(home.join("proj/README.md"), "project\n").unwrap();
    let config = json!({
        "env": { "GIT_SSH_COMMAND": "ssh -i key" },
        "hooks": { "sessionStart": [{ "command": "echo hook ran >&2; exit 3" }] },
        "allowedPaths": ["../shared"],
    });
    fs::write(home.join("proj/.pirc/config.json"), config.to_string()).unwrap();
    fs::create_dir_all(home.join("plain")).unwrap();
    fs::create_dir_all(home.join("roled/.pirc/roles")).unwrap();
    fs::write(
        home.join("roled/.pirc/roles/reviewer.md"),
        "---\ndescription: Reviews changes.\n---\n\nReview the diff.\n",
    )
    .unwrap();
    std::os::unix::fs::symlink(home.join("proj"), home.join("proj-link")).unwrap();
    fs::write(home.join("notes.txt"), "a file\n").unwrap();
    fs::create_dir_all(home.join(".ssh")).unwrap();
    fs::create_dir_all(home.join(".config")).unwrap();
    fs::create_dir_all(home.join("srv/state/inner")).unwrap();

    let mut t = Transcript::new(cluster.volatile());
    let mut ids = Ids::default();
    let mut r = Recorder {
        api: cluster.api(),
        t: &mut t,
        ids: &mut ids,
    };

    r.send(
        "the configured workspace before any is added",
        "GET",
        "/api/workspaces",
        None,
    )
    .await;

    let add =
        |path: &str, name: &str| json!({ "nodeId": NODE_ID, "path": path, "displayName": name });
    let created = r
        .send(
            "add ~/proj: expanded against the node's HOME, 201",
            "POST",
            "/api/workspaces",
            Some(add("~/proj", "Project")),
        )
        .await;
    let project = created["workspace"]["id"].as_str().unwrap().to_owned();
    r.send(
        "an absolute path inside HOME, display name trimmed",
        "POST",
        "/api/workspaces",
        Some(add(&home.join("plain").display().to_string(), "  Plain  ")),
    )
    .await;
    r.send(
        "a workspace with its own role (.pirc/roles/reviewer.md)",
        "POST",
        "/api/workspaces",
        Some(add("~/roled", "Roled")),
    )
    .await;
    let home_text = home.display().to_string();
    for (step, path) in [
        ("a relative path: refused, 400", "proj".to_owned()),
        (
            "~ alone is not expanded: a relative path, 400",
            "~".to_owned(),
        ),
        ("a missing directory: 400", "~/missing".to_owned()),
        ("a file, not a directory: 400", "~/notes.txt".to_owned()),
        ("HOME itself: outside HOME, 403", home_text.clone()),
        (
            "outside HOME (the configured workspace's directory): 403",
            root.join("workspace").display().to_string(),
        ),
        ("a path already added: 409", "~/proj".to_owned()),
        (
            "a symlink to a path already added (canonicalized): 409",
            "~/proj-link".to_owned(),
        ),
        (
            "a directory inside the node's state directory: 403",
            "~/srv/state/inner".to_owned(),
        ),
        (
            "a directory holding the node's state directory: 403",
            "~/srv".to_owned(),
        ),
        ("a credential store (~/.ssh): 403", "~/.ssh".to_owned()),
        (
            "a directory holding credential stores (~/.config holds .config/gh): 403",
            "~/.config".to_owned(),
        ),
    ] {
        r.send(step, "POST", "/api/workspaces", Some(add(&path, "Refused")))
            .await;
    }
    r.send(
        "an empty display name: the gateway's 400",
        "POST",
        "/api/workspaces",
        Some(add("~/plain", "   ")),
    )
    .await;
    r.send(
        "a chat project on a coding node: 403",
        "POST",
        "/api/workspaces",
        Some(json!({ "nodeId": NODE_ID, "mode": "chat", "displayName": "Trip" })),
    )
    .await;
    r.send(
        "the added workspaces are listed",
        "GET",
        "/api/workspaces",
        None,
    )
    .await;
    let nodes = r
        .api
        .send("GET", "/api/nodes", &browser_headers(), None)
        .await;
    let workspaces = r.ids.value(&nodes.body["nodes"][0]["workspaces"]);
    r.t.note(
        "the node's workspaces as registration reports them, with their roles",
        workspaces,
    );

    // Project config and trust.
    let summary = format!("/api/workspaces/{}/project-config", urlencode(&project));
    let trust = format!("/api/workspaces/{}/project-trust", urlencode(&project));
    let first = r
        .send(
            "project config of ~/proj: untrusted, defaults filled in",
            "GET",
            &summary,
            None,
        )
        .await;
    let hash = first["project"]["hash"].as_str().unwrap().to_owned();
    r.t.note(
        "the hash is sha256 of \"pirc-project-trust-v1\\n\" and the canonical JSON of allowedPaths, env, hooks and (when set) defaultModel",
        json!(trust_hash(&first["project"]) == hash),
    );
    r.send(
        "the configured workspace has no project config: empty",
        "GET",
        &format!("/api/workspaces/{}/project-config", urlencode(WORKSPACE_ID)),
        None,
    )
    .await;

    let (_, notifications) = run_once(&cluster, &project, "Untrusted").await;
    r.t.note(
        "an agent in the untrusted workspace warns that the config was ignored",
        notifications,
    );

    r.send(
        "trust with a hash that was never shown: 409",
        "POST",
        &trust,
        Some(json!({ "trusted": true, "hash": "a".repeat(64) })),
    )
    .await;
    r.send(
        "trust with a malformed hash: the gateway's 400",
        "POST",
        &trust,
        Some(json!({ "trusted": true, "hash": "nope" })),
    )
    .await;
    r.send(
        "trust with an extra key: 400",
        "POST",
        &trust,
        Some(json!({ "trusted": true, "hash": hash, "extra": 1 })),
    )
    .await;
    r.send(
        "trust the hash shown: trusted",
        "POST",
        &trust,
        Some(json!({ "trusted": true, "hash": hash })),
    )
    .await;
    let (_, notifications) = run_once(&cluster, &project, "Trusted").await;
    r.t.note(
        "an agent in the trusted workspace: no warning, and the trusted sessionStart hook runs",
        notifications,
    );

    fs::write(
        home.join("proj/.pirc/config.json"),
        json!({ "env": { "GIT_SSH_COMMAND": "ssh -o ProxyCommand=evil" } }).to_string(),
    )
    .unwrap();
    r.send(
        "the config changed after trusting: not trusted, the old hash kept",
        "GET",
        &summary,
        None,
    )
    .await;
    r.send("untrust", "POST", &trust, Some(json!({ "trusted": false })))
        .await;

    fs::write(home.join("proj/.pirc/config.json"), r#"{"hooks": "#).unwrap();
    r.send(
        "an invalid config is reported, with no hash",
        "GET",
        &summary,
        None,
    )
    .await;
    r.send(
        "an invalid config cannot be trusted: 400",
        "POST",
        &trust,
        Some(json!({ "trusted": true, "hash": hash })),
    )
    .await;
    fs::write(
        home.join("proj/.pirc/config.json"),
        json!({ "hooks": {}, "unknown": true }).to_string(),
    )
    .unwrap();
    r.send(
        "a config with an unknown key is invalid (strict)",
        "GET",
        &summary,
        None,
    )
    .await;
    fs::write(
        home.join("proj/.pirc/config.json"),
        json!({ "defaultModel": { "provider": "fake", "id": "fake-model" } }).to_string(),
    )
    .unwrap();
    r.send(
        "a config with only a default model: nothing to trust (empty)",
        "GET",
        &summary,
        None,
    )
    .await;

    r.send(
        "project config of an unknown workspace: 404",
        "GET",
        "/api/workspaces/test%3Anope/project-config",
        None,
    )
    .await;
    r.send(
        "instructions of a directory workspace: 400",
        "GET",
        &format!("/api/workspaces/{}/instructions", urlencode(WORKSPACE_ID)),
        None,
    )
    .await;
    r.send(
        "assistant prompts without a chat node: 503",
        "GET",
        "/api/assistant/prompts",
        None,
    )
    .await;

    let (session, _) = run_once(&cluster, WORKSPACE_ID, "Hello").await;
    let path = format!("/api/sessions/{session}");
    r.send(
        "deleting a session of a directory workspace: 204",
        "DELETE",
        &path,
        None,
    )
    .await;

    insta::assert_json_snapshot!("node_workspaces", t.into_value());
}

/// Removal fences only gateway access; re-adding the canonical directory
/// must recover the node's original workspace and saved conversation.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn removed_directory_readd_restores_real_node_history() {
    let Some(mut cluster) = Cluster::start().await else {
        return;
    };
    let home = cluster.dir.path().canonicalize().unwrap().join("node-home");
    let repository = home.join("restore-repository");
    fs::create_dir_all(&repository).unwrap();
    let sentinel = repository.join("keep.txt");
    fs::write(&sentinel, "never delete repository contents\n").unwrap();
    std::os::unix::fs::symlink(&repository, home.join("restore-alias")).unwrap();
    let api = cluster.api();
    let headers = browser_headers();
    let add =
        |path: &str, name: &str| json!({ "nodeId": NODE_ID, "path": path, "displayName": name });
    let created = api
        .send(
            "POST",
            "/api/workspaces",
            &headers,
            Some(add("~/restore-repository", "Original repository")),
        )
        .await;
    assert_eq!(created.status, 201, "{}", created.body);
    let workspace = created.body["workspace"].clone();
    let id = workspace["id"].as_str().unwrap();
    let workspace_path = format!("/api/workspaces/{}", urlencode(id));
    let duplicate = api
        .send(
            "POST",
            "/api/workspaces",
            &headers,
            Some(add("~/restore-alias", "Must not rename")),
        )
        .await;
    assert_eq!(duplicate.status, 409, "{}", duplicate.body);
    let (session_id, _) = run_once(&cluster, id, "Remember this conversation").await;
    let session_path = format!("/api/sessions/{session_id}/snapshot");
    let before = api.send("GET", &session_path, &headers, None).await;
    assert_eq!(before.status, 200, "{}", before.body);
    let history = before.body["history"].clone();
    assert!(history.is_array(), "{}", before.body);
    assert!(history.to_string().contains("Remember this conversation"));
    assert!(history.to_string().contains("Done."));
    let schedule = api
        .send(
            "POST",
            "/api/schedules",
            &headers,
            Some(
                json!({ "workspaceId": id, "prompt": "A future task", "at": "2040-01-01T09:00Z" }),
            ),
        )
        .await;
    assert_eq!(schedule.status, 201, "{}", schedule.body);
    let schedule_id = schedule.body["schedule"]["id"].as_str().unwrap();
    assert_eq!(schedule.body["schedule"]["status"], "active");

    // An agent_settled event can narrowly precede the final activity frame.
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let removed = api.send("DELETE", &workspace_path, &headers, None).await;
        if removed.status == 204 {
            break;
        }
        assert_eq!(removed.status, 409, "{}", removed.body);
        assert!(tokio::time::Instant::now() < deadline, "{}", removed.body);
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    for restarted in [false, true] {
        if restarted {
            cluster.restart_node(false).await;
            cluster.restart_gateway(false).await;
        }
        for (path, field, hidden_id) in [
            ("/api/workspaces", "workspaces", id),
            ("/api/sessions", "sessions", session_id.as_str()),
        ] {
            let listed = api.send("GET", path, &headers, None).await;
            assert_eq!(listed.status, 200, "{}", listed.body);
            assert!(
                listed.body[field]
                    .as_array()
                    .unwrap()
                    .iter()
                    .all(|row| row["id"] != hidden_id)
            );
        }
        let denied = api.send("GET", &session_path, &headers, None).await;
        assert_eq!(denied.status, 404, "{}", denied.body);
        let denied = api
            .send(
                "POST",
                "/api/conversation-submissions/prepare",
                &headers,
                Some(
                    json!({ "operationId": format!("removed-{restarted}"), "submission": {
                    "workspaceId": id, "message": "Hello" } }),
                ),
            )
            .await;
        assert_eq!(denied.status, 404, "{}", denied.body);
        assert_eq!(
            fs::read_to_string(&sentinel).unwrap(),
            "never delete repository contents\n"
        );
    }
    let restored = api
        .send(
            "POST",
            "/api/workspaces",
            &headers,
            Some(add("~/restore-alias", "Must not rename")),
        )
        .await;
    assert_eq!(restored.status, 201, "{}", restored.body);
    assert_eq!(restored.body["workspace"], workspace);
    let restored_history = api.send("GET", &session_path, &headers, None).await;
    assert_eq!(restored_history.status, 200, "{}", restored_history.body);
    assert_eq!(restored_history.body["history"], history);
    assert_eq!(restored_history.body["session"]["id"], session_id);
    let sessions = api.send("GET", "/api/sessions", &headers, None).await;
    assert!(
        sessions.body["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|row| row["id"] == session_id)
    );
    let schedule = api
        .send(
            "GET",
            &format!("/api/schedules/{schedule_id}"),
            &headers,
            None,
        )
        .await;
    assert_eq!(schedule.status, 200, "{}", schedule.body);
    assert_eq!(schedule.body["schedule"]["status"], "paused");
    assert!(schedule.body["schedule"]["nextRunAt"].is_null());
    assert_eq!(
        fs::read_to_string(&sentinel).unwrap(),
        "never delete repository contents\n"
    );
}

fn urlencode(id: &str) -> String {
    id.replace(':', "%3A")
}

/// Relayed requests sent straight to the node, as the gateway would.
struct OnNode<'a> {
    link: pirc_conformance::NodeLink,
    t: &'a mut Transcript,
    ids: &'a mut Ids,
    count: usize,
}

impl OnNode<'_> {
    async fn request(
        &mut self,
        step: &str,
        method: &str,
        url: &str,
        payload: Option<Value>,
    ) -> Value {
        self.request_as(step, USER, method, url, payload).await
    }

    async fn request_as(
        &mut self,
        step: &str,
        user: &str,
        method: &str,
        url: &str,
        payload: Option<Value>,
    ) -> Value {
        self.count += 1;
        let mut data = json!({ "method": method, "url": url, "user": user });
        if let Some(payload) = payload {
            data["payload"] = payload;
        }
        let response = self
            .link
            .request(&format!("request-{}", self.count), data)
            .await;
        let body = response["data"]["body"].clone();
        let mut masked = self.ids.value(&response["data"]);
        if let Some(error) = masked
            .get_mut("body")
            .and_then(|body| body.get_mut("error"))
            .and_then(Value::as_object_mut)
        {
            // The validation library's own report, as in `Transcript::response`.
            error.remove("details");
        }
        if masked["status"] == 404 && masked["body"]["statusCode"] == 404 {
            // The router's own not-found body (Fastify's): only the status is the contract.
            masked["body"] = json!("<no such route>");
        }
        let request = self.ids.text(&format!("{method} {url}"));
        self.t
            .note(step, json!({ "request": request, "response": masked }));
        body
    }
}

/// The node's own answers, with the test as the gateway.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_workspaces_on_node() {
    let gateway = FakeGateway::bind().await;
    let Some(node) = LoneNode::start(gateway.port()) else {
        return;
    };
    let root = node.dir.path().canonicalize().unwrap();
    let home = root.join("node-home");
    let mut t = Transcript::new(node.volatile());
    let mut ids = Ids::default();
    let mut link = gateway.accept().await;
    let register = link.recv().await;
    assert_eq!(register["type"], "register");
    link.send(&json!({ "type": "registered", "nodeId": NODE_ID,
        "models": { "providers": {} }, "mirrors": {} }))
        .await;
    fs::create_dir_all(home.join("proj/.pirc")).unwrap();
    fs::write(
        home.join("proj/.pirc/config.json"),
        json!({ "env": { "A": "1" } }).to_string(),
    )
    .unwrap();
    fs::create_dir_all(home.join("roled/.pirc/roles")).unwrap();
    fs::write(
        home.join("roled/.pirc/roles/reviewer.md"),
        "---\ndescription: Reviews changes.\n---\n\nReview the diff.\n",
    )
    .unwrap();

    let mut n = OnNode {
        link,
        t: &mut t,
        ids: &mut ids,
        count: 0,
    };

    let created = n
        .request(
            "add ~/proj: the node's answer has the canonical path and roles",
            "POST",
            "/api/workspaces",
            Some(json!({ "path": "~/proj", "displayName": "Project" })),
        )
        .await;
    let project = created["workspace"]["id"].as_str().unwrap().to_owned();
    n.request(
        "a workspace with its own role",
        "POST",
        "/api/workspaces",
        Some(json!({ "path": "~/roled", "displayName": "Roled" })),
    )
    .await;
    n.request(
        "no path and no kind: 400",
        "POST",
        "/api/workspaces",
        Some(json!({ "displayName": "Nothing" })),
    )
    .await;
    n.request(
        "a chat project on a coding node: 403",
        "POST",
        "/api/workspaces",
        Some(json!({ "mode": "chat", "displayName": "Trip" })),
    )
    .await;
    n.request_as(
        "a user the node does not allow: 403",
        "other@example.com",
        "GET",
        "/api/workspaces/test/project-config",
        None,
    )
    .await;
    let first = n
        .request(
            "project config",
            "GET",
            &format!("/api/workspaces/{project}/project-config"),
            None,
        )
        .await;
    let hash = first["project"]["hash"].clone();
    n.request(
        "trust with a malformed hash: the node's own 400",
        "POST",
        &format!("/api/workspaces/{project}/project-trust"),
        Some(json!({ "trusted": true, "hash": "nope" })),
    )
    .await;
    n.request(
        "trust with an upper-case hash: 400",
        "POST",
        &format!("/api/workspaces/{project}/project-trust"),
        Some(json!({ "trusted": true, "hash": hash.as_str().unwrap().to_uppercase() })),
    )
    .await;
    n.request(
        "trust",
        "POST",
        &format!("/api/workspaces/{project}/project-trust"),
        Some(json!({ "trusted": true, "hash": hash })),
    )
    .await;
    n.request(
        "trust kept on the node",
        "GET",
        &format!("/api/workspaces/{project}/project-config"),
        None,
    )
    .await;
    n.request(
        "instructions of a directory workspace: the node's 400",
        "GET",
        "/api/workspaces/test/instructions",
        None,
    )
    .await;
    n.request(
        "set instructions of a directory workspace: 400",
        "PATCH",
        "/api/workspaces/test/instructions",
        Some(json!({ "text": "x" })),
    )
    .await;
    n.request(
        "project config of an unknown workspace: 404",
        "GET",
        "/api/workspaces/nope/project-config",
        None,
    )
    .await;
    n.request(
        "assistant prompts on a coding node: not a route, 404",
        "GET",
        "/api/assistant/prompts",
        None,
    )
    .await;
    n.request(
        "set an assistant prompt on a coding node: 404",
        "PUT",
        "/api/assistant/prompts/soul",
        Some(json!({ "text": "" })),
    )
    .await;
    let created = n
        .request(
            "a session in the configured workspace",
            "POST",
            "/api/session-creations/internal",
            Some(json!({ "workspaceId": "test" })),
        )
        .await;
    let session = created["session"]["id"].as_str().unwrap().to_owned();
    n.request(
        "deleting it: a directory conversation, 204",
        "DELETE",
        &format!("/api/sessions/{session}"),
        None,
    )
    .await;

    insta::assert_json_snapshot!("node_workspaces_on_node", t.into_value());
}
