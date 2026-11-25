//! `pirc-node agent --session-dir DIR` (`agent/main.ts`): the `configure`
//! handshake, the agent, then RPC until stdin ends.

use std::io::BufRead;
use std::path::PathBuf;
use std::process::ExitCode;
use std::rc::Rc;

use pirc_protocol::Models;
use serde_json::Value;
use tokio::sync::mpsc;

use crate::agent::{Agent, AgentOptions, NameSource};
use crate::capabilities::Capabilities;
use crate::channels::{NodeChannels, node_channels, process_write_lease};
use crate::config::load_agent_config;
use crate::roles::AgentRole;
use crate::rpc::{RpcUi, Write, serve_rpc, stdout_write};
use crate::session_store::SessionStore;
use crate::ui::{NotifyLevel, Ui};

/// A parsed option (`parseArgs` with `strict: false`): a value, or `true`
/// for a flag given without one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Arg {
    Flag,
    Value(String),
}

/// The options `runAgent` reads. `--mode` and `--continue` are legacy and
/// ignored (sessions always resume from their directory).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Args {
    pub session_dir: Option<Arg>,
    pub model: Option<Arg>,
    pub thinking: Option<Arg>,
    pub name: Option<Arg>,
    pub headless: Option<Arg>,
    pub tools: Option<Arg>,
}

/// String-typed options take the next argument as their value.
const STRING_OPTIONS: [&str; 6] = ["session-dir", "mode", "model", "thinking", "name", "tools"];

/// `parseArgs({ strict: false })` as Bun runs it: `--name=value`, a string
/// option takes the next argument (whatever it is), `--` ends the options,
/// the last occurrence wins, unknown options and positionals are ignored.
pub fn parse_args(args: &[String]) -> Args {
    let mut out = Args::default();
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        index += 1;
        if arg == "--" {
            break;
        }
        let Some(option) = arg.strip_prefix("--") else {
            continue;
        };
        let (name, value) = match option.split_once('=') {
            Some((name, value)) => (name, Arg::Value(value.to_owned())),
            None if STRING_OPTIONS.contains(&option) && index < args.len() => {
                index += 1;
                (option, Arg::Value(args[index - 1].clone()))
            }
            None => (option, Arg::Flag),
        };
        let slot = match name {
            "session-dir" => &mut out.session_dir,
            "model" => &mut out.model,
            "thinking" => &mut out.thinking,
            "name" => &mut out.name,
            "headless" => &mut out.headless,
            "tools" => &mut out.tools,
            _ => continue,
        };
        *slot = Some(value);
    }
    out
}

fn string(arg: &Option<Arg>) -> Option<&str> {
    match arg {
        Some(Arg::Value(value)) => Some(value),
        _ => None,
    }
}

/// The `configure` line: the public catalog with the node's inference
/// transport, the chat policy and a role.
pub struct Configure {
    pub models: Models,
    pub persistence: Option<pirc_protocol::InferenceConfig>,
    pub capabilities: Capabilities,
    pub role: Option<AgentRole>,
    /// A team child follows its parent session's approval mode.
    pub approval_mode: Option<crate::auto_mode::ApprovalMode>,
}

/// `readConfigure`: the first non-blank line must be the configure message.
pub async fn read_configure(
    lines: &mut mpsc::UnboundedReceiver<String>,
) -> Result<Configure, String> {
    loop {
        let Some(line) = lines.recv().await else {
            return Err("stdin closed before the configure message".to_owned());
        };
        if crate::rpc::blank(&line) {
            continue;
        }
        let message: Value = serde_json::from_str(&line)
            .map_err(|_| "The first stdin line must be a JSON configure message".to_owned())?;
        return parse_configure(&message);
    }
}

pub fn parse_configure(message: &Value) -> Result<Configure, String> {
    if message.get("type").and_then(Value::as_str) != Some("configure") {
        return Err(
            "The first stdin line must be {\"type\":\"configure\",\"models\":…}".to_owned(),
        );
    }
    let models = match message.get("models") {
        None | Some(Value::Null) => Value::Object(Default::default()),
        Some(models) => models.clone(),
    };
    let models = crate::remote::parse_models(&models)?;
    let capabilities =
        Capabilities::from_value(message.get("capabilities").unwrap_or(&Value::Null));
    let role = message.get("role").and_then(|role| {
        let name = role.get("name")?.as_str()?;
        Some(AgentRole {
            name: name.to_owned(),
            instructions: role
                .get("instructions")
                .and_then(Value::as_str)
                .map(str::to_owned),
            models: role.get("models").and_then(Value::as_array).map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            }),
        })
    });
    let approval_mode = match message.get("approvalMode") {
        None | Some(Value::Null) => None,
        Some(mode) => Some(
            mode.as_str()
                .and_then(crate::auto_mode::ApprovalMode::parse)
                .ok_or("configure.approvalMode is one of read-only, auto, full-access")?,
        ),
    };
    let persistence = message
        .get("persistence")
        .filter(|v| !v.is_null())
        .map(|v| serde_json::from_value(v.clone()).map_err(|_| "Invalid persistence transport"))
        .transpose()?;
    Ok(Configure {
        models,
        persistence,
        capabilities,
        role,
        approval_mode,
    })
}

/// The longest stdin line the agent accepts (S5). The node forwards
/// gateway frames of at most [`pirc_protocol::NODE_FRAME_MAX_BYTES`]
/// (16 MiB) and answers browser requests with screenshots; four times the
/// frame limit leaves room for re-encoding while bounding the buffer.
pub const STDIN_LINE_MAX_BYTES: usize = 4 * pirc_protocol::NODE_FRAME_MAX_BYTES;

/// Lines of stdin (`stdinLines`), read on their own thread so a blocked read
/// never holds the runtime up; invalid UTF-8 becomes U+FFFD.
fn stdin_lines() -> mpsc::UnboundedReceiver<String> {
    let (sender, receiver) = mpsc::unbounded_channel();
    std::thread::spawn(move || {
        read_lines(std::io::stdin().lock(), STDIN_LINE_MAX_BYTES, |line| {
            sender.send(line).is_ok()
        });
    });
    receiver
}

/// Split `input` into lines for `deliver` until it ends, `deliver` returns
/// false, or a read fails. A line longer than `limit` bytes is not
/// buffered: the rest of it is read and dropped, and
/// [`crate::rpc::LINE_TOO_LONG`] is delivered in its place, so the RPC
/// answers it as a parse error and keeps serving.
fn read_lines(mut input: impl BufRead, limit: usize, mut deliver: impl FnMut(String) -> bool) {
    let mut line: Vec<u8> = Vec::new();
    let mut oversized = false;
    let finish = |line: &mut Vec<u8>, oversized: &mut bool| {
        if std::mem::take(oversized) {
            eprintln!("pirc agent: dropped a stdin line longer than {limit} bytes");
            crate::rpc::LINE_TOO_LONG.to_owned()
        } else {
            let text = String::from_utf8_lossy(line).into_owned();
            line.clear();
            // A long line's buffer is not kept for the rest of the session.
            line.shrink_to(64 * 1024);
            text
        }
    };
    loop {
        let chunk = match input.fill_buf() {
            Ok(chunk) => chunk,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        };
        if chunk.is_empty() {
            // A last line without a newline still counts.
            if oversized || !line.is_empty() {
                deliver(finish(&mut line, &mut oversized));
            }
            return;
        }
        let newline = chunk.iter().position(|byte| *byte == b'\n');
        let part = &chunk[..newline.unwrap_or(chunk.len())];
        if !oversized {
            if line.len() + part.len() > limit {
                oversized = true;
                line = Vec::new();
            } else {
                line.extend_from_slice(part);
            }
        }
        let used = part.len() + usize::from(newline.is_some());
        input.consume(used);
        if newline.is_some() && !deliver(finish(&mut line, &mut oversized)) {
            return;
        }
    }
}

/// What ends the agent: success (stdin ended or a signal), or an error
/// that TS would have let escape (printed, exit 1).
async fn main(args: Vec<String>) -> Result<(), String> {
    let args = parse_args(&args);
    // Tool allowlist (team kinds); team members always keep their coordination tools.
    let team_member = crate::features::team::channel::process_child_mode()
        == Some(crate::features::team::channel::ChildMode::Team);
    let allowed_tools = string(&args.tools).map(|tools| {
        let mut allowed: Vec<String> = tools
            .split(',')
            .filter(|tool| !tool.is_empty())
            .map(str::to_owned)
            .collect();
        if team_member {
            allowed.extend(
                crate::features::team::TEAM_TOOL_NAMES
                    .iter()
                    .map(|name| (*name).to_owned()),
            );
        }
        allowed
    });
    let session_dir = match &args.session_dir {
        Some(Arg::Value(dir)) => Some(dir.clone()),
        Some(Arg::Flag) => None,
        None => std::env::var("PI_CODING_AGENT_SESSION_DIR").ok(),
    }
    .filter(|dir| !dir.is_empty())
    .ok_or("--session-dir is required")?;
    let cwd = std::env::current_dir()
        .map_err(|error| error.to_string())?
        .to_string_lossy()
        .into_owned();
    let write: Write = stdout_write();
    let ui = RpcUi::new(write.clone());
    let mut lines = stdin_lines();
    let configured = read_configure(&mut lines).await?;
    crate::state_io::configure(configured.persistence)?;
    let config = load_agent_config(&cwd, configured.models, &|name| std::env::var(name).ok())?;
    let warnings = config.warnings.clone();
    let store = SessionStore::open(PathBuf::from(session_dir), &cwd)?;
    let features =
        crate::features::process_features(std::env::var("PIRC_AGENT_FEATURES").ok().as_deref())?;
    let agent = Agent::new(AgentOptions {
        config,
        capabilities: configured.capabilities,
        role: configured.role,
        store,
        emit: write.clone(),
        ui: ui.clone(),
        has_ui: !headless(&args.headless),
        tools: crate::tools::builtin_tools(),
        features,
        acquire_write: process_write_lease(),
        allowed_tools,
        stream_override: None,
    });
    agent.refresh_models().await;
    if let Some(model) = string(&args.model)
        && let Some((provider, id)) = model.split_once('/')
    {
        agent.set_model(provider, id)?;
    }
    if let Some(level) = string(&args.thinking) {
        agent.set_thinking(level)?;
    }
    if let Some(mode) = configured.approval_mode {
        agent.set_approval_mode(mode.as_str())?;
    }
    // `!agent.sessionName`: a recorded empty name counts as none.
    if let Some(name) = string(&args.name)
        && agent
            .session_name()
            .is_none_or(|current| current.is_empty())
    {
        agent.set_name(name, NameSource::User)?;
    }
    // E.g. an untrusted project config whose hooks / env / allowedPaths were ignored (H3).
    for warning in &warnings {
        ui.notify(warning, NotifyLevel::Warning);
    }
    agent.init().await?;
    let channels = node_channels();
    let mut terminate = signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut interrupt = signal(tokio::signal::unix::SignalKind::interrupt())?;
    let serve = serve_rpc(
        agent.clone(),
        ui.clone(),
        channels.clone(),
        write,
        &mut lines,
    );
    tokio::pin!(serve);
    let signalled = tokio::select! {
        served = &mut serve => {
            crash_on(served);
            false
        }
        _ = terminate.recv() => true,
        _ = interrupt.recv() => true,
    };
    let shutting_down = shutdown(&agent, &ui, &channels);
    tokio::pin!(shutting_down);
    if !signalled {
        shutting_down.await;
        return Ok(());
    }
    // `process.once`: stdin is still served while shutting down (a run may
    // still need its node), and a second signal ends the process.
    let mut serving = true;
    loop {
        tokio::select! {
            () = &mut shutting_down => return Ok(()),
            served = &mut serve, if serving => {
                crash_on(served);
                serving = false;
            }
            _ = terminate.recv() => exit(128 + 15),
            _ = interrupt.recv() => exit(128 + 2),
        }
    }
}

/// An error that escaped the RPC loop crashed the TS agent on the spot:
/// exit without running what is still pending (whose cleanup would write
/// cancel requests the TS agent never sent).
fn crash_on(served: Result<(), String>) {
    if let Err(error) = served {
        eprintln!("error: {error}");
        exit(1);
    }
}

/// `process::exit` runs no destructors, so the shells' process groups are
/// killed first: no command outlives the agent.
fn exit(code: i32) -> ! {
    crate::tools::bash::kill_live_groups();
    std::process::exit(code)
}

/// `!values.headless`: a flag or a non-empty value.
fn headless(arg: &Option<Arg>) -> bool {
    match arg {
        Some(Arg::Flag) => true,
        Some(Arg::Value(value)) => !value.is_empty(),
        None => false,
    }
}

fn signal(kind: tokio::signal::unix::SignalKind) -> Result<tokio::signal::unix::Signal, String> {
    tokio::signal::unix::signal(kind).map_err(|error| error.to_string())
}

async fn shutdown(agent: &Rc<Agent>, ui: &RpcUi, channels: &NodeChannels) {
    ui.cancel_all();
    channels.close_all();
    agent.shutdown().await;
}

/// Run one session agent; `args` follow `agent`.
pub fn run_agent(args: Vec<String>) -> ExitCode {
    // Tool subprocesses share this uid and PID namespace. Protect the RPC
    // pipes and in-memory transport credentials before reading configure.
    #[cfg(target_os = "linux")]
    if let Err(error) =
        nix::sys::prctl::set_dumpable(false).and_then(|()| nix::sys::prctl::set_no_new_privs())
    {
        eprintln!("error: cannot protect agent RPC process: {error}");
        return ExitCode::FAILURE;
    }
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("error: {error}");
            return ExitCode::FAILURE;
        }
    };
    let local = tokio::task::LocalSet::new();
    let outcome = runtime.block_on(local.run_until(main(args)));
    // Like `process.exit`: nothing still running is waited for.
    {
        let _context = runtime.enter();
        drop(local);
    }
    runtime.shutdown_background();
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error: {error}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn args(list: &[&str]) -> Args {
        parse_args(&list.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>())
    }

    fn value(text: &str) -> Option<Arg> {
        Some(Arg::Value(text.to_owned()))
    }

    #[test]
    fn parses_arguments_as_bun_parse_args_does() {
        // Cases checked against Bun's `parseArgs({ strict: false })`.
        let parsed = args(&["--session-dir", "/x", "--model"]);
        assert_eq!(parsed.session_dir, value("/x"));
        assert_eq!(parsed.model, Some(Arg::Flag));
        assert_eq!(
            args(&["--model", "--thinking", "high"]).model,
            value("--thinking")
        );
        assert_eq!(args(&["--model", "--thinking", "high"]).thinking, None);
        let parsed = args(&[
            "--model=a/b",
            "--headless=yes",
            "pos",
            "--foo",
            "--session-dir",
            "a",
            "--session-dir",
            "b",
        ]);
        assert_eq!(parsed.model, value("a/b"));
        assert_eq!(parsed.headless, value("yes"));
        assert_eq!(parsed.session_dir, value("b"));
        assert_eq!(args(&["-m", "x", "--", "--model", "q"]), Args::default());
        let parsed = args(&["--headless", "false", "--continue", "--mode", "rpc"]);
        assert_eq!(parsed.headless, Some(Arg::Flag));
        assert!(headless(&parsed.headless));
        let parsed = args(&["--tools", "", "--name", "-x"]);
        assert_eq!(parsed.tools, value(""));
        assert_eq!(parsed.name, value("-x"));
        assert_eq!(args(&["--session-dir="]).session_dir, value(""));
        assert!(!headless(&args(&["--headless="]).headless));
        assert!(!headless(&args(&["--no-headless"]).headless));
    }

    #[test]
    fn reads_the_configure_message() {
        let configure = parse_configure(&json!({ "type": "configure",
            "capabilities": { "web_search": false },
            "role": { "name": "reviewer", "instructions": 3, "models": ["a/*", 1, "b/c"] } }))
        .unwrap();
        assert!(configure.models.providers.is_empty());
        assert!(!configure.capabilities.allows("web_search"));
        assert_eq!(
            configure.role,
            Some(AgentRole {
                name: "reviewer".to_owned(),
                instructions: None,
                models: Some(vec!["a/*".to_owned(), "b/c".to_owned()]),
            })
        );
        let configure =
            parse_configure(&json!({ "type": "configure", "models": null, "role": { "name": 1 } }))
                .unwrap();
        assert!(configure.role.is_none());
        assert_eq!(configure.approval_mode, None);
        let child = parse_configure(&json!({ "type": "configure", "approvalMode": "full-access" }));
        assert_eq!(
            child.unwrap().approval_mode,
            Some(crate::auto_mode::ApprovalMode::FullAccess)
        );
        assert!(parse_configure(&json!({ "type": "configure", "approvalMode": "yolo" })).is_err());
        for message in [json!(null), json!({ "type": "prompt" }), json!([1])] {
            assert_eq!(
                parse_configure(&message).err().as_deref(),
                Some("The first stdin line must be {\"type\":\"configure\",\"models\":…}")
            );
        }
        let invalid = json!({ "type": "configure", "models": { "providers": { "p": {
            "api": "openai-completions", "baseUrl": "https://x", "models": [] } } } });
        assert_eq!(
            parse_configure(&invalid).err().as_deref(),
            Some("providers.p.models: Expected at least one entry")
        );
    }

    /// Lines of `input` as [`read_lines`] delivers them.
    fn lines_of(input: impl BufRead, limit: usize) -> Vec<String> {
        let mut out = Vec::new();
        read_lines(input, limit, |line| {
            out.push(line);
            true
        });
        out
    }

    /// An endless line, produced a chunk at a time: only a reader that
    /// drops what it cannot keep gets past it.
    struct Flood {
        left: usize,
        chunk: Vec<u8>,
        then: std::io::Cursor<Vec<u8>>,
    }

    impl std::io::Read for Flood {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            if self.left == 0 {
                return self.then.read(buf);
            }
            let n = buf.len().min(self.left).min(self.chunk.len());
            buf[..n].copy_from_slice(&self.chunk[..n]);
            self.left -= n;
            Ok(n)
        }
    }

    #[test]
    fn splits_stdin_lines() {
        let input: &[u8] = b"{\"a\":1}\n\nlast \xff";
        assert_eq!(lines_of(input, 64), ["{\"a\":1}", "", "last \u{fffd}"]);
        let exact = "x".repeat(16);
        assert_eq!(lines_of(format!("{exact}\n").as_bytes(), 16), [exact]);
        // The consumer is gone: reading stops.
        let mut seen = 0;
        read_lines(&b"a\nb\nc\n"[..], 64, |_| {
            seen += 1;
            false
        });
        assert_eq!(seen, 1);
    }

    #[test]
    fn drops_oversized_stdin_lines_without_buffering_them() {
        // 64 MiB without a newline against a 1 KiB limit, read through a
        // small buffer: the reader keeps no more than the limit.
        let flood = Flood {
            left: 64 * 1024 * 1024,
            chunk: vec![b'x'; 64 * 1024],
            then: std::io::Cursor::new(b"tail of it\n{\"type\":\"ok\"}\nyyyyyyyyyy".to_vec()),
        };
        let reader = std::io::BufReader::with_capacity(8 * 1024, flood);
        assert_eq!(
            lines_of(reader, 1024),
            [crate::rpc::LINE_TOO_LONG, "{\"type\":\"ok\"}", "yyyyyyyyyy"]
        );
        // Over the limit in its last chunk, and at the end of input.
        assert_eq!(
            lines_of(&b"12345\n123456\n1234567"[..], 5),
            [
                "12345",
                crate::rpc::LINE_TOO_LONG,
                crate::rpc::LINE_TOO_LONG
            ]
        );
    }

    #[tokio::test]
    async fn configure_errors() {
        let (sender, mut lines) = mpsc::unbounded_channel();
        for line in ["", "  ", "{not json"] {
            sender.send(line.to_owned()).unwrap();
        }
        assert_eq!(
            read_configure(&mut lines).await.err().as_deref(),
            Some("The first stdin line must be a JSON configure message")
        );
        drop(sender);
        assert_eq!(
            read_configure(&mut lines).await.err().as_deref(),
            Some("stdin closed before the configure message")
        );
    }
}
