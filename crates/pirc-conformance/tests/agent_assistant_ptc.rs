//! The assistant's tools in chat sessions (`agent/features/assistant/`):
//! `memory_note`, `memory_propose_user`, `delegate`, `delegation_status`
//! and `memory_search`, with `recall` reaching the gateway, the test
//! playing the agent's node and gateway. They are reachable only from
//! `ptc` scripts, so these transcripts replay only on an agent with the
//! PTC runtime (docs/architecture/ptc.md). The rest of the feature is in
//! `agent_assistant.rs`.

mod memory_support;

mod feature_support;

use memory_support::*;
use pirc_conformance::{AgentOptions, AgentRun, ModelReply};
use serde_json::{Value, json};

fn chat(features: &str) -> AgentOptions {
    let mut options = AgentOptions {
        files: vec![("plan.txt".to_owned(), "the plan\n".to_owned())],
        ..AgentOptions::default()
    }
    .features(features);
    options.env.extend([
        ("PIRC_GATEWAY".to_owned(), "1".to_owned()),
        (
            "PIRC_MODE".to_owned(),
            serde_json::to_string(&pirc_protocol::mode::default_chat()).unwrap(),
        ),
    ]);
    options
}

fn memory(extra: Value) -> Value {
    let mut out = json!({ "enabled": true, "user": [], "notes": [],
        "usage": { "user": { "used": 0, "max": 2000 }, "note": { "used": 0, "max": 8000 } },
        "pendingProposals": 0 });
    for (key, value) in extra.as_object().unwrap() {
        out[key] = value.clone();
    }
    out
}

fn ok(result: Value) -> Value {
    json!({ "ok": true, "result": result })
}

fn fail(status: u16, code: &str, message: &str, details: Option<Value>) -> Value {
    let mut error = json!({ "status": status, "code": code, "message": message });
    if let Some(details) = details {
        error["details"] = details;
    }
    json!({ "ok": false, "error": error })
}

fn answer(agent: &AgentRun, op: &str, replies: impl IntoIterator<Item = Value>) {
    agent
        .answers
        .lock()
        .unwrap()
        .gateway_queue
        .entry(op.to_owned())
        .or_default()
        .extend(replies);
}

fn call(id: &str, name: &str, args: Value) -> ModelReply {
    ModelReply::Tools(vec![ptc(id, name, args)])
}

fn usage() -> Value {
    json!({ "used": 40, "max": 8000 })
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_notes_and_proposals() {
    let Some(mut agent) = AgentRun::start(chat("assistant")).await else {
        return;
    };
    let mut log = Log::new(&agent);
    answer(
        &agent,
        "assistant.context",
        [ok(memory(
            json!({ "notes": [{ "id": "n33333333", "content": "Old plan.", "revision": 1 }] }),
        ))],
    );
    answer(
        &agent,
        "memory.proposeUser",
        [
            ok(json!({ "proposalId": "p1234abcd", "duplicate": false })),
            ok(json!({ "proposalId": "p1234abcd", "duplicate": true })),
        ],
    );
    answer(
        &agent,
        "memory.note",
        [
            ok(json!({ "id": "n44444444", "revision": 1, "unchanged": false, "usage": usage() })),
            fail(
                409,
                "conflict",
                "changed",
                Some(json!({ "id": "n33333333", "revision": 3, "content": "Newer plan." })),
            ),
            ok(json!({ "id": "n33333333", "revision": 4, "unchanged": false, "usage": usage() })),
            ok(json!({ "id": "n44444444", "revision": 1, "unchanged": true, "usage": usage() })),
            ok(json!({ "id": "n44444444", "revision": 2, "unchanged": false, "usage": usage() })),
            fail(503, "gateway_offline", "offline", None),
            fail(409, "forgotten", "forgotten", None),
            fail(400, "too_long", "MEMORY is full (8,000 characters).", None),
        ],
    );
    let key = format!("sk-{}", "x".repeat(24));
    agent.push([
        call(
            "p1",
            "memory_propose_user",
            json!({ "action": "add",
            "content": "Wants to be called Ice.", "quote": "“Call me  Ice”" }),
        ),
        call(
            "p2",
            "memory_propose_user",
            json!({ "action": "add",
            "content": "Is called Bob.", "quote": "call me Bob" }),
        ),
        call(
            "p3",
            "memory_propose_user",
            json!({ "action": "replace",
            "id": "u1", "content": "Ice.", "quote": "call me ice" }),
        ),
        call(
            "p4",
            "memory_propose_user",
            json!({ "action": "remove", "quote": "call me ice" }),
        ),
        call(
            "p5",
            "memory_propose_user",
            json!({ "action": "rename", "quote": "x" }),
        ),
        call("r1", "read", json!({ "path": "plan.txt" })),
        call(
            "n1",
            "memory_note",
            json!({ "action": "add", "content": "The plan is in plan.txt." }),
        ),
        call(
            "n2",
            "memory_note",
            json!({ "action": "replace", "id": "n33333333",
            "content": "Plan moved." }),
        ),
        call(
            "n3",
            "memory_note",
            json!({ "action": "replace", "id": "n33333333",
            "content": "Plan moved." }),
        ),
        call(
            "n4",
            "memory_note",
            json!({ "action": "add", "content": "The plan is in plan.txt.",
            "quote": "Please call me Ice" }),
        ),
        call(
            "n5",
            "memory_note",
            json!({ "action": "remove", "id": " n44444444 " }),
        ),
        call(
            "n6",
            "memory_note",
            json!({ "action": "add", "content": format!("Key {key}") }),
        ),
        call(
            "n7",
            "memory_note",
            json!({ "action": "add", "content": "Forgotten thing." }),
        ),
        call(
            "n8",
            "memory_note",
            json!({ "action": "add", "content": "Too much." }),
        ),
        call(
            "n9",
            "memory_note",
            json!({ "action": "add", "content": "x", "quote": "never said" }),
        ),
        call(
            "n10",
            "memory_note",
            json!({ "action": "replace", "content": "x" }),
        ),
        call(
            "n11",
            "memory_note",
            json!({ "action": "add", "content": "  " }),
        ),
        call("n12", "memory_note", json!({ "action": "edit" })),
        text("Done."),
    ]);
    log.turn(&mut agent, "prompt", "Please call me Ice from now on.")
        .await;
    log.session(&agent);
    insta::assert_json_snapshot!(
        "agent_assistant_notes_and_proposals",
        feature_support::without_ptc_progress(log.into_value())
    );
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_revisions_after_restart() {
    let Some(mut agent) = AgentRun::start(chat("assistant")).await else {
        return;
    };
    let mut log = Log::new(&agent);
    answer(&agent, "assistant.context", [ok(memory(json!({})))]);
    answer(
        &agent,
        "memory.note",
        [ok(
            json!({ "id": "n55555555", "revision": 1, "unchanged": false, "usage": usage() }),
        )],
    );
    agent.push([
        call(
            "n1",
            "memory_note",
            json!({ "action": "add", "content": "Fact." }),
        ),
        text("Saved."),
    ]);
    log.turn(&mut agent, "first process", "remember this fact")
        .await;
    let Some(mut agent) = agent.restart(chat("assistant")).await else {
        return;
    };
    answer(&agent, "assistant.context", [ok(memory(json!({})))]);
    answer(
        &agent,
        "memory.note",
        [ok(
            json!({ "id": "n55555555", "revision": 2, "unchanged": false, "usage": usage() }),
        )],
    );
    agent.push([
        call(
            "n2",
            "memory_note",
            json!({ "action": "replace", "id": "n55555555",
            "content": "Better fact." }),
        ),
        text("Updated."),
    ]);
    log.turn(&mut agent, "second process", "fix it").await;
    log.session(&agent);
    insta::assert_json_snapshot!(
        "agent_assistant_revisions_after_restart",
        feature_support::without_ptc_progress(log.into_value())
    );
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_delegation() {
    let Some(mut agent) = AgentRun::start(chat("assistant")).await else {
        return;
    };
    let mut log = Log::new(&agent);
    answer(
        &agent,
        "assistant.context",
        [ok(memory(json!({ "workspaces": [
            { "id": "work:test", "name": "Test", "node": "work", "online": true },
            { "id": "lab:x", "name": "X", "node": "lab", "online": false }] })))],
    );
    answer(
        &agent,
        "delegation.create",
        [
            ok(
                json!({ "id": "d12345678", "title": "Fix build", "workspace": "Test on work",
                "status": "pending_approval" }),
            ),
            // No workspace and no links: the gateway asks for one.
            fail(
                400,
                "invalid_input",
                "Name a workspace, or an earlier delegation to follow up",
                None,
            ),
            ok(
                json!({ "id": "d87654321", "title": "Review", "workspace": "Test on work",
                "status": "pending_approval", "role": "reviewer" }),
            ),
            fail(404, "not_found", "No workspace named nowhere", None),
        ],
    );
    answer(
        &agent,
        "delegation.status",
        [
            ok(
                json!({ "delegations": [{ "id": "d12345678", "title": "Fix build",
                "workspace": "Test on work", "status": "completed", "session": "Fix build",
                "result": "Build fixed." }] }),
            ),
            ok(
                json!({ "delegations": [{ "id": "d12345678", "title": "Fix build",
                "workspace": "Test on work", "status": "completed", "result": "Build",
                "resultOffset": 0, "resultChars": 12, "nextOffset": 5 }] }),
            ),
            ok(
                json!({ "delegations": [{ "id": "d12345678", "title": "Fix build",
                "workspace": "Test on work", "status": "completed", "result": " fixed.",
                "resultOffset": 5, "resultChars": 12 }] }),
            ),
            ok(json!({ "delegations": [] })),
        ],
    );
    agent.push([
        call(
            "d1",
            "delegate",
            json!({ "workspace": "work:test", "task": "Fix the build.",
            "title": "Fix build" }),
        ),
        call("d2", "delegate", json!({ "task": "Somewhere." })),
        call(
            "d3",
            "delegate",
            json!({ "follows": "d12345678", "task": "Now review it.",
            "role": "reviewer" }),
        ),
        call(
            "d4",
            "delegate",
            json!({ "workspace": "nowhere", "task": "x" }),
        ),
        call(
            "d5",
            "delegate",
            json!({ "workspace": "work:test", "task": "  " }),
        ),
        call("s1", "delegation_status", json!({})),
        call("s2", "delegation_status", json!({ "id": "d12345678" })),
        call(
            "s3",
            "delegation_status",
            json!({ "id": "d12345678", "offset": 5 }),
        ),
        call("s4", "delegation_status", json!({})),
        text("Asked."),
    ]);
    log.turn(&mut agent, "prompt", "get the build fixed over there")
        .await;
    insta::assert_json_snapshot!(
        "agent_assistant_delegation",
        feature_support::without_ptc_progress(log.into_value())
    );
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_search_and_recall() {
    let Some(mut agent) = AgentRun::start(chat("observational-memory,assistant")).await else {
        return;
    };
    let mut log = Log::new(&agent);
    answer(&agent, "assistant.context", [ok(memory(json!({})))]);
    answer(
        &agent,
        "memory.search",
        [
            ok(json!({ "hits": [
                { "id": "abcdefabcdef", "kind": "workspace", "workspace": "pirc on m5pro",
                  "date": "2026-09-27 10:05", "status": "active", "git": "main@abcdef1",
                  "content": "Deploys go through staging first." },
                { "id": "d12345678", "kind": "delegation", "workspace": "pirc on m5pro",
                  "date": "2026-09-28 09:00", "status": "completed", "content": "Fix deploy: done" },
                { "id": "bbbbbbbbbbbb", "kind": "workspace", "workspace": "pirc on m5pro",
                  "date": "2026-09-01 09:00", "status": "retired", "content": "Old note." }] })),
            ok(json!({ "hits": [] })),
        ],
    );
    answer(
        &agent,
        "recall.remote",
        [
            ok(json!({ "text": "pirc on m5pro:\nDeploy through staging first.", "status": "ok" })),
            fail(
                404,
                "not_found",
                "No workspace memory note 000000000000",
                None,
            ),
            fail(502, "node_offline", "The node is offline", None),
        ],
    );
    agent.push([
        call(
            "q1",
            "memory_search",
            json!({ "query": "staging", "limit": 3 }),
        ),
        call(
            "q2",
            "memory_search",
            json!({ "query": "nothing", "workspace": " pirc ",
            "limit": 99.7 }),
        ),
        call("q3", "memory_search", json!({ "query": "  " })),
        call("r1", "recall", json!({ "id": "abcdefabcdef" })),
        call("r2", "recall", json!({ "id": "000000000000" })),
        call("r3", "recall", json!({ "id": "111111111111" })),
        text("Found it."),
    ]);
    log.turn(&mut agent, "prompt", "what did we decide about deploys?")
        .await;
    insta::assert_json_snapshot!(
        "agent_assistant_search_and_recall",
        feature_support::without_ptc_progress(log.into_value())
    );
}

/// In a project linked to workspaces: the list marks them, `delegate` may
/// leave the workspace out, and `memory_search` says where it looked.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_project_links() {
    let Some(mut agent) = AgentRun::start(chat("assistant")).await else {
        return;
    };
    let mut log = Log::new(&agent);
    answer(
        &agent,
        "assistant.context",
        [ok(memory(json!({ "workspaces": [
            { "id": "work:test", "name": "Test", "node": "work", "online": true,
                "repo": "github.com/me/test", "linked": "workspace" },
            { "id": "lab:test", "name": "Test", "node": "lab", "online": false,
                "repo": "github.com/me/test", "linked": "repository" },
            { "id": "lab:x", "name": "X", "node": "lab", "online": true }] })))],
    );
    answer(
        &agent,
        "delegation.create",
        [ok(
            json!({ "id": "d12345678", "title": "Fix build", "workspace": "Test on work",
            "status": "pending_approval" }),
        )],
    );
    answer(
        &agent,
        "memory.search",
        [
            ok(json!({ "searched": "linked", "hits": [
                { "id": "abcdefabcdef", "kind": "workspace", "workspace": "Test on lab",
                  "date": "2026-09-27 10:05", "status": "active",
                  "content": "The build needs Node 22." }] })),
            ok(json!({ "searched": "everywhere", "hits": [
                { "id": "bbbbbbbbbbbb", "kind": "workspace", "workspace": "X on lab",
                  "date": "2026-09-01 09:00", "status": "active", "content": "Postgres 17." }] })),
            ok(json!({ "searched": "everywhere", "hits": [] })),
            ok(json!({ "hits": [] })),
        ],
    );
    agent.push([
        call("d1", "delegate", json!({ "task": "Fix the build." })),
        call("q1", "memory_search", json!({ "query": "build" })),
        call("q2", "memory_search", json!({ "query": "postgres" })),
        call("q3", "memory_search", json!({ "query": "redis" })),
        call(
            "q4",
            "memory_search",
            json!({ "query": "redis", "everywhere": true }),
        ),
        text("Asked."),
    ]);
    log.turn(&mut agent, "prompt", "fix the build of this project")
        .await;
    insta::assert_json_snapshot!(
        "agent_assistant_project_links",
        feature_support::without_ptc_progress(log.into_value())
    );
}
