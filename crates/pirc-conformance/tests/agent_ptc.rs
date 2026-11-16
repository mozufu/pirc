//! `ptc` scripts run by a real agent process, the test playing its node
//! (features off): the two-tool surface, operations through the policy
//! chain with their events and session entries, preflight refusals, the
//! script store, attachments, hooks and refusals inside scripts, timeouts
//! and cancellation (`apps/gateway/test/agent-ptc.test.ts`). The historical
//! PTC baseline (docs/development/historical-records.md). Scenarios that need
//! features (todo, browser, sandbox, background) are in `agent_ptc_features.rs`.

use std::sync::LazyLock;

use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder, fake_models};
use regex::Regex;
use serde_json::{Value, json};

fn tools(calls: &[(&str, &str, Value)]) -> ModelReply {
    ModelReply::Tools(
        calls
            .iter()
            .map(|(id, name, args)| ((*id).to_owned(), (*name).to_owned(), args.clone()))
            .collect(),
    )
}

fn file(path: &str, content: impl Into<String>) -> (String, String) {
    (path.to_owned(), content.into())
}

static STACK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(\n +at [^\n]*)+\n?").unwrap());
static NONCE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"id=[0-9a-f]{12}>>>").unwrap());
/// The parser's own words after "Syntax error:" (Bun's transpiler in TS).
static SYNTAX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"Syntax error: [^"\\]*"#).unwrap());

/// What varies between runs and engines: active and waited times, the
/// untrusted fence's nonce, stack lines of script errors (QuickJS builds
/// print them differently) and the parser's syntax error texts.
fn mask(value: &mut Value) {
    match value {
        Value::Object(object) => {
            for (key, item) in object.iter_mut() {
                if matches!(key.as_str(), "activeMs" | "waitedMs" | "durationMs")
                    && item.is_number()
                {
                    *item = json!("<ms>");
                } else {
                    mask(item);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(mask),
        Value::String(text) => {
            let masked = STACK.replace_all(text, "\n    at <stack>");
            let masked = NONCE.replace_all(&masked, "id=<nonce>>>>");
            let masked = SYNTAX.replace_all(&masked, "Syntax error: <message>");
            if masked != *text {
                *text = masked.into_owned();
            }
        }
        _ => {}
    }
}

/// The agent's events without progress updates, whose number depends on
/// timing (they are throttled to one per 100 ms).
fn stable(events: Vec<Value>) -> Vec<Value> {
    events
        .into_iter()
        .filter(|event| event["type"] != "tool_execution_update" && event["type"] != "response")
        .map(|mut event| {
            mask(&mut event);
            event
        })
        .collect()
}

/// A prompt and everything the agent does until it settles.
async fn turn(agent: &mut AgentRun, r: &mut Recorder, step: &str, message: &str) {
    let response = agent
        .call(json!({ "type": "prompt", "message": message }))
        .await;
    r.note(&format!("{step}: response"), response);
    let events = stable(agent.settle().await);
    record(r, step, agent, events);
}

fn record(r: &mut Recorder, step: &str, agent: &AgentRun, events: Vec<Value>) {
    r.note(&format!("{step}: events"), json!(events));
    let mut requests = agent.take_requests();
    requests.iter_mut().for_each(mask);
    r.requests(&format!("{step}: model requests"), requests);
}

/// One model turn running these scripts, then a final text.
async fn scripts(agent: &mut AgentRun, r: &mut Recorder, step: &str, codes: &[(&str, Value)]) {
    let calls: Vec<(&str, &str, Value)> = codes
        .iter()
        .map(|(id, args)| (*id, "ptc", args.clone()))
        .collect();
    agent.push([tools(&calls), ModelReply::Text("ok".to_owned())]);
    turn(agent, r, step, &format!("run {step}")).await;
}

fn code(code: &str) -> Value {
    json!({ "code": code })
}

fn session(r: &mut Recorder, agent: &AgentRun) {
    let mut entries = json!(agent.session_entries());
    mask(&mut entries);
    r.note("session file", entries);
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ptc_surface() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    scripts(
        &mut agent,
        &mut r,
        "a first script",
        &[("s1", code("return 1;"))],
    )
    .await;
    agent.push([
        tools(&[
            ("d1", "read", json!({ "path": "README.md" })),
            ("d2", "background_task", json!({ "action": "list" })),
            ("d3", "code", json!({ "code": "return 1" })),
            ("d4", "ptc", json!({ "code": "return 1", "extra": true })),
            ("d5", "ptc", json!({ "code": "" })),
            ("d6", "ptc", json!({ "code": "return 1", "timeout": 0 })),
            ("d7", "ptc", json!({})),
        ]),
        ModelReply::Text("ok".to_owned()),
    ]);
    turn(&mut agent, &mut r, "direct and invalid calls", "go").await;
    session(&mut r, &agent);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_ptc_surface", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ptc_tool_lists() {
    for (name, args) in [
        ("restricted", vec!["--tools", "read,code,ptc,bogus"]),
        ("none", vec!["--tools", "code"]),
    ] {
        let Some(mut agent) = AgentRun::start(AgentOptions {
            args: args.into_iter().map(str::to_owned).collect(),
            files: vec![file("a.txt", "x")],
            ..AgentOptions::default()
        })
        .await
        else {
            return;
        };
        let mut r = Recorder::new(&agent);
        scripts(
            &mut agent,
            &mut r,
            "scripts",
            &[
                (
                    "t1",
                    code("return (await tools.read({ path: 'a.txt' })).text;"),
                ),
                (
                    "t2",
                    code("return await tools.bash({ command: 'touch x' });"),
                ),
            ],
        )
        .await;
        agent.push([
            tools(&[("t3", "bash", json!({ "command": "touch x" }))]),
            ModelReply::Text("ok".to_owned()),
        ]);
        turn(&mut agent, &mut r, "a direct bash", "go").await;
        r.note("x exists", json!(agent.workspace.join("x").exists()));
        r.note("exit code", json!(agent.finish().await));
        insta::assert_json_snapshot!(format!("agent_ptc_tool_lists_{name}"), r.into_value());
    }
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ptc_operations() {
    let Some(mut agent) = AgentRun::start(AgentOptions {
        files: vec![
            file("a.txt", "aaa"),
            file("b.txt", "bbb"),
            file("c.txt", "ccc"),
            file("lines.md", "one\ntwo\nthree"),
        ],
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    scripts(
        &mut agent,
        &mut r,
        "a batch",
        &[(
            "o1",
            code(
                "const { paths } = await tools.find({ pattern: '*.txt' });
       const sizes: Record<string, number> = {};
       for (const f of paths) sizes[f] = (await tools.read({ path: f })).content.length;
       const edited = await tools.edit({ path: 'a.txt', oldText: 'aaa', newText: 'AAA' });
       console.log('checked', paths.length, edited.replacements);
       return sizes;",
            ),
        )],
    )
    .await;
    scripts(
        &mut agent,
        &mut r,
        "typed results",
        &[(
            "o2",
            code(
                "const read = await tools.read({ path: 'lines.md', offset: 2, limit: 1 });
       const grep = await tools.grep({ pattern: 'o', glob: '*.md' });
       const ls = await tools.ls({});
       const ok = await tools.bash({ command: 'printf hi' });
       const exited = await tools.bash({ command: 'printf oops; exit 3' });
       const failed = await tools.edit({ path: 'lines.md', oldText: 'absent', newText: 'x' }).catch((e) => e);
       return {
         read: [read.content, read.offset, read.lines, read.totalLines, read.nextOffset],
         grep: grep.matches.map((m) => m.path + ':' + m.line),
         ls: ls.entries,
         ok: [ok.output, ok.exitCode],
         exited: [exited.exitCode, exited.output],
         failed: [failed.code, failed.outcome, failed.message],
       };",
            ),
        )],
    )
    .await;
    let outside = agent.dir.path().join("home").join("outside.txt");
    scripts(
        &mut agent,
        &mut r,
        "workspace limits and typed errors",
        &[(
            "o3",
            code(&format!(
                "const out = [];
       for (const [p, c] of [[{}, 'y'], ['.pirc/config.json', '{{}}']]) {{
         const r = await tools.call('write', {{ path: p, content: c }});
         out.push(r.ok ? 'written' : r.error.code + ' ' + r.error.outcome + ' ' + r.error.message);
       }}
       try {{ await tools.read({{}}); }} catch (e) {{ out.push(e.code + ' ' + e.message); }}
       try {{ await tools.read({{ path: 7 }}); }} catch (e) {{ out.push(e.code + ' ' + e.message); }}
       try {{ await tools.bash({{ command: 'echo hi', description: 'x' }}); }} catch (e) {{ out.push(e.code + ' ' + e.message); }}
       return out;",
                json!(outside.display().to_string())
            )),
        )],
    )
    .await;
    r.note("outside written", json!(outside.exists()));
    r.note(
        "protected config written",
        json!(agent.workspace.join(".pirc/config.json").exists()),
    );
    agent.push([
        tools(&[
            (
                "o4",
                "read",
                json!({ "path": "lines.md", "offset": null, "limit": null }),
            ),
            (
                "o5",
                "bash",
                json!({ "command": "echo hi", "description": "Say hi" }),
            ),
        ]),
        ModelReply::Text("ok".to_owned()),
    ]);
    turn(&mut agent, &mut r, "lenient direct calls", "go").await;
    session(&mut r, &agent);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_ptc_operations", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ptc_preflight() {
    let Some(mut agent) = AgentRun::start(AgentOptions {
        config: json!({ "limits": { "toolOutputBytes": 2000 } }),
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let write = "await tools.bash({ command: 'touch side-effect.txt' }); ";
    let cases = [
        format!("{write}await tools.web_search({{ query: 'q' }});"),
        format!("{write}await tools.ptc({{ code: 'return 1' }});"),
        format!("{write}await tools.call('code', {{}});"),
        format!("{write}const n = 'bash'; await tools.call(n, {{}});"),
        format!("{write}await (tools as any)['ba' + 'sh']({{}});"),
        format!("{write}const t = tools; return t.read({{}});"),
        format!("{write}return [tools].length;"),
        "return (;".to_owned(),
        "}); globalThis.x = 1; (async () => {".to_owned(),
        "   ".to_owned(),
    ];
    let calls: Vec<(String, Value)> = cases
        .iter()
        .enumerate()
        .map(|(index, source)| (format!("r{index}"), code(source)))
        .collect();
    let calls: Vec<(&str, Value)> = calls
        .iter()
        .map(|(id, args)| (id.as_str(), args.clone()))
        .collect();
    scripts(&mut agent, &mut r, "refused before running", &calls).await;
    r.note(
        "side effect",
        json!(agent.workspace.join("side-effect.txt").exists()),
    );
    scripts(
        &mut agent,
        &mut r,
        "no ambient authority",
        &[(
            "h1",
            code(
                "const k = 'constr' + 'uctor';
       const probes = [typeof (globalThis as any).process, typeof (globalThis as any).Bun,
         typeof (globalThis as any).require, (() => 0)[k]('return typeof process')(),
         Object[k]('return typeof Bun')(), typeof setTimeout, typeof WebAssembly,
         typeof (globalThis as any).__ptc, Function('return typeof globalThis.__ptc')()];
       let imported = 'refused';
       try { await import('node:fs'); imported = 'loaded'; } catch {}
       return probes.concat(imported);",
            ),
        )],
    )
    .await;
    scripts(
        &mut agent,
        &mut r,
        "timeout and output cap",
        &[
            ("l1", json!({ "code": "for (;;) {}", "timeout": 0.5 })),
            (
                "l2",
                code("for (let i = 0; i < 5000; i++) console.log('line ' + i); return 'end';"),
            ),
            (
                "l3",
                code("console.log('a'); console.warn({ ok: true }); console.error('e', 1); return 'a\\nb';"),
            ),
            ("l4", code("let x = 1;")),
            ("l5", code("throw 42;")),
            ("l6", code("throw new TypeError('boom');")),
            ("l7", code("return { n: [1, 2], s: 'x', u: undefined };")),
        ],
    )
    .await;
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_ptc_preflight", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ptc_store() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    scripts(
        &mut agent,
        &mut r,
        "store",
        &[
            (
                "k1",
                code("store('cursor', { page: 2 }); store('gone', 1); store('gone', undefined); return 'ok';"),
            ),
            (
                "k2",
                code("store('cursor', { page: 99 }); throw new Error('no');"),
            ),
            (
                "k3",
                code("return [load('cursor'), load('gone'), load('missing')];"),
            ),
            (
                "k4",
                code("try { store('big', 'x'.repeat(300000)); } catch (e) { return e.code + ': ' + e.message; }"),
            ),
            (
                "k5",
                code("try { store('', 1); } catch (e) { return e.code + ': ' + e.message; }"),
            ),
            ("k6", code("store('__proto__', { a: 1 }); return 'ok';")),
            ("k7", code("return load('__proto__');")),
            ("k8", code("store('cursor', { page: 3 }); return 'unchanged';")),
            ("k9", code("return 'no load';")),
        ],
    )
    .await;
    session(&mut r, &agent);
    let file = std::fs::read_to_string(agent.session_dir.join("session.jsonl")).unwrap();
    r.note("exit code", json!(agent.finish().await));
    // A resumed session sees the last kept store.
    let Some(mut resumed) = AgentRun::start(AgentOptions {
        files: vec![
            ("README.md".to_owned(), "conformance\n".to_owned()),
            ("../session/session.jsonl".to_owned(), file),
        ],
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut again = Recorder::new(&resumed);
    scripts(
        &mut resumed,
        &mut again,
        "resumed",
        &[("k10", code("return load('cursor');"))],
    )
    .await;
    r.note("resumed", again.into_value());
    r.note("resumed exit code", json!(resumed.finish().await));
    insta::assert_json_snapshot!("agent_ptc_store", r.into_value());
}

/// A 1×1 PNG.
const PIXEL: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg==";

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ptc_attachments() {
    use base64::Engine;
    let mut models = fake_models();
    models["providers"]["fake"]["models"][1]["contextWindow"] = json!(100_000);
    let Some(mut agent) = AgentRun::start(AgentOptions {
        models: Some(models),
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let pixel = base64::engine::general_purpose::STANDARD
        .decode(PIXEL)
        .unwrap();
    std::fs::write(agent.workspace.join("pixel.png"), pixel).unwrap();
    let mut r = Recorder::new(&agent);
    let script = "const image = await tools.read({ path: 'pixel.png' });
       const seen = { kind: image.kind, mimeType: image.images[0].mimeType, bytes: image.images[0].bytes };
       const handle = image.images[0].handle;
       const forged = await attachments.add('att_' + '0'.repeat(64)).catch((e) => e.code);
       const bad = await attachments.add('../etc/passwd').catch((e) => e.code + ': ' + e.message);
       const queued = await attachments.add(image.images[0]).then((r) => r.queued, (e) => e.code + ': ' + e.message);
       const twice = await attachments.add(handle).then((r) => r.queued, (e) => e.code);
       return { seen, handle: /^att_[0-9a-f]{64}$/.test(handle), forged, bad, queued, twice };";
    scripts(
        &mut agent,
        &mut r,
        "a text-only model",
        &[("i1", code(script))],
    )
    .await;
    let response = agent
        .call(json!({ "type": "set_model", "provider": "fake", "modelId": "small-model" }))
        .await;
    r.note("switch to a vision model", response);
    scripts(
        &mut agent,
        &mut r,
        "a vision model",
        &[
            ("i2", code(script)),
            (
                "i3",
                code("const image = await tools.read({ path: 'pixel.png' }); await attachments.add(image.images[0]); throw new Error('after queueing');"),
            ),
        ],
    )
    .await;
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_ptc_attachments", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ptc_hooks() {
    let Some(mut agent) = AgentRun::start(AgentOptions {
        config: json!({ "hooks": { "beforeTool": [
            { "matcher": "bash", "command": "echo \"bash denied\" >&2; exit 2" },
            { "matcher": "code", "command": "echo \"scripts off\" >&2; exit 2" },
        ] } }),
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut all = Vec::new();
    let mut r = Recorder::new(&agent);
    scripts(
        &mut agent,
        &mut r,
        "a code matcher",
        &[("c1", code("return 1;"))],
    )
    .await;
    r.note("exit code", json!(agent.finish().await));
    all.push(r.into_value());

    let Some(mut agent) = AgentRun::start(AgentOptions {
        config: json!({ "hooks": {
            "beforeTool": [
                { "matcher": "bash", "command": "echo \"bash denied\" >&2; exit 2" },
                { "matcher": "edit", "command": "echo '{\"args\":{\"path\":42}}'" },
            ],
            "afterTool": [{ "matcher": "read", "command": "echo \"lint: careful\"" }],
        } }),
        files: vec![file("a.txt", "x")],
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    scripts(
        &mut agent,
        &mut r,
        "refusals in scripts",
        &[
            (
                "c2",
                code("try { await tools.bash({ command: 'echo hi' }); } catch (e) { return [e.code, e.outcome, e.message]; }"),
            ),
            (
                "c3",
                code("const out = [];
       try { await tools.bash({ command: 'echo hi' }); } catch (e) { out.push(e.code); }
       try { await tools.write({ path: 'b.txt', content: 'y' }); } catch (e) { out.push(e.code, e.message); }
       out.push((await tools.read({ path: 'a.txt' })).text);
       return out;"),
            ),
            (
                "c4",
                code("await tools.read({ path: 'a.txt' }); return 'done';"),
            ),
            (
                "c5",
                code("try { await tools.edit({ path: 'a.txt', oldText: 'x', newText: 'y' }); } catch (e) { return e.code + ': ' + e.message; }"),
            ),
            ("c6", code("await tools.bash({ command: 'echo hi' });")),
        ],
    )
    .await;
    r.note(
        "b.txt exists",
        json!(agent.workspace.join("b.txt").exists()),
    );
    r.note("exit code", json!(agent.finish().await));
    all.push(r.into_value());

    let Some(mut agent) = AgentRun::start(AgentOptions {
        config: json!({ "hooks": { "beforeTool": [
            { "matcher": "bash", "command": "sleep 0.3; echo \"bash denied\" >&2; exit 2" },
            { "matcher": "write", "command": "sleep 0.6" },
        ] } }),
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    scripts(
        &mut agent,
        &mut r,
        "held back while waiting",
        &[(
            "c7",
            code("const results = await Promise.allSettled([
         tools.bash({ command: 'echo hi' }),
         tools.write({ path: 'late.txt', content: 'y' }),
       ]);
       return results.map((r) => r.status === 'rejected' ? r.reason.code + ': ' + r.reason.message : 'ok');"),
        )],
    )
    .await;
    r.note(
        "late.txt exists",
        json!(agent.workspace.join("late.txt").exists()),
    );
    r.note("exit code", json!(agent.finish().await));
    all.push(r.into_value());
    insta::assert_json_snapshot!("agent_ptc_hooks", json!(all));
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ptc_abort() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        tools(&[(
            "abort-me",
            "ptc",
            code(
                "await tools.write({ path: 'first.txt', content: '1' });
                   await tools.bash({ command: 'sleep 30' });
                   await tools.write({ path: 'never.txt', content: '2' });",
            ),
        )]),
        ModelReply::Text("unused".to_owned()),
    ]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "go" }))
        .await;
    r.note("prompt: response", response);
    let mut events = agent
        .until(|line| line["type"] == "tool_execution_start" && line["toolName"] == "bash")
        .await;
    // Let the command start before the abort.
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let response = agent.call(json!({ "type": "abort" })).await;
    r.note("abort: response", response);
    events.extend(agent.settle().await);
    record(&mut r, "aborted", &agent, stable(events));
    r.note(
        "files",
        json!([
            agent.workspace.join("first.txt").exists(),
            agent.workspace.join("never.txt").exists()
        ]),
    );
    session(&mut r, &agent);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_ptc_abort", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ptc_unawaited() {
    // No write broker: when the operation reaches its write lease relative
    // to the script's end depends on the tool's own I/O.
    let Some(mut agent) = AgentRun::start(AgentOptions {
        env: Vec::new(),
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    scripts(
        &mut agent,
        &mut r,
        "an operation the script never awaited",
        &[(
            "u1",
            code("tools.bash({ command: 'sleep 5; touch late.txt' }); return 'returned early';"),
        )],
    )
    .await;
    r.note(
        "late.txt exists",
        json!(agent.workspace.join("late.txt").exists()),
    );
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_ptc_unawaited", r.into_value());
}

/// Large values a script handles without the model writing them out: what
/// events and the session show of them is bounded. Only those parts are
/// recorded (the requests repeat the large tool call).
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ptc_large_values() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        tools(&[
            (
                "b1",
                "ptc",
                code("await tools.write({ path: 'big.txt', content: 'x'.repeat(200000) }); return 'ok';"),
            ),
            ("b2", "ptc", code(&"x".repeat(65_537))),
            (
                "b3",
                "ptc",
                code("const r = await tools.call('write', { path: 'huge.txt', content: 'x'.repeat(1024 * 1024) }); return [r.ok, r.error.code, r.error.message];"),
            ),
        ]),
        ModelReply::Text("ok".to_owned()),
    ]);
    agent
        .call(json!({ "type": "prompt", "message": "go" }))
        .await;
    let events = stable(agent.settle().await);
    agent.take_requests();
    let shown: Vec<Value> = events
        .into_iter()
        .filter(|event| {
            event["type"] == "tool_execution_start" && event["toolName"] == "write"
                || event["type"] == "tool_execution_end"
        })
        .map(|mut event| {
            if event["toolName"] == "ptc" && event["type"] == "tool_execution_start" {
                event["args"] = json!("<the script>");
            }
            event
        })
        .collect();
    r.note("operation events and results", json!(shown));
    let mut operations: Vec<Value> = agent
        .session_entries()
        .into_iter()
        .filter(|entry| entry["customType"] == "ptc.operation")
        .collect();
    operations.iter_mut().for_each(mask);
    r.note("operation entries", json!(operations));
    r.note(
        "file lengths",
        json!(["big.txt", "huge.txt"].map(|name| {
            std::fs::read_to_string(agent.workspace.join(name))
                .map(|text| text.len())
                .ok()
        })),
    );
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_ptc_large_values", r.into_value());
}

/// Progress cadence is timing-dependent, but updates must remain inside the
/// parent tool's lifetime. Feature snapshots validate operation events/results.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ptc_progress_stays_inside_tool_lifetime() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    agent.push([
        ModelReply::tool("progress", "ptc", code(
            "await tools.call('bash', {command: 'sleep 0.2; printf progress-complete'}); return 'done';"
        )),
        ModelReply::Text("done".to_owned()),
    ]);
    agent
        .call(json!({"type":"prompt","message":"run the slow operation"}))
        .await;
    let events = agent.settle().await;
    let outer = |event: &Value| event["toolCallId"] == "progress" && event["toolName"] == "ptc";
    let started = events
        .iter()
        .position(|e| outer(e) && e["type"] == "tool_execution_start")
        .unwrap();
    let ended = events
        .iter()
        .position(|e| outer(e) && e["type"] == "tool_execution_end")
        .unwrap();
    let updates: Vec<_> = events
        .iter()
        .enumerate()
        .filter(|(_, e)| outer(e) && e["type"] == "tool_execution_update")
        .collect();
    assert!(!updates.is_empty(), "missing PTC progress: {events:?}");
    assert!(updates.iter().all(|(i, _)| started < *i && *i < ended));
    assert!(updates.iter().any(|(_, e)| {
        e["partialResult"]["content"][0]["text"]
            .as_str()
            .is_some_and(|s| s.contains("1 completed"))
    }));
    assert_eq!(events[ended]["isError"], false);
    assert_eq!(agent.finish().await, Some(0));
}
