//! Deleting a chat project through a real gateway and chat node
//! (docs/guides/chat-projects.md, "Deleting a project"): what the preview
//! lists, the memory its chats wrote (forgotten, rolled back, or decided by
//! the user), its chats, uploads and directory removed on the node, and the
//! project not coming back. Checked with assertions rather than a recorded
//! transcript.

use std::fs;
use std::path::Path;

use pirc_conformance::{
    Api, CHATS_WORKSPACE_ID, Cluster, GatewayOptions, NODE_ID, Reply, browser_headers,
};
use serde_json::{Value, json};

/// A 1×1 PNG.
const PIXEL: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
];

fn encode(id: &str) -> String {
    id.replace(':', "%3A")
}

async fn send(api: &Api, method: &str, path: &str, body: Option<Value>) -> (u16, Value) {
    let response = api.send(method, path, &browser_headers(), body).await;
    (response.status, response.body)
}

/// A chat with control, and its event stream.
struct Chat {
    id: String,
    generation: Value,
    live: pirc_conformance::WebSocket,
}

async fn open_chat(api: &Api, workspace: &str) -> Chat {
    let (status, created) = send(
        api,
        "POST",
        "/api/sessions",
        Some(json!({ "workspaceId": workspace })),
    )
    .await;
    assert_eq!(status, 201, "{created}");
    let id = created["session"]["id"].as_str().unwrap().to_owned();
    let (_, acquired) = send(
        api,
        "POST",
        &format!("/api/sessions/{id}/control/acquire"),
        Some(json!({ "clientId": "browser" })),
    )
    .await;
    let (_, before) = send(api, "GET", &format!("/api/sessions/{id}/snapshot"), None).await;
    let watermark = &before["watermark"];
    let live = api
        .connect(
            &format!(
                "/api/events?sessionId={id}&cursor={}:{}",
                watermark["epoch"], watermark["sequence"]
            ),
            &browser_headers(),
        )
        .await
        .open();
    Chat {
        id,
        generation: acquired["lease"]["generation"].clone(),
        live,
    }
}

impl Chat {
    async fn command(&self, api: &Api, command: &str, payload: Value) -> (u16, Value) {
        send(
            api,
            "POST",
            &format!("/api/sessions/{}/commands", self.id),
            Some(json!({ "commandId": command, "clientId": "browser",
                "generation": self.generation, "payload": payload })),
        )
        .await
    }

    /// Run `code` as the agent's `ptc` call, then let it finish.
    async fn run(&mut self, cluster: &Cluster, api: &Api, command: &str, code: &str) {
        cluster.llm.push([
            Reply::Tool {
                id: format!("{command}-tool"),
                name: "ptc".to_owned(),
                args: json!({ "code": code }),
            },
            Reply::Text("Done.".to_owned()),
        ]);
        let (status, body) = self
            .command(
                api,
                command,
                json!({ "type": "prompt", "message": "Note it" }),
            )
            .await;
        assert_eq!(status, 202, "{body}");
        self.live
            .until(|frame| frame["type"] == "pi_event" && frame["data"]["type"] == "agent_settled")
            .await;
    }
}

fn note(content: &str) -> String {
    format!(
        "return JSON.stringify(await tools.call(\"memory_note\", {{ action: \"add\", content: {} }}));",
        json!(content)
    )
}

fn replace(id: &str, content: &str) -> String {
    format!(
        "return JSON.stringify(await tools.call(\"memory_note\", {{ action: \"replace\", id: {}, content: {} }}));",
        json!(id),
        json!(content)
    )
}

/// The active note with `content`.
async fn note_id(api: &Api, content: &str) -> Option<(String, i64)> {
    let (_, memory) = send(api, "GET", "/api/memory", None).await;
    memory["notes"]
        .as_array()?
        .iter()
        .find(|entry| entry["content"] == content)
        .map(|entry| {
            (
                entry["id"].as_str().unwrap().to_owned(),
                entry["revision"].as_i64().unwrap(),
            )
        })
}

fn names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .map(|read| {
            read.map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn project_deletion() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        chat_node: true,
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let state = cluster
        .dir
        .path()
        .canonicalize()
        .unwrap()
        .join("node-state");
    let api = cluster.api();

    let (status, created) = send(
        &api,
        "POST",
        "/api/workspaces",
        Some(json!({ "nodeId": NODE_ID, "kind": "chat", "displayName": "Trip" })),
    )
    .await;
    assert_eq!(status, 201, "{created}");
    let project = created["workspace"]["id"].as_str().unwrap().to_owned();
    let local = project
        .strip_prefix(&format!("{NODE_ID}:"))
        .unwrap()
        .to_owned();
    let deletion = format!("/api/workspaces/{}/deletion", encode(&project));
    let (status, _) = send(
        &api,
        "PATCH",
        &format!("/api/workspaces/{}/instructions", encode(&project)),
        Some(json!({ "text": "Plan trips." })),
    )
    .await;
    assert_eq!(status, 200);
    assert!(
        state
            .join("chat")
            .join(&local)
            .join("instructions.md")
            .exists()
    );

    // Memory: a top-level chat notes something, a project chat notes its
    // own and edits that one, and a later top-level chat edits the
    // project's note.
    let mut top = open_chat(&api, CHATS_WORKSPACE_ID).await;
    top.run(&cluster, &api, "c1", &note("Tea")).await;
    top.run(&cluster, &api, "c1b", &note("Coffee")).await;
    let (tea, _) = note_id(&api, "Tea").await.expect("the top-level note");
    let (coffee, _) = note_id(&api, "Coffee").await.expect("the top-level note");
    // A project chat that changes a note, then is deleted on its own: its
    // change stays (it did not create the note) until the project goes.
    let mut early = open_chat(&api, &project).await;
    early
        .run(&cluster, &api, "c1c", &replace(&coffee, "Coffee for X"))
        .await;
    let (status, _) = send(&api, "DELETE", &format!("/api/sessions/{}", early.id), None).await;
    assert_eq!(status, 204);
    assert!(note_id(&api, "Coffee for X").await.is_some());
    let mut chat = open_chat(&api, &project).await;
    chat.run(&cluster, &api, "c2", &note("Project only")).await;
    chat.run(&cluster, &api, "c3", &replace(&tea, "Tea for X"))
        .await;
    chat.run(&cluster, &api, "c4", &note("From P")).await;
    assert!(note_id(&api, "Tea for X").await.is_some());
    let (mixed, _) = note_id(&api, "From P").await.expect("the project's note");
    let mut later = open_chat(&api, CHATS_WORKSPACE_ID).await;
    later
        .run(&cluster, &api, "c5", &replace(&mixed, "From P and S"))
        .await;
    let (_, mixed_revision) = note_id(&api, "From P and S")
        .await
        .expect("edited elsewhere");

    // Uploads: one made in the project is usable there only.
    let upload = api
        .send_bytes(
            "POST",
            &format!("/api/sessions/{}/uploads", chat.id),
            &browser_headers(),
            Some("image/png"),
            PIXEL.to_vec(),
        )
        .await;
    assert_eq!(upload.status, 201, "{}", upload.body);
    let upload_id = upload.body["upload"]["id"].as_str().unwrap().to_owned();
    let uploads_before = names(&state.join("uploads"));
    assert_eq!(uploads_before.len(), 1);
    let (status, refused) = top
        .command(
            &api,
            "c6",
            json!({ "type": "prompt", "message": "Look", "uploadIds": [upload_id] }),
        )
        .await;
    assert_eq!(status, 403, "{refused}");
    assert_eq!(
        refused["error"]["message"], "Upload belongs to another workspace",
        "{refused}"
    );

    // The preview.
    let (status, preview) = send(&api, "GET", &deletion, None).await;
    assert_eq!(status, 200, "{preview}");
    assert_eq!(preview["project"]["displayName"], "Trip");
    assert_eq!(preview["nodeOnline"], true);
    assert_eq!(preview["deleting"], false);
    assert_eq!(preview["chats"].as_array().unwrap().len(), 1);
    let action = |content: &str| -> Value {
        preview["memory"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["entry"]["content"] == content)
            .map(|item| item["action"].clone())
            .unwrap_or(Value::Null)
    };
    assert_eq!(action("Project only"), "forget", "{preview}");
    assert_eq!(action("Tea for X"), "rollback", "{preview}");
    assert_eq!(action("From P and S"), "review", "{preview}");
    assert_eq!(action("Coffee for X"), "rollback", "{preview}");
    let rollback = preview["memory"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["action"] == "rollback")
        .unwrap();
    assert_eq!(rollback["restored"], "Tea");

    // Refused: a top-level workspace, an undecided review, a stale one.
    let (status, _) = send(
        &api,
        "POST",
        &format!("/api/workspaces/{}/deletion", encode(CHATS_WORKSPACE_ID)),
        Some(json!({})),
    )
    .await;
    assert_eq!(status, 400);
    let (status, conflict) = send(&api, "POST", &deletion, Some(json!({}))).await;
    assert_eq!(status, 409, "{conflict}");
    let stale = json!({ "decisions": [{ "entryId": mixed, "revision": mixed_revision - 1,
        "action": "forget" }] });
    let (status, _) = send(&api, "POST", &deletion, Some(stale)).await;
    assert_eq!(status, 409);
    let (status, _) = send(
        &api,
        "POST",
        &deletion,
        Some(
            json!({ "decisions": [{ "entryId": mixed, "revision": mixed_revision,
            "action": "rename" }] }),
        ),
    )
    .await;
    assert_eq!(status, 400);
    // Nothing changed yet.
    assert!(note_id(&api, "Project only").await.is_some());
    assert!(state.join("chat").join(&local).exists());

    // Delete.
    let decisions = json!({ "decisions": [{ "entryId": mixed, "revision": mixed_revision,
        "action": "edit", "content": "From S" }] });
    let (status, body) = send(&api, "POST", &deletion, Some(decisions.clone())).await;
    assert_eq!(status, 204, "{body}");
    let frames = chat
        .live
        .until(|frame| frame["type"] == "session_deleted")
        .await;
    assert_eq!(frames.last().unwrap()["data"]["sessionId"], json!(chat.id));

    // Memory.
    assert!(note_id(&api, "Project only").await.is_none());
    assert!(note_id(&api, "Tea for X").await.is_none());
    assert!(note_id(&api, "Tea").await.is_some());
    assert!(note_id(&api, "Coffee").await.is_some());
    assert!(note_id(&api, "From S").await.is_some());
    let (_, history) = send(
        &api,
        "GET",
        &format!("/api/memory/entries/{tea}/history"),
        None,
    )
    .await;
    assert!(
        !history.to_string().contains("Tea for X"),
        "the project's version is erased: {history}"
    );
    // Another chat may write the project's text again.
    top.run(&cluster, &api, "c7", &note("Project only")).await;
    assert!(note_id(&api, "Project only").await.is_some());

    // The node.
    assert!(!state.join("chat").join(&local).exists());
    assert_eq!(names(&state.join("uploads")), Vec::<String>::new());
    // The gateway.
    let (_, workspaces) = send(&api, "GET", "/api/workspaces", None).await;
    assert!(!workspaces.to_string().contains(&project), "{workspaces}");
    let (_, sessions) = send(&api, "GET", "/api/sessions", None).await;
    assert!(!sessions.to_string().contains(&chat.id), "{sessions}");
    let (_, nodes) = send(&api, "GET", "/api/nodes", None).await;
    assert!(!nodes.to_string().contains(&local), "{nodes}");
    let (status, _) = send(&api, "GET", &deletion, None).await;
    assert_eq!(status, 404);
    let (status, _) = send(
        &api,
        "GET",
        &format!("/api/workspaces/{}/instructions", encode(&project)),
        None,
    )
    .await;
    assert_eq!(status, 404);
    // Again: done.
    let (status, _) = send(&api, "POST", &deletion, Some(decisions)).await;
    assert_eq!(status, 204);
    // A new project with the same name is new.
    let (status, again) = send(
        &api,
        "POST",
        "/api/workspaces",
        Some(json!({ "nodeId": NODE_ID, "kind": "chat", "displayName": "Trip" })),
    )
    .await;
    assert_eq!(status, 201);
    assert_ne!(again["workspace"]["id"], json!(project));
    let (_, instructions) = send(
        &api,
        "GET",
        &format!(
            "/api/workspaces/{}/instructions",
            encode(again["workspace"]["id"].as_str().unwrap())
        ),
        None,
    )
    .await;
    assert_eq!(instructions["instructions"]["text"], "");
}
