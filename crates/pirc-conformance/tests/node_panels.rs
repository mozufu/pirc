//! The node's side-panel routes (`apps/gateway/src/node/panel-routes.ts`,
//! `node/inspect.ts`) and uploads (`node/app.ts`), through a real gateway
//! and a real node: Git status, diffs, history and commits; the file
//! browser and its containment; the memory, context and background panels
//! with and without a live agent; browser recordings; uploads and what a
//! prompt that references them gives the model; and who may use these
//! routes. `node_panels_link` plays the gateway instead, for the checks
//! the real gateway makes before relaying anything. The historical node
//! baseline (docs/development/historical-records.md).

mod node_panels_support;

use std::fs;
use std::os::unix::fs::symlink;
use std::time::Duration;

use node_panels_support::{Panel, condense, encode, git, settled};
use pirc_conformance::{
    Cluster, FakeGateway, GatewayOptions, LoneNode, NODE_ID, NodeOptions, Reply, Transcript, USER,
};
use serde_json::{Value, json};

/// The run directories lie inside this repository's worktree: Git must not
/// find it from the node's workspace. The node passes the variable on to
/// the Git it runs because `PIRC_AGENT_ENV_ALLOW` names it.
fn no_outer_repository() -> Vec<(&'static str, String)> {
    let base = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/conformance");
    fs::create_dir_all(&base).unwrap();
    let base = base.canonicalize().unwrap();
    vec![
        ("PIRC_AGENT_ENV_ALLOW", "GIT_CEILING_DIRECTORIES".to_owned()),
        ("GIT_CEILING_DIRECTORIES", base.display().to_string()),
    ]
}

/// Git: no repository, a subdirectory of one, no commits yet, then two
/// commits with an upstream and every kind of change; diff, log and commit
/// options and errors.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_panels_git() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        node_env: no_outer_repository(),
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let mut p = Panel::open(&cluster).await;
    let ws = p.workspace.clone();

    // Not a repository yet.
    p.get("status outside a repository", "/git/status").await;
    p.get("log outside a repository", "/git/log").await;
    p.get("diff outside a repository", "/git/diff").await;
    p.get("a commit outside a repository", "/git/commits/abcd1234")
        .await;

    // The workspace as a subdirectory of a repository: `root` is its path
    // in the repository, files outside it are not shown.
    let run = ws.parent().unwrap().to_owned();
    git(&run, &["init", "-q", "-b", "outer"]);
    fs::write(ws.join("inside.txt"), "inside\n").unwrap();
    p.get("status in a subdirectory of a repository", "/git/status")
        .await;
    p.get(
        "untracked diff in a subdirectory",
        "/git/diff?path=inside.txt&untracked=1",
    )
    .await;
    fs::remove_dir_all(run.join(".git")).unwrap();
    fs::remove_file(ws.join("inside.txt")).unwrap();

    // A repository without commits.
    git(&ws, &["init", "-q", "-b", "main"]);
    p.get("status before the first commit", "/git/status").await;
    p.get("log before the first commit", "/git/log").await;

    // Two commits, a branch `base` at the first one as `main`'s upstream.
    fs::write(ws.join("a.txt"), "one\n").unwrap();
    fs::write(ws.join("gone.txt"), "to be deleted\n").unwrap();
    fs::write(ws.join("old name.txt"), "renamed content\n").unwrap();
    git(&ws, &["add", "."]);
    git(&ws, &["commit", "-q", "-m", "first commit"]);
    git(&ws, &["branch", "base"]);
    fs::write(ws.join("a.txt"), "one\ntwo\n").unwrap();
    fs::create_dir(ws.join("src")).unwrap();
    fs::write(ws.join("src/lib.rs"), "fn main() {}\n").unwrap();
    git(&ws, &["add", "."]);
    git(
        &ws,
        &[
            "commit",
            "-q",
            "-m",
            "second commit",
            "-m",
            "With a body\nover two lines.",
        ],
    );
    git(&ws, &["tag", "v1"]);
    git(&ws, &["branch", "-q", "--set-upstream-to", "base"]);
    let head = git(&ws, &["rev-parse", "HEAD"]).trim().to_owned();
    let first = git(&ws, &["rev-parse", "HEAD~1"]).trim().to_owned();
    p.note(
        "the commits (fixed author and clock)",
        json!({ "HEAD": head, "HEAD~1": first }),
    );

    // Staged, unstaged and untracked changes; a staged rename and deletion.
    fs::write(ws.join("a.txt"), "one\ntwo\nthree staged\n").unwrap();
    git(&ws, &["add", "a.txt"]);
    fs::write(ws.join("a.txt"), "one\ntwo\nthree staged\nfour unstaged\n").unwrap();
    git(&ws, &["mv", "old name.txt", "new name.txt"]);
    git(&ws, &["rm", "-q", "gone.txt"]);
    fs::write(ws.join("src/lib.rs"), "fn main() { changed(); }\n").unwrap();
    fs::write(ws.join("new file.txt"), "fresh\n").unwrap();
    fs::create_dir(ws.join("untracked dir")).unwrap();
    fs::write(ws.join("untracked dir/inner.txt"), "inner\n").unwrap();
    fs::write(ws.join("-dash.txt"), "dash\n").unwrap();
    fs::write(ws.join("ünïcode.txt"), "ü\n").unwrap();

    p.get(
        "status: branch, upstream, ahead, every kind of change",
        "/git/status",
    )
    .await;

    for (step, query) in [
        ("worktree diff of everything", ""),
        ("staged diff of everything", "?staged=1"),
        ("staged=true", "?staged=true"),
        ("staged=0 is the worktree", "?staged=0"),
        ("staged=false", "?staged=false"),
        ("a bad flag value", "?staged=yes"),
        ("worktree diff of one file", "?path=a.txt"),
        ("staged diff of one file", "?path=a.txt&staged=1"),
        ("a file in a subdirectory", "?path=src/lib.rs"),
        ("a leading slash is dropped", "?path=/a.txt"),
        ("a backslash is a separator", "?path=src%5Clib.rs"),
        ("a path that is normalized", "?path=src/../a.txt"),
        ("a staged deletion", "?path=gone.txt&staged=1"),
        ("an unchanged file", "?path=README.md"),
        ("a missing file in the workspace", "?path=nothing.txt"),
        ("a missing directory", "?path=nowhere/x.txt"),
        ("a glob is literal", "?path=*.txt"),
        ("an untracked file", "?path=new%20file.txt&untracked=1"),
        (
            "an untracked file in an untracked directory",
            "?path=untracked%20dir/inner.txt&untracked=1",
        ),
        (
            "an untracked file named with a dash",
            "?path=-dash.txt&untracked=1",
        ),
        (
            "an untracked non-ASCII name",
            "?path=%C3%BCn%C3%AFcode.txt&untracked=1",
        ),
        (
            "untracked ignores staged",
            "?path=new%20file.txt&untracked=1&staged=1",
        ),
        ("untracked without a path", "?untracked=1"),
        ("untracked on a directory", "?path=src&untracked=1"),
        (
            "untracked on a missing file",
            "?path=missing.txt&untracked=1",
        ),
        ("a path outside the workspace", "?path=../secret.txt"),
        ("a path of ..", "?path=.."),
        ("a path of .", "?path=."),
        ("an empty path", "?path="),
        (
            "a path that is too long",
            &format!("?path={}", "a".repeat(4097)),
        ),
    ] {
        p.get(&format!("diff: {step}"), &format!("/git/diff{query}"))
            .await;
    }

    for (step, query) in [
        ("defaults", ""),
        ("limit 1 has more", "?limit=1"),
        ("skip 1", "?skip=1"),
        ("skip past the end", "?skip=5"),
        ("limit 2 has no more", "?limit=2"),
        ("limit 0", "?limit=0"),
        ("limit 201", "?limit=201"),
        ("limit 200", "?limit=200"),
        ("a negative skip", "?skip=-1"),
        ("a fractional limit", "?limit=1.5"),
        ("a non-numeric skip", "?skip=x"),
        ("an empty limit", "?limit="),
    ] {
        p.get(&format!("log: {step}"), &format!("/git/log{query}"))
            .await;
    }

    let short = &head[..7];
    let upper = head.to_uppercase();
    for (step, sha) in [
        ("the head commit", head.as_str()),
        ("the first commit (a root commit)", first.as_str()),
        ("by its short id", short),
        ("upper case", upper.as_str()),
        ("an unknown id", "deadbeef0"),
        ("a non-hex id", "not-a-sha"),
        ("too short", "abc"),
        ("a ref name is not an id", "main"),
        ("too long", &"a".repeat(65)),
    ] {
        p.get(&format!("commit: {step}"), &format!("/git/commits/{sha}"))
            .await;
    }

    p.get("files: .git is not listed", "/files").await;

    insta::assert_json_snapshot!("node_panels_git", p.into_value());
}

/// A PNG's signature and the start of its header chunk.
const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0\x01\0\0\0\x01\x08\x06\0\0\0";
/// A JPEG's start-of-image marker and an APP0 segment.
const JPEG: &[u8] = b"\xff\xd8\xff\xe0\0\x10JFIF\0\x01\x01\0\0\x01\0\x01\0\0";

/// The file browser: listing order and kinds, text, binary and image
/// contents, size limits, and every way out of the workspace.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_panels_files() {
    let Some(cluster) = Cluster::start().await else {
        return;
    };
    let mut p = Panel::open(&cluster).await;
    let ws = p.workspace.clone();
    let run = ws.parent().unwrap().to_owned();

    fs::create_dir_all(ws.join("src/nested")).unwrap();
    fs::write(ws.join("src/main.ts"), "export {};\n").unwrap();
    fs::write(ws.join("src/nested/deep.txt"), "deep\n").unwrap();
    fs::create_dir(ws.join(".git")).unwrap();
    fs::write(ws.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
    fs::write(ws.join(".hidden"), "dotfile\n").unwrap();
    fs::create_dir(ws.join(".config")).unwrap();
    fs::create_dir(ws.join("Zeta")).unwrap();
    fs::create_dir(ws.join("alpha")).unwrap();
    for name in [
        "b10.txt",
        "b2.txt",
        "B1.txt",
        "_under.txt",
        "émile.txt",
        "Émile2.txt",
    ] {
        fs::write(ws.join(name), name).unwrap();
    }
    fs::write(ws.join("bin.dat"), [1u8, 0, 2]).unwrap();
    fs::write(ws.join("empty.txt"), "").unwrap();
    fs::write(ws.join("utf8.txt"), "héllo ✓\n").unwrap();
    fs::write(ws.join("shot.png"), PNG).unwrap();
    fs::write(ws.join("upper.PNG"), PNG).unwrap();
    fs::write(ws.join("photo.jpeg"), JPEG).unwrap();
    fs::write(ws.join("fake.gif"), "not really a gif\n").unwrap();
    fs::write(
        ws.join("icon.svg"),
        r#"<svg xmlns="http://www.w3.org/2000/svg"/>"#,
    )
    .unwrap();
    // Over the 8 MiB image limit (sparse: cheap to write).
    fs::File::create(ws.join("huge.jpg"))
        .unwrap()
        .set_len(9 * 1_048_576)
        .unwrap();
    // Over the 1 MiB text limit, once ASCII and once with a two-byte
    // character split by the cut.
    fs::write(ws.join("big.txt"), "x".repeat(1_048_576 + 10)).unwrap();
    fs::write(
        ws.join("big-utf8.txt"),
        format!("{}é tail", "x".repeat(1_048_575)),
    )
    .unwrap();
    fs::write(run.join("secret.txt"), "nope").unwrap();
    fs::create_dir(run.join("outside")).unwrap();
    symlink(run.join("secret.txt"), ws.join("leak")).unwrap();
    symlink(run.join("outside"), ws.join("outside-dir")).unwrap();
    symlink("src/main.ts", ws.join("inner-link")).unwrap();
    symlink("src", ws.join("dir-link")).unwrap();
    symlink("nowhere", ws.join("dangling")).unwrap();
    let fifo = std::process::Command::new("mkfifo")
        .arg(ws.join("pipe"))
        .status()
        .unwrap();
    assert!(fifo.success());
    fs::write(ws.join("unreadable.txt"), "secret").unwrap();
    fs::set_permissions(
        ws.join("unreadable.txt"),
        std::os::unix::fs::PermissionsExt::from_mode(0o000),
    )
    .unwrap();

    let abs = |relative: &str| encode(&format!("{}{relative}", ws.display()));
    let outside = encode(&run.join("secret.txt").display().to_string());
    for (step, query) in [
        (
            "the root: dirs first, locale order, no .git, kinds of links".to_owned(),
            String::new(),
        ),
        ("an empty path is the root".to_owned(), "?path=".to_owned()),
        ("a subdirectory".to_owned(), "?path=src".to_owned()),
        ("a trailing slash".to_owned(), "?path=src/".to_owned()),
        ("a ./ prefix".to_owned(), "?path=./src".to_owned()),
        ("a leading slash".to_owned(), "?path=/src".to_owned()),
        (
            "a nested directory".to_owned(),
            "?path=src/nested".to_owned(),
        ),
        (
            "through a link to a directory".to_owned(),
            "?path=dir-link".to_owned(),
        ),
        (
            "the .git directory itself".to_owned(),
            "?path=.git".to_owned(),
        ),
        (
            "an absolute path of the root".to_owned(),
            format!("?path={}", abs("")),
        ),
        (
            "an absolute path inside".to_owned(),
            format!("?path={}", abs("/src")),
        ),
        (
            "an absolute path outside".to_owned(),
            format!("?path={}", encode(&run.display().to_string())),
        ),
        (
            "an absolute path that exists nowhere inside".to_owned(),
            "?path=/etc".to_owned(),
        ),
        (
            "a file is not a directory".to_owned(),
            "?path=README.md".to_owned(),
        ),
        ("a missing directory".to_owned(), "?path=missing".to_owned()),
        ("..".to_owned(), "?path=..".to_owned()),
        ("../".to_owned(), "?path=../".to_owned()),
        (
            "a ../ escape".to_owned(),
            "?path=src/../../outside".to_owned(),
        ),
        (
            "a link to a directory outside".to_owned(),
            "?path=outside-dir".to_owned(),
        ),
        ("a NUL byte".to_owned(), "?path=src%00".to_owned()),
        (
            "a path that is too long".to_owned(),
            format!("?path={}", "a".repeat(4097)),
        ),
    ] {
        p.get(&format!("list: {step}"), &format!("/files{query}"))
            .await;
    }

    for (step, query) in [
        ("text".to_owned(), "README.md".to_owned()),
        (
            "in a subdirectory".to_owned(),
            "src/nested/deep.txt".to_owned(),
        ),
        (
            "a normalized path".to_owned(),
            "src/../README.md".to_owned(),
        ),
        ("absolute inside".to_owned(), abs("/src/main.ts")),
        ("absolute outside".to_owned(), outside.clone()),
        ("binary".to_owned(), "bin.dat".to_owned()),
        ("empty".to_owned(), "empty.txt".to_owned()),
        ("UTF-8".to_owned(), "utf8.txt".to_owned()),
        ("a PNG image".to_owned(), "shot.png".to_owned()),
        ("an upper-case extension".to_owned(), "upper.PNG".to_owned()),
        ("a JPEG image".to_owned(), "photo.jpeg".to_owned()),
        (
            "an image by extension only".to_owned(),
            "fake.gif".to_owned(),
        ),
        ("SVG is text and an image".to_owned(), "icon.svg".to_owned()),
        ("an image over 8 MiB".to_owned(), "huge.jpg".to_owned()),
        ("text over 1 MiB".to_owned(), "big.txt".to_owned()),
        (
            "a character split by the cut".to_owned(),
            "big-utf8.txt".to_owned(),
        ),
        (
            "the .git directory's files".to_owned(),
            ".git/HEAD".to_owned(),
        ),
        ("a dotfile".to_owned(), ".hidden".to_owned()),
        ("a link inside".to_owned(), "inner-link".to_owned()),
        ("a link to a file outside".to_owned(), "leak".to_owned()),
        ("a link to a directory".to_owned(), "dir-link".to_owned()),
        ("a dangling link".to_owned(), "dangling".to_owned()),
        ("a directory".to_owned(), "src".to_owned()),
        ("a FIFO".to_owned(), "pipe".to_owned()),
        ("an unreadable file".to_owned(), "unreadable.txt".to_owned()),
        ("a missing file".to_owned(), "missing.txt".to_owned()),
        ("a ../ escape".to_owned(), "../secret.txt".to_owned()),
        ("a NUL byte".to_owned(), "README.md%00".to_owned()),
        ("an empty path".to_owned(), String::new()),
        ("a path that is too long".to_owned(), "a".repeat(4097)),
    ] {
        p.get(
            &format!("content: {step}"),
            &format!("/files/content?path={query}"),
        )
        .await;
    }
    p.get("content: without a path", "/files/content").await;

    insta::assert_json_snapshot!("node_panels_files", p.into_value());
}

/// Memory, context and background panels without and with a live agent,
/// a background task stopped from the panel, and browser recordings.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_panels_state() {
    let Some(cluster) = Cluster::start().await else {
        return;
    };
    let mut p = Panel::open(&cluster).await;
    let ws = p.workspace.clone();
    fs::write(ws.join("AGENTS.md"), "Be brief.\n").unwrap();

    // No agent has run yet.
    p.get("state without an agent", "/panel/state").await;
    p.get("context before any message", "/panel/context").await;
    p.get(
        "background output without an agent",
        "/panel/background/abc",
    )
    .await;
    p.get(
        "background output: lines out of range is checked first",
        "/panel/background/abc?lines=0",
    )
    .await;
    let stop = "/panel/background/abc/stop";
    p.call("stop without a body", "POST", stop, None).await;
    p.call("stop with an empty body", "POST", stop, Some(json!({})))
        .await;
    p.call(
        "stop with generation 0",
        "POST",
        stop,
        Some(json!({ "clientId": "browser", "generation": 0 })),
    )
    .await;
    p.call(
        "stop without holding the lease",
        "POST",
        stop,
        Some(json!({ "clientId": "browser", "generation": 1 })),
    )
    .await;
    let generation = p.acquire().await;
    p.call(
        "stop with a stale generation",
        "POST",
        stop,
        Some(json!({ "clientId": "browser", "generation": generation + 5 })),
    )
    .await;
    p.call(
        "stop as another client",
        "POST",
        stop,
        Some(json!({ "clientId": "other", "generation": generation })),
    )
    .await;
    let lease = p.lease();
    p.call(
        "stop with the lease, no agent",
        "POST",
        stop,
        Some(lease.clone()),
    )
    .await;

    // Browser recordings: read from the workspace, the browser itself is off.
    let recording = "/browser/recording?path=.pirc/recordings";
    p.get("recording: missing", &format!("{recording}/missing.webm"))
        .await;
    fs::create_dir_all(ws.join(".pirc/recordings/dir.webm")).unwrap();
    fs::write(ws.join(".pirc/recordings/r-1.webm"), b"0123456789").unwrap();
    // The gateway reads the node's chunks (`offset`, `length`) and answers
    // Range requests itself.
    for (step, query) in [
        ("a directory", "/dir.webm"),
        ("not .webm", "/r-1.mp4"),
        ("a subdirectory", "/sub/r-1.webm"),
        ("an escape", "/../../README.md"),
    ] {
        p.get(
            &format!("recording: {step}"),
            &format!("{recording}{query}"),
        )
        .await;
    }
    p.get("recording: whole", &format!("{recording}/r-1.webm"))
        .await;
    for range in [
        "bytes=4-",
        "bytes=2-4",
        "bytes=-3",
        "bytes=2-100",
        "bytes=50-",
        "bytes=x",
    ] {
        p.get_with(
            &format!("recording: range {range}"),
            &format!("{recording}/r-1.webm"),
            ("range", range),
        )
        .await;
    }
    p.get(
        "recording: another directory",
        "/browser/recording?path=r-1.webm",
    )
    .await;
    p.get("recording: without a path", "/browser/recording")
        .await;

    // A prompt starts the agent.
    cluster
        .llm
        .push([Reply::Text("Hello from the fake model.".to_owned())]);
    p.prompt(
        "prompt",
        "prompt-1",
        json!({ "type": "prompt", "message": "Say hello" }),
    )
    .await;
    // agent_settled precedes repository extraction; snapshot the idle panel.
    p.poll("/panel/state", |body| {
        body["workspaceMemory"]["extracting"] == false
    })
    .await;
    p.get("state with a live agent", "/panel/state").await;
    let context = p
        .api
        .send(
            "GET",
            &format!("{}/panel/context", p.session),
            &p.headers,
            None,
        )
        .await;
    p.note("context with a live agent", context_summary(&context.body));
    p.get(
        "background output: an unknown task",
        "/panel/background/abc",
    )
    .await;
    p.call(
        "stop an unknown task with the lease",
        "POST",
        stop,
        Some(lease.clone()),
    )
    .await;

    // A background task, started with the agent's `/bg` command.
    p.command(
        "start a background task",
        "bg-1",
        json!({ "type": "prompt",
            "message": "/bg start echo started; until [ -e go ]; do sleep 0.02; done; echo done" }),
    )
    .await;
    let state = p
        .poll("/panel/state", |body| {
            body["backgroundTasks"]
                .as_array()
                .is_some_and(|t| !t.is_empty())
        })
        .await;
    let task = state["backgroundTasks"][0]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    p.mask_as(&task, "<task>");
    p.poll(&format!("/panel/background/{task}"), |body| {
        body.to_string().contains("started")
    })
    .await;
    p.get("state with a running task", "/panel/state").await;
    p.get("its output", &format!("/panel/background/{task}"))
        .await;
    p.get(
        "its last line",
        &format!("/panel/background/{task}?lines=1"),
    )
    .await;
    p.call(
        "stop it without the lease",
        "POST",
        &format!("/panel/background/{task}/stop"),
        Some(json!({ "clientId": "browser", "generation": generation + 1 })),
    )
    .await;
    // Stopping it finishes it, which wakes the agent once.
    cluster
        .llm
        .push([Reply::Text("The task was stopped.".to_owned())]);
    let mut live = p.watch().await;
    p.call(
        "stop it",
        "POST",
        &format!("/panel/background/{task}/stop"),
        Some(lease.clone()),
    )
    .await;
    settled(&mut live).await;
    live.close().await;
    let requests = cluster.llm.requests();
    p.note("model requests", json!(requests.len()));
    p.note(
        "what the wake-up gives the model",
        requests.last().unwrap()["messages"]
            .as_array()
            .unwrap()
            .iter()
            .rev()
            .take(2)
            .rev()
            .cloned()
            .collect(),
    );
    p.get(
        "its output once stopped",
        &format!("/panel/background/{task}"),
    )
    .await;
    // The finished task is listed once it stopped; its pid is already masked.
    let state = p
        .api
        .send(
            "GET",
            &format!("{}/panel/state", p.session),
            &p.headers,
            None,
        )
        .await;
    let request = format!("GET {}/panel/state", p.session);
    p.record("state once it stopped", &request, &state);
    p.call(
        "stop it again",
        "POST",
        &format!("/panel/background/{task}/stop"),
        Some(lease.clone()),
    )
    .await;

    insta::assert_json_snapshot!("node_panels_state", p.into_value());
}

/// The context panel's answer without the texts that are the agent's
/// (system prompt, tool descriptions, messages): its shape, its sections'
/// sources and links, and what it says about the agent.
fn context_summary(body: &Value) -> Value {
    let Some(snapshot) = body["snapshot"].as_object() else {
        return body.clone();
    };
    let keys = |value: &Value| -> Vec<String> {
        value
            .as_object()
            .map(|o| o.keys().cloned().collect())
            .unwrap_or_default()
    };
    let mut top = keys(body);
    top.sort();
    let mut inner: Vec<&String> = snapshot.keys().collect();
    inner.sort();
    json!({
        "keys": top,
        "agentRunning": body["agentRunning"],
        "source": body["source"],
        "snapshot keys": inner,
        // The working directory section holds the run directory's path, so
        // its size and the totals it counts towards depend on where the
        // repository is checked out.
        "usage": snapshot.get("usage").map(|usage| {
            let mut usage = usage.clone();
            for path in ["/buckets/system", "/estimatedInput", "/scale"] {
                if let Some(value) = usage.pointer_mut(path) {
                    *value = json!("<depends on the run directory>");
                }
            }
            usage
        }),
        "capabilities": snapshot.get("capabilities").map(|c| match c {
            Value::Array(items) => json!(format!("<{} items>", items.len())),
            Value::Object(object) => json!(object.keys().collect::<Vec<_>>()),
            other => other.clone(),
        }),
        "sections": snapshot.get("sections").and_then(Value::as_array).map(|sections| sections
            .iter()
            .map(|s| {
                let mut s = s.clone();
                if s["id"] == "cwd" {
                    s["text"] = json!("<depends on the run directory>");
                    s["estimatedTokens"] = json!("<depends on the run directory>");
                } else if let Some(text) = s.get("text").and_then(Value::as_str) {
                    s["text"] = json!(format!("<{} chars>", text.chars().count()));
                }
                s
            })
            .collect::<Vec<_>>()),
        "tools": snapshot.get("tools").and_then(Value::as_array).map(|tools| tools
            .iter()
            .map(|tool| json!({ "keys": keys(tool), "name": tool["name"] }))
            .collect::<Vec<_>>()),
        "messages": snapshot.get("messages").and_then(Value::as_array).map(Vec::len),
        "model": snapshot.get("model"),
    })
}

/// A second allowed user, who owns none of the sessions.
const OTHER: &str = "other@example.com";

/// Gateway and node allowing [`USER`] and [`OTHER`], with a small node
/// upload limit (the gateway keeps its own, larger one).
fn two_users() -> GatewayOptions {
    let users = format!("{USER},{OTHER}");
    GatewayOptions {
        env: vec![("PIRC_ALLOWED_USERS", users.clone())],
        node_env: [
            vec![
                ("PIRC_ALLOWED_USERS", users),
                ("PIRC_UPLOAD_MAX_BYTES", "1024".to_owned()),
            ],
            no_outer_repository(),
        ]
        .concat(),
        ..Default::default()
    }
}

/// A valid 1×1 PNG.
const PNG_1X1: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

/// Uploads (images by their bytes, files by name, limits), then prompts
/// that reference them: what the model gets and the copies in the workspace.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_panels_uploads() {
    use base64::Engine as _;
    let Some(cluster) = Cluster::start_with(two_users()).await else {
        return;
    };
    // The fake model takes images.
    let file = cluster.models_file().to_owned();
    let mut models: Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
    models["providers"]["fake"]["models"][0]["input"] = json!(["text", "image"]);
    fs::write(&file, serde_json::to_vec_pretty(&models).unwrap()).unwrap();
    cluster.reload_gateway();
    let api = cluster.api();
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !api
        .send(
            "GET",
            "/api/models",
            &pirc_conformance::browser_headers(),
            None,
        )
        .await
        .body
        .to_string()
        .contains("image")
    {
        assert!(
            std::time::Instant::now() < deadline,
            "the models file was not reloaded"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let mut p = Panel::open(&cluster).await;
    let png = base64::engine::general_purpose::STANDARD
        .decode(PNG_1X1)
        .unwrap();

    let mut ids = std::collections::BTreeMap::new();
    let long_name = format!("?filename={}", "n".repeat(256));
    let uploads: Vec<(&str, &str, Option<&str>, Vec<u8>)> = vec![
        ("a PNG", "", Some("image/png"), png.clone()),
        (
            "a JPEG by its magic bytes",
            "",
            Some("image/jpeg"),
            JPEG.to_vec(),
        ),
        (
            "a GIF",
            "",
            Some("image/gif"),
            b"GIF89a\x01\0\x01\0\0\0\0;".to_vec(),
        ),
        (
            "a WebP",
            "",
            Some("image/webp"),
            b"RIFF\x1a\0\0\0WEBPVP8 ".to_vec(),
        ),
        (
            "a PNG declared as a JPEG",
            "",
            Some("image/jpeg"),
            png.clone(),
        ),
        (
            "a PNG declared as text",
            "",
            Some("text/plain"),
            png.clone(),
        ),
        (
            "a PNG as octet-stream",
            "",
            Some("application/octet-stream"),
            png.clone(),
        ),
        (
            "a PNG with a charset parameter",
            "",
            Some("image/png; charset=binary"),
            png.clone(),
        ),
        (
            "a PNG with a filename (an image all the same)",
            "?filename=shot.png",
            Some("image/png"),
            png.clone(),
        ),
        ("a PNG without a content type", "", None, png.clone()),
        (
            "a text file with a filename",
            "?filename=notes.txt",
            Some("text/plain"),
            b"hello file\n".to_vec(),
        ),
        (
            "a file without a content type",
            "?filename=data.bin",
            None,
            vec![0, 1, 2, 3],
        ),
        (
            "a file with an unknown type",
            "?filename=a.xyz",
            Some("application/x-custom"),
            b"custom".to_vec(),
        ),
        (
            "a filename with directories",
            "?filename=..%2F..%2Fdir%2Fevil.txt",
            Some("text/plain"),
            b"evil\n".to_vec(),
        ),
        (
            "a filename with spaces around",
            "?filename=%20padded.txt%20",
            Some("text/plain"),
            b"padded\n".to_vec(),
        ),
        (
            "a filename of spaces",
            "?filename=%20%20",
            Some("text/plain"),
            b"x".to_vec(),
        ),
        (
            "a filename of ..",
            "?filename=..",
            Some("text/plain"),
            b"x".to_vec(),
        ),
        (
            "a filename over 255 characters",
            &long_name,
            Some("text/plain"),
            b"x".to_vec(),
        ),
        (
            "a non-image without a filename",
            "",
            Some("text/plain"),
            b"no name".to_vec(),
        ),
        (
            "a JSON body",
            "?filename=a.json",
            Some("application/json"),
            b"{\"a\":1}".to_vec(),
        ),
        (
            "an empty body",
            "?filename=empty.txt",
            Some("text/plain"),
            Vec::new(),
        ),
        (
            "exactly the node's limit",
            "?filename=limit.txt",
            Some("text/plain"),
            vec![b'l'; 1024],
        ),
        (
            "over the node's limit",
            "?filename=over.txt",
            Some("text/plain"),
            vec![b'o'; 1025],
        ),
        (
            "an image over the node's limit",
            "",
            Some("image/png"),
            [png.as_slice(), &[0u8; 1024]].concat(),
        ),
    ];
    for (step, query, content_type, body) in uploads {
        let path = format!("{}/uploads{query}", p.session);
        let response = p
            .api
            .send_bytes("POST", &path, &p.headers, content_type, body)
            .await;
        let request = format!(
            "POST {path} ({})",
            content_type.unwrap_or("no content type")
        );
        p.record(&format!("upload: {step}"), &request, &response);
        if let Some(id) = response.body["upload"]["id"].as_str() {
            ids.insert(step, id.to_owned());
        }
    }

    // Someone else may not upload into the session.
    let mut other = p.headers.clone();
    other.retain(|(name, _)| *name != "x-pirc-user");
    other.push(("x-pirc-user", OTHER.to_owned()));
    let path = format!("{}/uploads", p.session);
    let response = p
        .api
        .send_bytes("POST", &path, &other, Some("image/png"), png.clone())
        .await;
    p.record(
        "upload: another user",
        &format!("POST {path} (image/png, as {OTHER})"),
        &response,
    );
    let unknown = "/api/sessions/session_unknown/uploads";
    let response = p
        .api
        .send_bytes("POST", unknown, &p.headers, Some("image/png"), png.clone())
        .await;
    p.record(
        "upload: an unknown session",
        &format!("POST {unknown}"),
        &response,
    );

    // A prompt that references them: images go to the model, files are
    // copied into the workspace and named in the message.
    p.acquire().await;
    p.command(
        "a prompt with an unknown upload",
        "unknown-upload",
        json!({ "type": "prompt", "message": "look", "uploadIds": ["upload_nope"] }),
    )
    .await;
    p.command(
        "a prompt with 17 uploads",
        "too-many",
        json!({ "type": "prompt", "message": "look", "uploadIds": vec![&ids["a PNG"]; 17] }),
    )
    .await;
    cluster.llm.push([Reply::Text("I see them.".to_owned())]);
    let uploaded = json!([
        ids["a PNG"],
        ids["a text file with a filename"],
        ids["a JPEG by its magic bytes"],
        ids["a filename with directories"],
        ids["a file without a content type"],
    ]);
    p.prompt(
        "a prompt with images and files",
        "with-uploads",
        json!({ "type": "prompt", "message": "Look at these", "uploadIds": uploaded }),
    )
    .await;
    let requests = cluster.llm.requests();
    let last = requests.last().unwrap()["messages"]
        .as_array()
        .unwrap()
        .last()
        .cloned()
        .unwrap();
    p.note("what the model receives", last);
    let path = format!("{}/files?path=.pirc/uploads", p.session);
    let mut listed = p.api.send("GET", &path, &p.headers, None).await;
    // Listed in the order of their (random) upload ids: recorded in the
    // order of the file names instead.
    listed.body["entries"]
        .as_array_mut()
        .unwrap()
        .sort_by_key(|entry| entry["name"].as_str().unwrap()["upload_".len() + 37..].to_owned());
    p.record(
        "the copies in the workspace (sorted by file name here)",
        &format!("GET {path}"),
        &listed,
    );
    for entry in listed.body["entries"].as_array().unwrap() {
        let name = entry["name"].as_str().unwrap();
        // `<upload id>-<file name>`
        let file = &name["upload_".len() + 37..];
        p.get(
            &format!("content of the copy of {file}"),
            &format!("/files/content?path=.pirc/uploads/{}", encode(name)),
        )
        .await;
    }
    p.get(".pirc itself", "/files?path=.pirc").await;
    // The same files again: already copied, the message is the same.
    cluster.llm.push([Reply::Text("Again.".to_owned())]);
    p.prompt(
        "the same files again, as a follow-up",
        "again",
        json!({ "type": "prompt", "message": "Again", "uploadIds": [ids["a text file with a filename"]] }),
    )
    .await;
    let requests = cluster.llm.requests();
    let last = requests.last().unwrap()["messages"]
        .as_array()
        .unwrap()
        .last()
        .cloned()
        .unwrap();
    p.note("what the model receives the second time", last);
    let snapshot = p
        .api
        .send("GET", &format!("{}/snapshot", p.session), &p.headers, None)
        .await;
    let users: Vec<Value> = snapshot.body["history"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|message| message["role"] == "user")
        .cloned()
        .collect();
    p.note("the user messages in the session's history", json!(users));

    insta::assert_json_snapshot!("node_panels_uploads", p.into_value());
}

/// Who may use the panel routes: the owner, another user, no identity, an
/// unknown session.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_panels_access() {
    let Some(cluster) = Cluster::start_with(two_users()).await else {
        return;
    };
    let mut p = Panel::open(&cluster).await;
    let generation = p.acquire().await;
    let lease = json!({ "clientId": "browser", "generation": generation });
    let routes: Vec<(&str, &str, Option<Value>)> = vec![
        ("GET", "/git/status", None),
        ("GET", "/git/diff?path=README.md", None),
        ("GET", "/git/log", None),
        ("GET", "/git/commits/abcd1234", None),
        ("GET", "/files", None),
        ("GET", "/files/content?path=README.md", None),
        ("GET", "/panel/state", None),
        ("GET", "/panel/context", None),
        ("GET", "/panel/background/abc", None),
        ("POST", "/panel/background/abc/stop", Some(lease.clone())),
        (
            "GET",
            "/browser/recording?path=.pirc/recordings/a.webm",
            None,
        ),
    ];
    let mut other = p.headers.clone();
    other.retain(|(name, _)| *name != "x-pirc-user");
    other.push(("x-pirc-user", OTHER.to_owned()));
    let mut anonymous = p.headers.clone();
    anonymous.retain(|(name, _)| *name != "x-pirc-user");
    let unknown = "/api/sessions/session_unknown";
    for (method, suffix, body) in routes {
        let path = format!("{}{suffix}", p.session);
        p.call(
            &format!("{method} {suffix}: the owner"),
            method,
            suffix,
            body.clone(),
        )
        .await;
        let response = p.api.send(method, &path, &other, body.clone()).await;
        p.record(
            &format!("{method} {suffix}: another user"),
            &format!("{method} {path} (as {OTHER})"),
            &response,
        );
        let response = p.api.send(method, &path, &anonymous, body.clone()).await;
        p.record(
            &format!("{method} {suffix}: no identity"),
            &format!("{method} {path} (no identity)"),
            &response,
        );
        p.call_path(
            &format!("{method} {suffix}: an unknown session"),
            method,
            &format!("{unknown}{suffix}"),
            body,
        )
        .await;
    }
    // The other user takes control: the owner's lease is gone, theirs
    // does not reach a session they cannot see.
    let path = format!("{}/control/acquire", p.session);
    let response = p
        .api
        .send(
            "POST",
            &path,
            &other,
            Some(json!({ "clientId": "intruder", "force": true })),
        )
        .await;
    p.record(
        "another user cannot take control",
        &format!("POST {path} (as {OTHER})"),
        &response,
    );
    insta::assert_json_snapshot!("node_panels_access", p.into_value());
}

/// The node's own checks, with the test as the gateway: requests the real
/// gateway never relays (it validates or answers them itself), and the
/// node's ownership check of the user a request is relayed for.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_panels_link() {
    use base64::Engine as _;
    let gateway = FakeGateway::bind().await;
    let users = format!("{USER},{OTHER}");
    let Some(node) = LoneNode::start_with(
        gateway.port(),
        NodeOptions {
            env: [
                vec![
                    ("PIRC_ALLOWED_USERS", users),
                    ("PIRC_UPLOAD_MAX_BYTES", "1024".to_owned()),
                ],
                no_outer_repository(),
            ]
            .concat(),
            ..Default::default()
        },
    ) else {
        return;
    };
    let mut t = Transcript::new(node.volatile());
    let mut link = gateway.accept().await;
    link.recv_where(|frame| frame["type"] == "register").await;
    link.send(
        &json!({ "type": "registered", "nodeId": NODE_ID, "models": {
        "providers": {} }, "mirrors": {} }),
    )
    .await;

    let mut count = 0;
    let created = link
        .request(
            "create",
            json!({ "method": "POST", "url": "/api/session-creations/internal", "user": USER,
                "payload": { "workspaceId": "test" } }),
        )
        .await;
    t.note("create a session", created["data"].clone());
    let session = format!(
        "/api/sessions/{}",
        created["data"]["body"]["session"]["id"].as_str().unwrap()
    );
    let workspace = node.dir.path().canonicalize().unwrap().join("workspace");
    fs::create_dir_all(workspace.join(".pirc/recordings")).unwrap();
    fs::write(workspace.join(".pirc/recordings/r.webm"), b"0123456789").unwrap();
    let png = base64::engine::general_purpose::STANDARD
        .decode(PNG_1X1)
        .unwrap();
    let encoded = |bytes: &[u8]| base64::engine::general_purpose::STANDARD.encode(bytes);

    let long_task = format!("/panel/background/{}", "a".repeat(101));
    let requests: Vec<(&str, Value)> = vec![
        (
            "files as the owner",
            json!({ "method": "GET", "url": "/files", "user": USER }),
        ),
        (
            "files as another allowed user",
            json!({ "method": "GET", "url": "/files", "user": OTHER }),
        ),
        (
            "files as a user the node does not allow",
            json!({ "method": "GET", "url": "/files", "user": "stranger@example.com" }),
        ),
        (
            "a commit id that is not hex",
            json!({ "method": "GET", "url": "/git/commits/not-a-sha", "user": USER }),
        ),
        (
            "a commit id of 4 non-hex characters",
            json!({ "method": "GET", "url": "/git/commits/zzzz", "user": USER }),
        ),
        (
            "a commit id under 4 characters",
            json!({ "method": "GET", "url": "/git/commits/abc", "user": USER }),
        ),
        (
            "a commit ref",
            json!({ "method": "GET", "url": "/git/commits/HEAD~1", "user": USER }),
        ),
        (
            "a task id over 100 characters",
            json!({ "method": "GET", "url": long_task, "user": USER }),
        ),
        (
            "recording: a chunk",
            json!({ "method": "GET",
            "url": "/browser/recording?path=.pirc/recordings/r.webm&offset=3&length=4", "user": USER }),
        ),
        (
            "recording: the default length",
            json!({ "method": "GET",
            "url": "/browser/recording?path=.pirc/recordings/r.webm", "user": USER }),
        ),
        (
            "recording: an offset past the end",
            json!({ "method": "GET",
            "url": "/browser/recording?path=.pirc/recordings/r.webm&offset=50", "user": USER }),
        ),
        (
            "recording: length 0",
            json!({ "method": "GET",
            "url": "/browser/recording?path=.pirc/recordings/r.webm&length=0", "user": USER }),
        ),
        (
            "recording: length over 4 MiB",
            json!({ "method": "GET",
            "url": "/browser/recording?path=.pirc/recordings/r.webm&length=4194305", "user": USER }),
        ),
        (
            "recording: a negative offset",
            json!({ "method": "GET",
            "url": "/browser/recording?path=.pirc/recordings/r.webm&offset=-1", "user": USER }),
        ),
        (
            "upload: an empty body",
            json!({ "method": "POST", "url": "/uploads?filename=a.txt",
            "user": USER, "bodyBase64": "", "contentType": "text/plain" }),
        ),
        (
            "upload: a JSON payload",
            json!({ "method": "POST", "url": "/uploads?filename=a.txt",
            "user": USER, "payload": { "data": "x" } }),
        ),
        (
            "upload: a PNG without a content type (octet-stream)",
            json!({ "method": "POST",
            "url": "/uploads", "user": USER, "bodyBase64": encoded(&png) }),
        ),
        (
            "upload: a PNG declared as a JPEG",
            json!({ "method": "POST", "url": "/uploads",
            "user": USER, "bodyBase64": encoded(&png), "contentType": "image/jpeg" }),
        ),
        (
            "upload: over the limit",
            json!({ "method": "POST", "url": "/uploads?filename=a.txt",
            "user": USER, "bodyBase64": encoded(&[b'x'; 1025]), "contentType": "text/plain" }),
        ),
        (
            "upload: an empty filename",
            json!({ "method": "POST", "url": "/uploads?filename=",
            "user": USER, "bodyBase64": encoded(b"x"), "contentType": "text/plain" }),
        ),
        (
            "upload: another allowed user",
            json!({ "method": "POST", "url": "/uploads",
            "user": OTHER, "bodyBase64": encoded(&png), "contentType": "image/png" }),
        ),
    ];
    for (step, mut request) in requests {
        let url = request["url"].as_str().unwrap().to_owned();
        request["url"] = json!(format!("{session}{url}"));
        count += 1;
        let mut response = link
            .request(&format!("request-{count}"), request.clone())
            .await;
        // As `Transcript::response` does: the validation library's report is not recorded.
        if let Some(error) = response
            .pointer_mut("/data/body/error")
            .and_then(Value::as_object_mut)
        {
            error.remove("details");
        }
        if let Some(body) = request["bodyBase64"].as_str() {
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(body)
                .unwrap();
            request["bodyBase64"] = json!(format!("<{} bytes>", bytes.len()));
        }
        t.note(
            step,
            condense(json!({ "request": request, "response": response["data"] })),
        );
    }
    let unknown = link
        .request(
            "unknown",
            json!({ "method": "GET", "url": "/api/sessions/session_unknown/files", "user": USER }),
        )
        .await;
    t.note("files of an unknown session", unknown["data"].clone());
    insta::assert_json_snapshot!("node_panels_link", t.into_value());
}
