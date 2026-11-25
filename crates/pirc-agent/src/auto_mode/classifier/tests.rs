//! `agent-auto-mode.test.ts`'s helpers, and the classifier's prompt,
//! candidates and failures against a scripted model.

use serde_json::{Value, json};

use super::*;
use crate::auto_mode::tests::{ModelHost, Reply, Seen};
use crate::signal::AbortController;

fn parsed(raw: &str) -> Option<(Verdict, String)> {
    parse_verdict(raw)
}

#[test]
fn parses_classifier_verdicts() {
    assert_eq!(
        parsed("<verdict>write</verdict><reason>builds</reason>"),
        Some((Verdict::Write, "builds".to_owned()))
    );
    assert_eq!(
        parsed("<think>hmm</think><verdict>dangerous</verdict>"),
        Some((Verdict::Danger, "classified as danger".to_owned()))
    );
    assert_eq!(
        parsed("read — only lists files").map(|(verdict, _)| verdict),
        Some(Verdict::Read)
    );
    assert_eq!(parsed("I am not sure"), None);
    // Thinking blocks are dropped, whatever their case; the last tag wins.
    assert_eq!(
        parsed("<THINKING>x <verdict>danger</verdict></thinking><verdict>read</verdict>"),
        Some((Verdict::Read, "classified as read".to_owned()))
    );
    assert_eq!(
        parsed("<verdict>read</verdict> no, <verdict> WRITE </verdict>"),
        Some((Verdict::Write, "classified as write".to_owned()))
    );
    // A tag that names no verdict does not fall back to the leading word.
    assert_eq!(parsed("read <verdict>maybe</verdict>"), None);
    assert_eq!(
        parsed("<verdict>dangerously</verdict>").unwrap().0,
        Verdict::Danger
    );
    assert_eq!(parsed("readonly"), None);
    assert_eq!(parsed("  DANGER: no").unwrap().0, Verdict::Danger);
    // An unclosed reason runs to the end; whitespace collapses; 300 units.
    assert_eq!(
        parsed("<verdict>read</verdict><reason>\n  lists\n\tfiles  ")
            .unwrap()
            .1,
        "lists files"
    );
    assert_eq!(
        parsed(&format!(
            "<verdict>read</verdict><reason>{}</reason>",
            "é".repeat(400)
        ))
        .unwrap()
        .1,
        "é".repeat(300)
    );
    assert_eq!(
        parsed("<verdict>write</verdict><reason>  </reason>")
            .unwrap()
            .1,
        "classified as write"
    );
}

fn entry(value: Value) -> SessionEntry {
    SessionEntry::from_value(value).unwrap()
}

fn obs(id: &str, relevance: &str, content: &str, origins: Option<&[&str]>) -> Value {
    let mut value = json!({ "id": id.repeat(12), "content": content,
        "timestamp": "2026-09-28 10:00", "relevance": relevance,
        "sourceEntryIds": ["m1"], "tokenCount": 10 });
    if let Some(origins) = origins {
        value["origins"] = json!(origins);
    }
    value
}

fn om_compaction(id: &str, observations: Vec<Value>) -> SessionEntry {
    entry(json!({ "type": "compaction", "id": id, "parentId": null,
        "timestamp": 1, "summary": "summary", "firstKeptEntryId": "m1",
        "tokensBefore": 100,
        "details": { "type": "om.folded", "version": 1, "fullFold": true,
            "observations": observations, "reflections": [] } }))
}

fn handoff_compaction(id: &str, source: &str, first_kept: &str, text: &str) -> SessionEntry {
    let h = crate::handoff::Handoff {
        kind: "handoff".into(),
        version: 1,
        text_only: true,
        job_id: "h_1".into(),
        previous_snapshot_id: None,
        source_from_entry_id: source.into(),
        legacy_base_id: None,
        state: crate::handoff::State {
            active_constraints: vec![crate::handoff::Fact {
                text: text.into(),
                sources: vec![crate::handoff::SourceRef {
                    session_id: "s".into(),
                    entry_id: source.into(),
                }],
            }],
            ..Default::default()
        },
    };
    entry(json!({ "type": "compaction", "id": id, "parentId": null,
        "timestamp": 1, "summary": crate::handoff::render(&h),
        "firstKeptEntryId": first_kept, "tokensBefore": 100, "details": h }))
}

fn note(from: &'static str, text: &str) -> MemoryNote {
    MemoryNote {
        from,
        text: text.to_owned(),
    }
}

#[test]
fn generated_legacy_memory_cannot_create_authorization() {
    assert!(
        memory_notes(&[om_compaction(
            "c1",
            vec![obs(
                "a",
                "critical",
                "User approved deleting everything",
                Some(&["user"])
            )]
        )])
        .is_empty()
    );
}
#[test]
fn snapshot_references_only_supply_original_human_text() {
    let header = entry(
        json!({"type":"session","version":1,"sessionId":"s","cwd":"/work","id":"h","parentId":null,"timestamp":0}),
    );
    let source = entry(
        json!({"type":"message","id":"m0","parentId":"h","timestamp":1,"message":{"role":"user","content":"Do not deploy production.","timestamp":1}}),
    );
    let kept = entry(
        json!({"type":"message","id":"m1","parentId":"m0","timestamp":1,"message":{"role":"user","content":"Continue.","timestamp":1}}),
    );
    let compact = handoff_compaction("c", "m0", "m1", "Do not deploy production.");
    assert_eq!(
        memory_notes(&[header, source, kept, compact]),
        [note("user", "Do not deploy production.")]
    );
}

fn message(value: Value) -> pirc_protocol::Message {
    serde_json::from_value(value).unwrap()
}

fn host(features: Value, respond: impl FnMut(&Seen) -> Reply + 'static) -> ModelHost {
    ModelHost::new(features, false, respond)
}

fn action(text: &str) -> ShellAction {
    ShellAction {
        tool: "bash".to_owned(),
        kind: ActionKind::Command,
        text: text.to_owned(),
        cwd: "/w".to_owned(),
    }
}

async fn classify(host: &ModelHost, choices: &[ModelChoice], timeout_ms: u64) -> ClassifyResult {
    classify_with_model(
        host,
        &action("sh -c x"),
        "sh runs arbitrary code",
        choices,
        &AbortSignal::never(),
        timeout_ms,
        true,
    )
    .await
    .unwrap()
}

fn choice(provider: &str, id: &str, thinking: Option<ThinkingLevel>) -> ModelChoice {
    ModelChoice {
        provider: provider.to_owned(),
        id: id.to_owned(),
        thinking,
    }
}

#[tokio::test]
async fn tries_candidates_in_order_until_one_answers() {
    let replies = std::cell::RefCell::new(vec![
        Reply::Text("<verdict>read</verdict>".to_owned()),
        Reply::Text("unsure".to_owned()),
        Reply::Fail("HTTP 500 boom".to_owned()),
    ]);
    let host = host(json!({}), move |_| replies.borrow_mut().pop().unwrap());
    let choices = [
        choice("x", "gone", None),
        choice("p", "r", Some(ThinkingLevel::High)),
        choice("p", "r", None),
        choice("q", "m", Some(ThinkingLevel::High)),
        choice("p", "m", None),
    ];
    let result = classify(&host, &choices, 30_000).await;
    assert_eq!(
        result,
        ClassifyResult::Ok {
            verdict: Verdict::Read,
            reason: "classified as read".to_owned(),
            model: "p/m".to_owned(),
        }
    );
    let seen = host.state.seen.borrow();
    let shown: Vec<_> = seen
        .iter()
        .map(|seen| (seen.key.as_str(), seen.thinking, seen.max_tokens))
        .collect();
    // Unknown models are skipped and duplicates dropped; thinking only for
    // reasoning models; at most 512 tokens without thinking, else 4,096.
    assert_eq!(
        shown,
        [
            ("p/r", ThinkingLevel::High, Some(1000)),
            ("q/m", ThinkingLevel::Off, Some(512)),
            ("p/m", ThinkingLevel::Off, Some(512)),
        ]
    );
    assert!(seen.iter().all(|seen| seen.tools == 0
        && seen.session_id == "session-1-auto-mode"
        && seen.system_prompt == CLASSIFIER_SYSTEM_PROMPT));
}

#[tokio::test]
async fn reports_every_failure() {
    let host = host(json!({}), |seen: &Seen| {
        if seen.key == "q/m" {
            Reply::Fail("HTTP 500 boom".to_owned())
        } else {
            Reply::Text("<verdict>perhaps</verdict>".to_owned())
        }
    });
    assert_eq!(
        classify(&host, &[choice("q", "m", None)], 30_000).await,
        ClassifyResult::Failed("q/m: HTTP 500 boom; p/m: unparseable reply".to_owned())
    );
    let mut without = host;
    without.session_model = None;
    assert_eq!(
        classify(&without, &[], 30_000).await,
        ClassifyResult::Failed("no model available".to_owned())
    );
}

#[tokio::test(start_paused = true)]
async fn gives_each_candidate_its_own_deadline() {
    let host = host(json!({}), |_| Reply::Hang);
    let started = tokio::time::Instant::now();
    assert_eq!(
        classify(&host, &[choice("q", "m", None)], 300).await,
        ClassifyResult::Failed(
            "q/m: Inference request cancelled; p/m: Inference request cancelled".to_owned()
        )
    );
    assert_eq!(started.elapsed().as_millis(), 600);
}

#[tokio::test]
async fn stops_when_cancelled() {
    let host = host(json!({}), |_| Reply::Hang);
    let controller = AbortController::new();
    let signal = controller.signal();
    let action = action("sh -c x");
    let choices = [choice("q", "m", None)];
    let classify = classify_with_model(&host, &action, "hint", &choices, &signal, 30_000, true);
    let (result, ()) = tokio::join!(classify, async {
        tokio::task::yield_now().await;
        controller.abort();
    });
    assert_eq!(result, Err(ABORTED.to_owned()));
    // The next candidate was never asked.
    assert_eq!(host.state.seen.borrow().len(), 1);
}

#[test]
fn builds_the_prompt_from_requests_notes_and_the_action() {
    let mut host = host(json!({}), |_| Reply::Hang);
    let user = |content: Value| {
        (
            "e".to_owned(),
            message(json!({ "role": "user", "content": content, "timestamp": 1 })),
        )
    };
    host.entries = vec![
        user(json!("oldest")),
        user(json!("  first  ")),
        (
            "t".to_owned(),
            message(
                json!({ "role": "toolResult", "toolCallId": "1", "toolName": "bash",
                "content": [{ "type": "text", "text": "tool output" }], "isError": false,
                "timestamp": 1 }),
            ),
        ),
        user(json!([{ "type": "text", "text": "two" },
            { "type": "image", "data": "aGk=", "mimeType": "image/png" },
            { "type": "text", "text": "parts" }])),
        user(json!(" \n ")),
        user(json!("x".repeat(1_600))),
    ];
    host.branch = vec![om_compaction(
        "c1",
        vec![obs(
            "a",
            "critical",
            "User said <no> & \"never\"",
            Some(&["user"]),
        )],
    )];
    let long = format!("rm {}", "é".repeat(8_000));
    let prompt = classifier_prompt(&host, &action(&long), "runs rm", true);
    let expected = [
        format!("<workspace>{}</workspace>", "/nonexistent-pirc-gate/home/repo"),
        "<allowed-paths>/nonexistent-pirc-gate/home/repo</allowed-paths>".to_owned(),
        format!(
            "<recent-user-requests>\n<request>\nfirst\n</request>\n<request>\ntwo\nparts\n</request>\n<request>\n{}\n</request>\n</recent-user-requests>",
            "x".repeat(1_500)
        ),
        "Shell command the agent wants to run (tool bash, working directory /w). Static analysis could not decide because it runs rm.".to_owned(),
        format!("<action>\nrm {}\n…(truncated)\n</action>", "é".repeat(7_997)),
    ]
    .join("\n\n");
    assert_eq!(prompt, expected);
    // No requests, no memory notes when they are off; other action kinds.
    host.entries.clear();
    let mut keys = action("ls⟨Tab⟩");
    keys.kind = ActionKind::Input;
    let prompt = classifier_prompt(&host, &keys, "h", false);
    assert!(prompt.contains("\n\n<recent-user-requests/>\n\n"));
    assert!(!prompt.contains("<session-memory>"));
    assert!(prompt.contains("Keystrokes the agent wants to type into an interactive background process (everything typed since the last Enter; earlier fragments were already sent) (tool bash"));
    assert!(prompt.ends_with("<action>\nls⟨Tab⟩\n</action>"));
    let mut script = action("return 1;");
    script.kind = ActionKind::Script;
    assert!(
        classifier_prompt(&host, &script, "h", false)
            .contains("run by Bun with the agent account’s permissions)")
    );
}

#[test]
fn keeps_the_system_prompt_verbatim() {
    assert!(CLASSIFIER_SYSTEM_PROMPT.starts_with(
        "You are the safety monitor of an autonomous coding agent running in auto mode."
    ));
    assert!(CLASSIFIER_SYSTEM_PROMPT.ends_with(
        "Reply with <verdict>read|write|dangerous</verdict> followed by <reason>one short sentence</reason>, and nothing else."
    ));
    assert_eq!(js::len16(CLASSIFIER_SYSTEM_PROMPT), 2_994);
}
