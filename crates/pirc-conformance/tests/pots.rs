//! Explicit pots Start over real Gateway, Node, agent RPC and fake inference.
//! The normal conformance fake-srt isolates fixtures, not a sandbox security test.
mod node_sessions_support;

use node_sessions_support::{HeldLlm, Hold, Session, Step, held_cluster, poll, read_until};
use pirc_conformance::{Api, GatewayOptions, WORKSPACE_ID, browser_headers};
use serde_json::{Value, json};

async fn call(api: &Api, method: &str, path: &str, input: Option<Value>) -> Value {
    let response = api.send(method, path, &browser_headers(), input).await;
    assert!(
        (200..300).contains(&response.status),
        "{method} {path}: {} {}",
        response.status,
        response.body
    );
    response.body
}

async fn scenario(stop: bool, take_over: bool) {
    let llm = HeldLlm::start().await;
    let models = tempfile::tempdir().unwrap();
    let Some(_cluster) = held_cluster(&llm, models.path(), GatewayOptions::default()).await else {
        return;
    };
    let api = _cluster.api();
    let created = call(
        &api,
        "POST",
        "/api/pots/responsibilities",
        Some(json!({
            "idempotencyKey":"watch", "purpose":"Watch session input blockers",
            "scopes":[{"workspaceId":WORKSPACE_ID,"access":"progress"}],
            "budgets":{"observations":4,"dispatches":1,"concurrency":1}
        })),
    )
    .await;
    let responsibility = &created["responsibility"];
    let activated = call(&api, "POST", &format!("/api/pots/responsibilities/{}/control", responsibility["id"].as_str().unwrap()), Some(json!({
        "expectedRevision":responsibility["revision"], "expectedGeneration":responsibility["generation"], "action":{"type":"activate"}
    }))).await;
    let responsibility = &activated["responsibility"];
    call(&api, "POST", &format!("/api/pots/responsibilities/{}/control", responsibility["id"].as_str().unwrap()), Some(json!({
        "expectedRevision":responsibility["revision"], "expectedGeneration":responsibility["generation"], "action":{"type":"resume_coordination"}
    }))).await;

    let (mut source, _) = Session::create(&api).await;
    assert_eq!(source.acquire().await.status, 200);
    let mut events = source.events().await;
    llm.push([Step::ptc(
        "source-question",
        "ask_user_question",
        json!({"questions":[{"question":"PRIVATE_SOURCE_QUESTION: continue?"}]}),
    )]);
    assert_eq!(source.command(json!({"type":"prompt","message":"PRIVATE_SOURCE_TRANSCRIPT: ask before proceeding"})).await.status, 202);
    let opened = read_until(&mut events, |frame| frame["type"] == "interaction_created").await;
    let interaction_id = opened.last().unwrap()["data"]["id"].clone();

    let suggestion = poll("pots suggestion", || async {
        let overview = call(&api, "GET", "/api/pots", None).await;
        overview["suggestions"].as_array()?.first().cloned()
    })
    .await;
    let tracked = call(
        &api,
        "POST",
        &format!(
            "/api/pots/suggestions/{}/track",
            suggestion["id"].as_str().unwrap()
        ),
        Some(json!({
            "expectedRevision":suggestion["revision"],"commandId":"track"
        })),
    )
    .await;
    let task = &tracked["task"];
    let task_id = task["id"].as_str().unwrap();
    let task_path = format!("/api/pots/tasks/{task_id}");
    assert!(task["executionSessionId"].is_null());
    let listed = call(&api, "GET", "/api/sessions", None).await;
    assert_eq!(
        listed["sessions"].as_array().unwrap().len(),
        1,
        "Track must not create execution"
    );
    assert_eq!(llm.requests().len(), 1, "Track must not infer");

    let hold = Hold::new();
    llm.push([Step::held(
        &hold,
        Step::text("EXPLICIT_EXECUTION_COMPLETED"),
    )]);
    let instruction =
        "EXPLICIT_POTS_INSTRUCTION: independently report completion; do not answer source";
    let start = json!({"expectedRevision":task["revision"],"expectedGeneration":task["controlGeneration"],"commandId":"start-once","instruction":instruction});
    let start_path = format!("{task_path}/start");
    let (first, again) = tokio::join!(
        call(&api, "POST", &start_path, Some(start.clone())),
        call(&api, "POST", &start_path, Some(start)),
    );
    assert_eq!(
        first["task"]["executionSessionId"],
        again["task"]["executionSessionId"]
    );
    let execution_id = first["task"]["executionSessionId"]
        .as_str()
        .expect("bound before dispatch");
    assert_ne!(execution_id, source.id);
    llm.wait_requests(2).await;
    assert_eq!(llm.requests().len(), 2, "Start retry cannot deliver twice");
    let request = llm.requests()[1].to_string();
    assert!(request.contains(instruction));
    assert!(!request.contains("PRIVATE_SOURCE_TRANSCRIPT"));
    assert!(!request.contains("PRIVATE_SOURCE_QUESTION"));
    let listed = call(&api, "GET", "/api/sessions", None).await;
    assert_eq!(listed["sessions"].as_array().unwrap().len(), 2);
    let execution_snapshot = call(
        &api,
        "GET",
        &format!("/api/sessions/{execution_id}/snapshot"),
        None,
    )
    .await;
    assert!(
        execution_snapshot.to_string().contains("pots-dispatch"),
        "trusted custom message recorded"
    );
    assert!(
        execution_snapshot.to_string().contains(task_id),
        "backend binding recorded"
    );
    assert_eq!(execution_snapshot["session"]["workspaceId"], WORKSPACE_ID);
    // The execution conversation belongs to pots until takeover or completion.
    let mut execution = Session::existing(&api, execution_id);
    assert_eq!(execution.acquire().await.status, 200);
    // Gateway command ids are unique per client across sessions.
    let refused = execution
        .command_with(
            "exec-refused",
            json!({"type":"prompt","message":"USER_FOLLOW_UP"}),
        )
        .await;
    assert_eq!(refused.status, 409, "{}", refused.body);
    assert_eq!(
        refused.body["error"]["code"], "pots_dispatch_reserved",
        "{}",
        refused.body
    );
    let mut inferences = 2;

    if stop && !take_over {
        let current = call(&api, "GET", &task_path, None).await;
        let current = &current["task"];
        call(&api, "POST", &format!("{task_path}/control"), Some(json!({
            "expectedRevision":current["revision"],"expectedGeneration":current["controlGeneration"],"action":{"type":"stop"}
        }))).await;
        poll("execution stopped", || async {
            let current = call(&api, "GET", &task_path, None).await;
            (current["task"]["status"] == "stopped").then_some(())
        })
        .await;
        let snapshot = call(
            &api,
            "GET",
            &format!("/api/sessions/{execution_id}/snapshot"),
            None,
        )
        .await;
        assert!(
            snapshot["run"].is_null()
                || matches!(
                    snapshot["run"]["status"].as_str(),
                    Some("cancelled" | "interrupted" | "failed" | "succeeded")
                ),
            "Stop cannot leave an open execution run: {snapshot}"
        );
        assert!(
            snapshot["history"]
                .as_array()
                .unwrap()
                .iter()
                .any(|row| row["role"] == "assistant" && row["stopReason"] == "aborted"),
            "Held inference was aborted rather than completed: {snapshot}"
        );
        assert!(
            matches!(
                snapshot["session"]["runnerState"].as_str(),
                Some("stopped" | "failed")
            ),
            "Stopped process is not live: {snapshot}"
        );
    } else {
        if take_over {
            let current = call(&api, "GET", &task_path, None).await;
            let current = &current["task"];
            let controlled = call(&api, "POST", &format!("{task_path}/control"), Some(json!({
                "expectedRevision":current["revision"], "expectedGeneration":current["controlGeneration"],
                "action":{"type":"take_over"}
            }))).await;
            assert_eq!(controlled["task"]["takenOver"], true);
            let snapshot = call(
                &api,
                "GET",
                &format!("/api/sessions/{execution_id}/snapshot"),
                None,
            )
            .await;
            assert_eq!(
                snapshot["session"]["runnerState"], "ready",
                "TakeOver must not abort active execution"
            );
            assert!(
                snapshot["partialMessage"].is_object(),
                "Held inference still active"
            );
            if stop {
                // The conversation is the user's now: a later pots Stop ends the
                // task without aborting anything running in it.
                let current = &controlled["task"];
                call(&api, "POST", &format!("{task_path}/control"), Some(json!({
                    "expectedRevision":current["revision"],"expectedGeneration":current["controlGeneration"],"action":{"type":"stop"}
                }))).await;
                poll("released task stopped", || async {
                    let current = call(&api, "GET", &task_path, None).await;
                    (current["task"]["status"] == "stopped").then_some(())
                })
                .await;
                let snapshot = call(
                    &api,
                    "GET",
                    &format!("/api/sessions/{execution_id}/snapshot"),
                    None,
                )
                .await;
                assert_eq!(snapshot["session"]["runnerState"], "ready");
                assert!(
                    snapshot["partialMessage"].is_object(),
                    "Stop after takeover must not abort the conversation: {snapshot}"
                );
                hold.release();
                execution
                    .snapshot_until("run finished unaborted", |s| {
                        s["run"]["status"] == "succeeded"
                            && s["history"].as_array().is_some_and(|rows| {
                                rows.iter().any(|row| {
                                    row["role"] == "assistant"
                                        && row["stopReason"] != "aborted"
                                        && row.to_string().contains("EXPLICIT_EXECUTION_COMPLETED")
                                })
                            })
                    })
                    .await;
            }
        }
        hold.release();
        if !stop {
            let completed = poll("pots execution completion", || async {
                let current = call(&api, "GET", &task_path, None).await;
                (current["task"]["status"] == "completed").then_some(current)
            })
            .await;
            assert!(
                completed["task"]["outcome"]
                    .as_str()
                    .unwrap_or_default()
                    .contains("EXPLICIT_EXECUTION_COMPLETED")
            );
        }
        // Takeover or the task's end hands the conversation to the user.
        llm.push([Step::text("USER_FOLLOW_UP_ANSWERED")]);
        let mut accepted = None;
        for attempt in 0..200 {
            let response = execution
                .command_with(
                    &format!("exec-{attempt}"),
                    json!({"type":"prompt","message":"USER_FOLLOW_UP"}),
                )
                .await;
            if response.status == 202 {
                accepted = Some(response);
                break;
            }
            assert_eq!(response.body["error"]["code"], "pots_dispatch_reserved");
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        assert!(accepted.is_some(), "conversation was never handed back");
        llm.wait_requests(3).await;
        inferences = 3;
    }
    // Neither Start nor Stop answers/aborts the evidence conversation.
    let source_snapshot = source.snapshot().await.body;
    assert_eq!(source_snapshot["session"]["runnerState"], "ready");
    assert!(
        source_snapshot["interactions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|row| row["id"] == interaction_id && row["status"] == "pending")
    );
    assert_eq!(llm.requests().len(), inferences);
    hold.release();
}

#[ignore = "pirc 2: needs a session created through first-send instead of the removed POST /api/sessions; rewritten after M4 (plans/roadmap.md M2.9)"]
#[tokio::test(flavor = "multi_thread")]
async fn pots_start_is_one_shot_and_records_completion_without_source_transcript() {
    scenario(false, false).await;
}

#[ignore = "pirc 2: needs a session created through first-send instead of the removed POST /api/sessions; rewritten after M4 (plans/roadmap.md M2.9)"]
#[tokio::test(flavor = "multi_thread")]
async fn pots_stop_aborts_only_the_dedicated_execution() {
    scenario(true, false).await;
}

#[ignore = "pirc 2: needs a session created through first-send instead of the removed POST /api/sessions; rewritten after M4 (plans/roadmap.md M2.9)"]
#[tokio::test(flavor = "multi_thread")]
async fn pots_takeover_leaves_running_execution_alive_until_completion() {
    scenario(false, true).await;
}

#[ignore = "pirc 2: needs a session created through first-send instead of the removed POST /api/sessions; rewritten after M4 (plans/roadmap.md M2.9)"]
#[tokio::test(flavor = "multi_thread")]
async fn pots_stop_after_takeover_leaves_the_users_conversation_running() {
    scenario(true, true).await;
}
