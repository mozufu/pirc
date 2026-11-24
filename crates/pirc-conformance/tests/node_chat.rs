//! The chat role (`pirc-chat`, later `pirc-node chat`; `node/chat.ts`,
//! `assistant-prompts.ts`), through a real gateway: the top-level chats
//! workspace, chat projects, project instructions and assistant prompts
//! kept on the node, what a chat session's agent is given (its working
//! directory and system prompt), and deleting chats (directories removed,
//! a live runner stopped). `node_chat_startup` records the role checks a
//! node makes when it starts: configured workspaces and `PIRC_CHAT` refused
//! on the chat role, and state holding the other role's workspaces refused
//! by either role without changing it.

#[path = "node_chat_support/mod.rs"]
mod node_chat_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use node_chat_support::{Ids, NodeProcess, NodeRoot, node_command};
use pirc_conformance::{
    Api, CHATS_WORKSPACE_ID, Cluster, FakeGateway, GatewayOptions, NODE_ID, NodeLink, Reply,
    Transcript, USER, browser_headers,
};
use serde_json::{Value, json};

/// Records request/response pairs with workspace ids masked.
struct Recorder<'a> {
    api: Api,
    t: &'a mut Transcript,
    ids: &'a mut Ids,
}

impl Recorder<'_> {
    async fn send(&mut self, step: &str, method: &str, path: &str, body: Option<Value>) -> Value {
        let response = self.api.send(method, path, &browser_headers(), body).await;
        let masked = self.ids.response(&response);
        let request = self.ids.text(&format!("{method} {path}"));
        self.t.response(step, &request, &masked);
        response.body
    }

    /// Directory names, masked then sorted (generated names sort differently on every run).
    fn note_names(&mut self, step: &str, names: Vec<String>) {
        let mut masked: Vec<String> = names
            .iter()
            .map(|name| {
                self.ids.learn(&json!(name));
                self.ids.text(name)
            })
            .collect();
        masked.sort();
        self.t.note(step, json!(masked));
    }

    fn note(&mut self, step: &str, value: Value) {
        let value = self.ids.value(&value);
        self.t.note(step, value);
    }
}

fn settled(frame: &Value) -> bool {
    frame["type"] == "pi_event" && frame["data"]["type"] == "agent_settled"
}

fn encode(id: &str) -> String {
    id.replace(':', "%3A")
}

/// Names in a directory, sorted (`[]` when it does not exist).
fn entries(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .map(|read| {
            read.map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

/// A live chat session: created, controlled and watched from its start.
struct Chat {
    id: String,
    generation: Value,
    live: pirc_conformance::WebSocket,
}

async fn open_chat(api: &Api, workspace: &str) -> Chat {
    let headers = browser_headers();
    let created = api
        .send(
            "POST",
            "/api/sessions",
            &headers,
            Some(json!({ "workspaceId": workspace })),
        )
        .await;
    assert_eq!(created.status, 201, "{}", created.body);
    let id = created.body["session"]["id"].as_str().unwrap().to_owned();
    let acquired = api
        .send(
            "POST",
            &format!("/api/sessions/{id}/control/acquire"),
            &headers,
            Some(json!({ "clientId": "browser" })),
        )
        .await;
    let generation = acquired.body["lease"]["generation"].clone();
    let before = api
        .send(
            "GET",
            &format!("/api/sessions/{id}/snapshot"),
            &headers,
            None,
        )
        .await;
    let watermark = &before.body["watermark"];
    let live = api
        .connect(
            &format!(
                "/api/events?sessionId={id}&cursor={}:{}",
                watermark["epoch"], watermark["sequence"]
            ),
            &headers,
        )
        .await
        .open();
    Chat {
        id,
        generation,
        live,
    }
}

impl Chat {
    async fn prompt(&mut self, api: &Api, command: &str, message: &str) {
        let sent = api
            .send(
                "POST",
                &format!("/api/sessions/{}/commands", self.id),
                &browser_headers(),
                Some(json!({ "commandId": command, "clientId": "browser",
                    "generation": self.generation,
                    "payload": { "type": "prompt", "message": message } })),
            )
            .await;
        assert_eq!(sent.status, 202, "{}", sent.body);
    }
}

/// The system prompt of a model request.
fn system_prompt(request: &Value) -> String {
    request["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|message| message["role"] == "system" || message["role"] == "developer")
        .map(|message| match &message["content"] {
            Value::String(text) => text.clone(),
            other => other.to_string(),
        })
        .unwrap_or_default()
}

const CHAT_IDENTITY: &str = "You are pirc, the user's personal assistant";
const CHAT_ENVIRONMENT: &str = "This chat has its own private working directory";
const CODING_IDENTITY: &str = "You are pirc, a coding agent";

#[ignore = "pirc 2: needs a session created through first-send instead of the removed POST /api/sessions; rewritten after M4 (plans/roadmap.md M2.9)"]
#[tokio::test(flavor = "multi_thread")]
async fn node_chat() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        chat_node: true,
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let root = cluster.dir.path().canonicalize().unwrap();
    let state = root.join("node-state");
    let config = root.join("node-config");
    let api = cluster.api();
    let mut t = Transcript::new(cluster.volatile());
    let mut ids = Ids::default();
    let mut r = Recorder {
        api: api.clone(),
        t: &mut t,
        ids: &mut ids,
    };

    r.send(
        "the chat node's top-level chats workspace",
        "GET",
        "/api/workspaces",
        None,
    )
    .await;
    r.send(
        "the chat node is the assistant's node",
        "GET",
        "/api/assistant/node",
        None,
    )
    .await;

    // Chat projects.
    let created = r
        .send(
            "create a chat project: 201, display name trimmed, no path",
            "POST",
            "/api/workspaces",
            Some(json!({ "nodeId": NODE_ID, "mode": "chat", "displayName": "  Trip  " })),
        )
        .await;
    let project = created["workspace"]["id"].as_str().unwrap().to_owned();
    let local = project.strip_prefix("test:").unwrap().to_owned();
    r.send(
        "a second project with the same name: names need not be unique",
        "POST",
        "/api/workspaces",
        Some(json!({ "nodeId": NODE_ID, "mode": "chat", "displayName": "Trip" })),
    )
    .await;
    for (step, name) in [
        ("an empty display name: 400", "   ".to_owned()),
        ("a display name over 200 characters: 400", "x".repeat(201)),
    ] {
        r.send(
            step,
            "POST",
            "/api/workspaces",
            Some(json!({ "nodeId": NODE_ID, "mode": "chat", "displayName": name })),
        )
        .await;
    }
    r.send(
        "a display name of exactly 200 characters: 201",
        "POST",
        "/api/workspaces",
        Some(json!({ "nodeId": NODE_ID, "mode": "chat", "displayName": "y".repeat(200) })),
    )
    .await;
    r.send(
        "neither a path nor kind chat: 400",
        "POST",
        "/api/workspaces",
        Some(json!({ "nodeId": NODE_ID, "displayName": "No path" })),
    )
    .await;
    for (step, path) in [
        ("a directory workspace (~) on the chat node: 403", "~"),
        ("a directory workspace (~/x) on the chat node: 403", "~/x"),
    ] {
        r.send(
            step,
            "POST",
            "/api/workspaces",
            Some(json!({ "nodeId": NODE_ID, "path": path, "displayName": "Repo" })),
        )
        .await;
    }
    r.send(
        "the projects are listed beside the top-level chats",
        "GET",
        "/api/workspaces",
        None,
    )
    .await;
    let nodes = api
        .send("GET", "/api/nodes", &browser_headers(), None)
        .await;
    r.note(
        "the chat node's registration: role and workspaces (with their directories)",
        json!({ "role": nodes.body["nodes"][0]["role"],
            "workspaces": nodes.body["nodes"][0]["workspaces"] }),
    );
    r.note_names(
        "each workspace has a directory in the node's state: <state>/chat/<local id>",
        entries(&state.join("chat")),
    );

    // A chat outside any project, before any prompt or instructions exist.
    let mut first = open_chat(&api, CHATS_WORKSPACE_ID).await;
    cluster
        .llm
        .push([Reply::Text("Hello from the assistant.".to_owned())]);
    first.prompt(&api, "command-first", "Hello").await;
    first.live.until(settled).await;
    let request = cluster.llm.requests().last().cloned().unwrap();
    let prompt = system_prompt(&request);
    r.note(
        "a top-level chat's system prompt: the built-in assistant identity and chat environment, no coding prompt, no instructions",
        json!({
            "assistant identity": prompt.contains(CHAT_IDENTITY),
            "chat environment": prompt.contains(CHAT_ENVIRONMENT),
            "coding identity": prompt.contains(CODING_IDENTITY),
            "project instructions": prompt.contains("Project instructions"),
        }),
    );
    let first_dirs = entries(&state.join("chat/chats/sessions"));
    r.note(
        "the chat works in its own directory: <state>/chat/chats/sessions/<node session id>",
        json!({ "directories": first_dirs,
            "named after the gateway's session id": first_dirs == [first.id.clone()] }),
    );

    // Project instructions.
    let instructions = format!("/api/workspaces/{}/instructions", encode(&project));
    let file = state.join("chat").join(&local).join("instructions.md");
    r.send(
        "a new project has no instructions",
        "GET",
        &instructions,
        None,
    )
    .await;
    r.send(
        "set them: CRLF becomes LF, surrounding whitespace trimmed",
        "PATCH",
        &instructions,
        Some(json!({ "text": "  Plan trips on a budget.\r\nPrefer trains.\r\n\r\n" })),
    )
    .await;
    r.note(
        "kept on the node in <state>/chat/<project>/instructions.md, with a final newline",
        json!(fs::read_to_string(&file).ok()),
    );
    r.send("read them back", "GET", &instructions, None).await;
    r.send(
        "over 8000 characters: 413",
        "PATCH",
        &instructions,
        Some(json!({ "text": "x".repeat(8001) })),
    )
    .await;
    r.note(
        "the file is unchanged after the refusal",
        json!(fs::read_to_string(&file).ok()),
    );
    let exactly = api
        .send(
            "PATCH",
            &instructions,
            &browser_headers(),
            Some(json!({ "text": format!("  {}  \n", "z".repeat(8000)) })),
        )
        .await;
    r.note(
        "exactly 8000 characters once trimmed: accepted",
        json!({ "status": exactly.status,
            "length": exactly.body["instructions"]["text"].as_str().map(str::len),
            "maxChars": exactly.body["instructions"]["maxChars"] }),
    );
    r.send(
        "an extra key: 400",
        "PATCH",
        &instructions,
        Some(json!({ "text": "x", "extra": true })),
    )
    .await;
    r.send(
        "whitespace only: removes them",
        "PATCH",
        &instructions,
        Some(json!({ "text": " \r\n " })),
    )
    .await;
    r.note("the file is gone", json!(file.exists()));
    r.send(
        "set them again for the project's chats",
        "PATCH",
        &instructions,
        Some(json!({ "text": "Plan trips on a budget." })),
    )
    .await;
    r.send(
        "the top-level chats workspace has instructions too (empty)",
        "GET",
        &format!(
            "/api/workspaces/{}/instructions",
            encode(CHATS_WORKSPACE_ID)
        ),
        None,
    )
    .await;
    r.send(
        "instructions of an unknown workspace: 404",
        "GET",
        "/api/workspaces/test%3Anope/instructions",
        None,
    )
    .await;
    r.send(
        "a chat project has no project config: 400",
        "GET",
        &format!("/api/workspaces/{}/project-config", encode(&project)),
        None,
    )
    .await;

    // Assistant prompts (SOUL.md, CHAT.md in the node's config directory).
    r.send(
        "the assistant prompts: empty and writable",
        "GET",
        "/api/assistant/prompts",
        None,
    )
    .await;
    let put = |text: Value| json!({ "text": text, "nodeId": NODE_ID });
    r.send(
        "set the persona: CRLF and whitespace normalized",
        "PUT",
        "/api/assistant/prompts/soul",
        Some(put(json!(
            "  A unique persona marker.\r\nSpeak briefly.\r\n"
        ))),
    )
    .await;
    r.note(
        "kept in the node's config directory as SOUL.md",
        json!(fs::read_to_string(config.join("SOUL.md")).ok()),
    );
    r.send(
        "set the chat rules (CHAT.md)",
        "PUT",
        "/api/assistant/prompts/chat",
        Some(put(json!("A unique chat rules marker."))),
    )
    .await;
    r.send(
        "an unknown prompt name: 400",
        "PUT",
        "/api/assistant/prompts/agents",
        Some(put(json!("x"))),
    )
    .await;
    r.send(
        "over 8000 characters: 413",
        "PUT",
        "/api/assistant/prompts/soul",
        Some(put(json!("x".repeat(8001)))),
    )
    .await;
    r.send(
        "an extra key: 400",
        "PUT",
        "/api/assistant/prompts/soul",
        Some(json!({ "text": "x", "nodeId": NODE_ID, "extra": true })),
    )
    .await;
    r.send(
        "another chat node's id: 409",
        "PUT",
        "/api/assistant/prompts/soul",
        Some(json!({ "text": "x", "nodeId": "other" })),
    )
    .await;
    r.send(
        "empty text removes the prompt",
        "PUT",
        "/api/assistant/prompts/chat",
        Some(put(json!(""))),
    )
    .await;
    r.note("CHAT.md is gone", json!(config.join("CHAT.md").exists()));
    std::os::unix::fs::symlink(config.join("elsewhere.md"), config.join("CHAT.md")).unwrap();
    r.send(
        "a symlinked prompt is reported read-only",
        "GET",
        "/api/assistant/prompts",
        None,
    )
    .await;
    r.send(
        "and is not replaced: 409",
        "PUT",
        "/api/assistant/prompts/chat",
        Some(put(json!("do not replace"))),
    )
    .await;
    fs::remove_file(config.join("CHAT.md")).unwrap();
    r.send(
        "set the chat rules again",
        "PUT",
        "/api/assistant/prompts/chat",
        Some(put(json!("A unique chat rules marker."))),
    )
    .await;

    // A chat in the project: persona, rules and instructions reach its agent.
    let mut second = open_chat(&api, &project).await;
    cluster.llm.push([Reply::Text("Trains it is.".to_owned())]);
    second.prompt(&api, "command-second", "Plan a trip").await;
    second.live.until(settled).await;
    let request = cluster.llm.requests().last().cloned().unwrap();
    let prompt = system_prompt(&request);
    let at = |needle: &str| prompt.find(needle);
    r.note(
        "a project chat's system prompt: the persona replaces the built-in identity, then the chat environment, the chat rules and the project's instructions",
        json!({
            "persona (SOUL.md)": prompt.contains("A unique persona marker.\nSpeak briefly."),
            "built-in identity": prompt.contains(CHAT_IDENTITY),
            "chat environment": prompt.contains(CHAT_ENVIRONMENT),
            "chat rules (CHAT.md)": prompt.contains("A unique chat rules marker."),
            "project instructions heading": prompt.contains("## Project instructions"),
            "project instructions": prompt.contains("Plan trips on a budget."),
            "coding identity": prompt.contains(CODING_IDENTITY),
            "in that order": at("A unique persona marker.") < at(CHAT_ENVIRONMENT)
                && at(CHAT_ENVIRONMENT) < at("A unique chat rules marker.")
                && at("A unique chat rules marker.") < at("Plan trips on a budget."),
        }),
    );
    let project_sessions = state.join("chat").join(&local).join("sessions");
    let second_dirs = entries(&project_sessions);
    r.note(
        "the project chat's own directory: <state>/chat/<project>/sessions/<node session id>",
        json!({ "directories": second_dirs,
            "named after the gateway's session id": second_dirs == [second.id.clone()] }),
    );
    let private_before = entries(&state.join("sessions"));
    r.note(
        "the node's private session directories (<state>/sessions), one per session",
        json!(private_before.len()),
    );

    // Deleting chats.
    let path = format!("/api/sessions/{}", second.id);
    r.send(
        "delete the project chat while its runner is alive: 204",
        "DELETE",
        &path,
        None,
    )
    .await;
    let frames = second
        .live
        .until(|frame| frame["type"] == "session_deleted")
        .await;
    let deleted = frames.last().unwrap();
    r.note(
        "the open event stream gets session_deleted",
        json!({ "type": deleted["type"], "data": deleted["data"],
            "is the session": deleted["data"]["sessionId"] == json!(second.id) }),
    );
    // The gateway does not close the stream (not recorded: no event marks it).
    r.note(
        "the chat's directory is gone",
        json!(entries(&project_sessions)),
    );
    r.note(
        "its private session directory is gone",
        json!(entries(&state.join("sessions")).len() + 1 == private_before.len()),
    );
    r.send("delete it again: 204", "DELETE", &path, None).await;
    r.send(
        "its snapshot after deletion",
        "GET",
        &format!("{path}/snapshot"),
        None,
    )
    .await;
    r.send(
        "a command after deletion",
        "POST",
        &format!("{path}/commands"),
        Some(json!({ "commandId": "command-late", "clientId": "browser",
            "generation": second.generation,
            "payload": { "type": "prompt", "message": "Still there?" } })),
    )
    .await;
    r.send(
        "renaming after deletion",
        "PATCH",
        &path,
        Some(json!({ "name": "Gone" })),
    )
    .await;

    // A chat deleted in the middle of a run (waiting on a question).
    let question = "const r = await tools.call(\"ask_user_question\", { questions: [{ question: \"Which city?\" }] });\nreturn JSON.stringify(r);";
    cluster.llm.push([Reply::Tool {
        id: "q1".to_owned(),
        name: "ptc".to_owned(),
        args: json!({ "code": question }),
    }]);
    first.prompt(&api, "command-ask", "Ask me something").await;
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let snapshot = api
            .send(
                "GET",
                &format!("/api/sessions/{}/snapshot", first.id),
                &browser_headers(),
                None,
            )
            .await;
        if snapshot.body["interactions"]
            .as_array()
            .is_some_and(|items| !items.is_empty())
        {
            r.note(
                "a run waiting on the user's answer",
                json!({ "run": snapshot.body["run"]["status"],
                    "interactions": snapshot.body["interactions"].as_array().unwrap().len() }),
            );
            break;
        }
        assert!(
            Instant::now() < deadline,
            "no interaction: {}",
            snapshot.body
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let path = format!("/api/sessions/{}", first.id);
    r.send(
        "delete the chat during the run: the runner is stopped, 204",
        "DELETE",
        &path,
        None,
    )
    .await;
    first
        .live
        .until(|frame| frame["type"] == "session_deleted")
        .await;
    r.note(
        "its directory is gone, and so is its private session directory",
        json!({ "chat directories": entries(&state.join("chat/chats/sessions")),
            "private session directories": entries(&state.join("sessions")).len() }),
    );
    r.send("no chats are left", "GET", "/api/sessions", None)
        .await;
    r.send(
        "deleting an unknown session: 404",
        "DELETE",
        "/api/sessions/session_00000000-0000-4000-8000-000000000000",
        None,
    )
    .await;
    r.note("model requests", json!(cluster.llm.requests().len()));

    insta::assert_json_snapshot!("node_chat", t.into_value());
}

/// Start `chat` or coding node on `root`'s state against `gateway`, accept
/// its link and return its `register` frame.
async fn registered(
    root: &NodeRoot,
    gateway: &FakeGateway,
    name: &str,
    chat: bool,
    command: &(PathBuf, Vec<&'static str>),
) -> (NodeProcess, NodeLink, Value) {
    let mut extra = Vec::new();
    if !chat {
        extra.push(("PIRC_WORKSPACES", root.workspaces()));
    }
    let process = NodeProcess::spawn(root, name, command, &root.env(gateway.port(), &extra));
    let mut link = gateway.accept().await;
    let register = link.recv().await;
    assert_eq!(register["type"], "register", "{register}");
    link.send(&json!({ "type": "registered", "nodeId": NODE_ID,
        "models": { "providers": {} }, "mirrors": {} }))
        .await;
    (process, link, register)
}

/// The workspaces of a `register` frame: id, kind and display name.
fn registered_workspaces(register: &Value) -> Value {
    register["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| json!({ "id": w["id"], "mode": w["mode"], "displayName": w["displayName"] }))
        .collect()
}

/// Start a node that must refuse to start: its exit status, and whether
/// its output says why.
fn refused(
    root: &NodeRoot,
    name: &str,
    command: &(PathBuf, Vec<&'static str>),
    env: &[(String, String)],
    reason: &str,
) -> Value {
    let mut process = NodeProcess::spawn(root, name, command, env);
    let status = process.wait_exit();
    let log = process.log();
    json!({ "exit code": status.code(), "output names the reason": log.contains(reason) })
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_chat_startup() {
    let (Some(chat), Some(coding)) = (node_command(true), node_command(false)) else {
        return;
    };
    let gateway = FakeGateway::bind().await;
    let root = NodeRoot::new();
    let mut t = Transcript::new(root.volatile());
    let mut ids = Ids::default();

    t.note(
        "a chat node with PIRC_WORKSPACES set exits",
        refused(
            &root,
            "chat-with-workspaces",
            &chat,
            &root.env(gateway.port(), &[("PIRC_WORKSPACES", root.workspaces())]),
            "PIRC_WORKSPACES must be empty on the chat node",
        ),
    );
    for (step, name, command) in [
        (
            "a chat node with PIRC_CHAT set exits",
            "chat-with-pirc-chat",
            &chat,
        ),
        (
            "a coding node with PIRC_CHAT set exits",
            "node-with-pirc-chat",
            &coding,
        ),
    ] {
        let mut extra = vec![("PIRC_CHAT", "1".to_owned())];
        if name.starts_with("node") {
            extra.push(("PIRC_WORKSPACES", root.workspaces()));
        }
        t.note(
            step,
            refused(
                &root,
                name,
                command,
                &root.env(gateway.port(), &extra),
                "PIRC_CHAT was removed",
            ),
        );
    }

    // A chat node's state, with a project, then a coding node on it.
    let extra = [("PIRC_WORKSPACES", "[]".to_owned())];
    let mut process = NodeProcess::spawn(&root, "chat-1", &chat, &root.env(gateway.port(), &extra));
    let mut link = gateway.accept().await;
    let register = link.recv().await;
    link.send(&json!({ "type": "registered", "nodeId": NODE_ID,
        "models": { "providers": {} }, "mirrors": {} }))
        .await;
    t.note(
        "a chat node (PIRC_WORKSPACES=[]) registers its top-level chats",
        json!({ "role": register["role"], "workspaces": registered_workspaces(&register) }),
    );
    let created = link
        .request(
            "request-1",
            json!({ "method": "POST", "url": "/api/workspaces", "user": USER,
                "payload": { "mode": "chat", "displayName": "Trip" } }),
        )
        .await;
    let mut masked = ids.value(&created["data"]);
    masked["body"]["workspace"]["canonicalPath"] = json!(
        masked["body"]["workspace"]["canonicalPath"]
            .as_str()
            .map(|path| { path.replace(&root.root.display().to_string(), "<tmp>") })
    );
    t.note("the node's answer to a new chat project", masked);
    process.stop();
    drop(link);

    t.note(
        "a coding node on the chat node's state exits",
        refused(
            &root,
            "node-on-chat-state",
            &coding,
            &root.env(gateway.port(), &[("PIRC_WORKSPACES", root.workspaces())]),
            "State contains workspaces incompatible with configured accepted modes",
        ),
    );
    let (mut again, _link, register) = registered(&root, &gateway, "chat-2", true, &chat).await;
    let workspaces = ids.value(&registered_workspaces(&register));
    t.note(
        "the chat node starts again on its state, unchanged: its project is still there",
        workspaces,
    );
    again.stop();

    // A coding node's state, then a chat node on it.
    let coding_root = NodeRoot::new();
    let (mut node, _link, register) =
        registered(&coding_root, &gateway, "node-1", false, &coding).await;
    t.note(
        "a coding node registers its configured workspace",
        json!({ "role": register["role"], "workspaces": registered_workspaces(&register) }),
    );
    node.stop();
    t.note(
        "a chat node on the coding node's state exits",
        refused(
            &coding_root,
            "chat-on-node-state",
            &chat,
            &coding_root.env(gateway.port(), &[]),
            "State contains workspaces incompatible with configured accepted modes",
        ),
    );
    let (mut node, _link, register) =
        registered(&coding_root, &gateway, "node-2", false, &coding).await;
    t.note(
        "the coding node starts again on its state, unchanged",
        registered_workspaces(&register),
    );
    node.stop();

    insta::assert_json_snapshot!("node_chat_startup", t.into_value());
}

/// A project's files as recorded: `modifiedAt` only as "a time".
fn files_view(body: &Value) -> Value {
    let files: Vec<Value> = body["files"]
        .as_array()
        .map(|files| {
            files
                .iter()
                .map(|file| {
                    json!({ "name": file["name"], "byteSize": file["byteSize"],
                        "modifiedAt is a time": file["modifiedAt"].as_i64().is_some_and(|ms| ms > 0) })
                })
                .collect()
        })
        .unwrap_or_default();
    json!({ "files": files, "maxFiles": body["maxFiles"],
        "maxBytes is a number": body["maxBytes"].is_u64() })
}

/// The last tool result in a model request, as JSON text.
fn tool_text(request: &Value) -> String {
    request["messages"]
        .as_array()
        .unwrap()
        .iter()
        .rev()
        .find(|message| message["role"] == "tool")
        .map(|message| message["content"].to_string())
        .unwrap_or_default()
}

/// A chat project's files: uploaded, listed, replaced and removed through
/// the gateway, kept in `<state>/chat/<project>/files`, read (never
/// written) by the project's chats, also when added while a chat runs, and
/// removed with the project.
#[ignore = "pirc 2: needs a session created through first-send instead of the removed POST /api/sessions; rewritten after M4 (plans/roadmap.md M2.9)"]
#[tokio::test(flavor = "multi_thread")]
async fn node_chat_project_files() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        chat_node: true,
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let root = cluster.dir.path().canonicalize().unwrap();
    let state = root.join("node-state");
    let api = cluster.api();
    let mut t = Transcript::new(cluster.volatile());
    let mut ids = Ids::default();
    let mut r = Recorder {
        api: api.clone(),
        t: &mut t,
        ids: &mut ids,
    };
    let created = r
        .send(
            "create a chat project",
            "POST",
            "/api/workspaces",
            Some(json!({ "nodeId": NODE_ID, "mode": "chat", "displayName": "Trip" })),
        )
        .await;
    let project = created["workspace"]["id"].as_str().unwrap().to_owned();
    let local = project.strip_prefix("test:").unwrap().to_owned();
    let files = format!("/api/workspaces/{}/files", encode(&project));
    let dir = state.join("chat").join(&local).join("files");

    let listed = api.send("GET", &files, &browser_headers(), None).await;
    r.note(
        "a new project has no files, and no files directory",
        json!({ "status": listed.status, "body": files_view(&listed.body),
            "directory exists": dir.exists() }),
    );
    let upload = |name: &str, content: &[u8]| {
        let (api, path) = (api.clone(), format!("{files}?filename={name}"));
        let content = content.to_vec();
        async move {
            api.send_bytes(
                "POST",
                &path,
                &browser_headers(),
                Some("text/plain"),
                content,
            )
            .await
        }
    };
    let added = upload("notes%2Fa.txt", b"alpha").await;
    r.note(
        "upload a.txt (the name's last path component is kept): 201",
        json!({ "status": added.status, "name": added.body["file"]["name"],
            "byteSize": added.body["file"]["byteSize"] }),
    );
    r.note(
        "kept on the node in <state>/chat/<project>/files",
        json!({ "files": entries(&dir),
            "a.txt": fs::read_to_string(dir.join("a.txt")).ok() }),
    );
    for (step, name, body) in [
        ("a hidden name: 400", ".env", b"x".to_vec()),
        ("an empty name: 400", "", b"x".to_vec()),
        ("an empty body: 413", "empty.txt", Vec::new()),
    ] {
        let refused = upload(name, &body).await;
        r.note(
            step,
            json!({ "status": refused.status, "body": refused.body }),
        );
    }
    let json_body = api
        .send(
            "POST",
            &format!("{files}?filename=x.json"),
            &browser_headers(),
            Some(json!({})),
        )
        .await;
    r.note(
        "a JSON body: 400",
        json!({ "status": json_body.status, "body": json_body.body }),
    );
    let listed = api.send("GET", &files, &browser_headers(), None).await;
    r.note("listed", files_view(&listed.body));
    r.send(
        "the top-level chats have project files too (none)",
        "GET",
        &format!("/api/workspaces/{}/files", encode(CHATS_WORKSPACE_ID)),
        None,
    )
    .await;
    r.send(
        "files of an unknown workspace: 404",
        "GET",
        "/api/workspaces/test%3Anope/files",
        None,
    )
    .await;

    // A chat in the project reads them, cannot write them, and sees a file
    // added while it runs.
    let mut chat = open_chat(&api, &project).await;
    let dir_text = dir.display().to_string();
    let read = |name: &str| {
        format!(
            "const r = await tools.read({{ path: {} }}); return JSON.stringify(r);",
            json!(format!("{dir_text}/{name}"))
        )
    };
    let write = format!(
        "try {{ await tools.write({{ path: {}, content: \"x\" }}); return \"written\"; }} catch (error) {{ return \"refused\"; }}",
        json!(format!("{dir_text}/a.txt"))
    );
    cluster.llm.push([
        Reply::Tool {
            id: "read-a".to_owned(),
            name: "ptc".to_owned(),
            args: json!({ "code": read("a.txt") }),
        },
        Reply::Tool {
            id: "write-a".to_owned(),
            name: "ptc".to_owned(),
            args: json!({ "code": write }),
        },
        Reply::Text("Read it.".to_owned()),
    ]);
    chat.prompt(&api, "command-files", "What is in my files?")
        .await;
    chat.live.until(settled).await;
    let requests = cluster.llm.requests();
    let prompt = system_prompt(&requests[requests.len() - 3]);
    r.note(
        "the chat's system prompt names the directory, read-only",
        json!({
            "heading": prompt.contains("## Project files"),
            "the directory": prompt.contains(&format!("`{dir_text}`")),
            "read-only": prompt.contains("They are read-only"),
        }),
    );
    r.note(
        "the agent reads a.txt, and cannot write it",
        json!({
            "read": tool_text(&requests[requests.len() - 2]).contains("alpha"),
            "write": tool_text(&requests[requests.len() - 1]).contains("refused"),
            "a.txt unchanged": fs::read_to_string(dir.join("a.txt")).ok(),
        }),
    );
    let added = upload("b.txt", b"beta").await;
    let replaced = upload("a.txt", b"alpha 2").await;
    r.note(
        "while the chat runs: add b.txt, replace a.txt",
        json!({ "b.txt": added.status, "a.txt": replaced.status }),
    );
    cluster.llm.push([
        Reply::Tool {
            id: "read-b".to_owned(),
            name: "ptc".to_owned(),
            args: json!({ "code": read("b.txt") }),
        },
        Reply::Tool {
            id: "read-a2".to_owned(),
            name: "ptc".to_owned(),
            args: json!({ "code": read("a.txt") }),
        },
        Reply::Text("Read them.".to_owned()),
    ]);
    chat.prompt(&api, "command-files-2", "And now?").await;
    chat.live.until(settled).await;
    let requests = cluster.llm.requests();
    r.note(
        "the running chat reads the new file and the replaced one",
        json!({
            "b.txt": tool_text(&requests[requests.len() - 2]).contains("beta"),
            "a.txt": tool_text(&requests[requests.len() - 1]).contains("alpha 2"),
        }),
    );

    r.send(
        "remove b.txt: 204",
        "DELETE",
        &format!("{files}?name=b.txt"),
        None,
    )
    .await;
    r.send(
        "remove it again: 404",
        "DELETE",
        &format!("{files}?name=b.txt"),
        None,
    )
    .await;
    r.send("remove without a name: 400", "DELETE", &files, None)
        .await;
    r.note("left on the node", json!(entries(&dir)));

    // Deleting the project removes its files.
    r.send(
        "delete the project: 204",
        "POST",
        &format!("/api/workspaces/{}/deletion", encode(&project)),
        Some(json!({ "decisions": [] })),
    )
    .await;
    r.note(
        "the project's directory is gone, files included",
        json!(state.join("chat").join(&local).exists()),
    );
    r.send("files of the deleted project: 404", "GET", &files, None)
        .await;

    insta::assert_json_snapshot!("node_chat_project_files", t.into_value());
}
