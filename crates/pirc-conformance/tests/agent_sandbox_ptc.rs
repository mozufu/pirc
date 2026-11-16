//! The sandbox tools run from `ptc` scripts (docs/architecture/ptc.md):
//! `sandbox_allow_domains` granted, partly granted, refused and for an
//! unrestricted agent; `unsandboxed_bash` run, failing, timed out, refused
//! by the human and refused a write lease. The node's answers come from
//! the test (`sandbox_request` / `sandbox_response`). Needs the `ptc`
//! runtime.

mod feature_support;

use feature_support::{Masker, ptc, turn};
use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

fn ok(result: Value) -> Value {
    json!({ "ok": true, "result": result })
}

/// Every call's outcome, as JSON.
fn script(calls: &[(&str, Value)]) -> String {
    let mut code = String::from("const out = [];\n");
    for (name, args) in calls {
        code.push_str(&format!(
            "out.push(await tools.call({}, {args}));\n",
            json!(name)
        ));
    }
    code.push_str("return JSON.stringify(out);");
    code
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_sandbox_tools() {
    let mut options = AgentOptions::default().features("sandbox");
    options
        .env
        .push(("PIRC_SANDBOX".to_owned(), "srt".to_owned()));
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut m = Masker::new();
    agent.answers.lock().unwrap().sandbox.extend([
        ok(json!({ "granted": ["api.example.com"] })),
        ok(json!({ "granted": ["a.example"], "denied": ["b.example"] })),
        ok(json!({ "unrestricted": true })),
        json!({ "ok": false, "error": { "code": "invalid_input", "message": "Bad domain" } }),
        ok(json!({ "granted": [] })),
        ok(json!({ "output": "built\n", "exitCode": 0 })),
        ok(json!({ "output": "fail", "exitCode": 2, "truncated": true })),
        ok(json!({ "output": "", "timedOut": true })),
        ok(json!({ "output": "partial\n", "aborted": true })),
        json!({ "ok": false, "error": { "code": "unavailable", "message": "No sandbox" } }),
        json!({ "ok": false, "error": { "code": "denied", "message": "The user said no" } }),
    ]);
    agent.push([
        ptc(
            "n1",
            &script(&[
                (
                    "sandbox_allow_domains",
                    json!({ "domains": ["api.example.com"], "reason": "docs" }),
                ),
                (
                    "sandbox_allow_domains",
                    json!({ "domains": ["a.example", "b.example"], "reason": "both" }),
                ),
                (
                    "sandbox_allow_domains",
                    json!({ "domains": ["d.example"], "reason": "free" }),
                ),
                (
                    "sandbox_allow_domains",
                    json!({ "domains": ["bad domain"], "reason": "error" }),
                ),
            ]),
        ),
        // A refusal stops the rest of its script, so it comes alone.
        ptc(
            "n2",
            &script(&[(
                "sandbox_allow_domains",
                json!({ "domains": ["c.example"], "reason": "refused" }),
            )]),
        ),
        ptc(
            "x1",
            &script(&[
                (
                    "unsandboxed_bash",
                    json!({ "command": "nix build", "reason": "daemon", "cwd": "sub",
                        "timeout": 30 }),
                ),
                (
                    "unsandboxed_bash",
                    json!({ "command": "false", "reason": "fails" }),
                ),
                (
                    "unsandboxed_bash",
                    json!({ "command": "sleep 99", "reason": "slow" }),
                ),
                (
                    "unsandboxed_bash",
                    json!({ "command": "yes", "reason": "aborted" }),
                ),
                (
                    "unsandboxed_bash",
                    json!({ "command": "true", "reason": "no channel" }),
                ),
                (
                    "unsandboxed_bash",
                    json!({ "command": "rm -rf /", "reason": "refused" }),
                ),
            ]),
        ),
        ModelReply::Text("Done.".to_owned()),
    ]);
    turn(&mut agent, &mut m, &mut r, "sandbox tools", "Reach out").await;
    // Without the write lease, nothing is asked of the human.
    let workspace = agent.workspace.display().to_string();
    agent.answers.lock().unwrap().refuse_leases = vec![workspace];
    agent.push([
        ptc(
            "x2",
            &script(&[(
                "unsandboxed_bash",
                json!({ "command": "touch x", "reason": "lease" }),
            )]),
        ),
        ModelReply::Text("Refused.".to_owned()),
    ]);
    turn(&mut agent, &mut m, &mut r, "lease refused", "Write outside").await;
    insta::assert_json_snapshot!(
        "agent_sandbox_tools",
        feature_support::without_ptc_progress(r.into_value())
    );
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_sandbox_tools_absent() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default().features("sandbox")).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut m = Masker::new();
    agent.push([
        ptc(
            "n1",
            &script(&[(
                "sandbox_allow_domains",
                json!({ "domains": ["a.example"], "reason": "r" }),
            )]),
        ),
        ModelReply::Text("Hi.".to_owned()),
    ]);
    turn(&mut agent, &mut m, &mut r, "try it", "Try it").await;
    insta::assert_json_snapshot!(
        "agent_sandbox_tools_absent",
        feature_support::without_ptc_progress(r.into_value())
    );
}
