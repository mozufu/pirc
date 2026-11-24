//! Same-account coding/chat nodes: actual native confinement, not just lists.
#![cfg(any(target_os = "linux", target_os = "macos"))]

use pirc_config::{Env, NodeConfig};
use pirc_node::sandbox::{PrepareInput, Prepared, ReadonlyInput, Sandbox, SandboxStatus};
use pirc_policy::{read_allowed, real_resolve, write_allowed};
use pirc_protocol::NodeRole;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

fn native(config: &NodeConfig, env: &Env) -> Arc<dyn Sandbox> {
    #[cfg(target_os = "macos")]
    {
        Arc::new(pirc_node::sandbox::macos::MacSandbox::new(
            config.clone(),
            env.clone(),
        ))
    }
    #[cfg(target_os = "linux")]
    {
        Arc::new(pirc_node::sandbox::linux::NativeSandbox::new(
            config.clone(),
            env.clone(),
            PathBuf::from(env!("CARGO_BIN_EXE_pirc-node")),
        ))
    }
}
fn config(root: &Path, home: &Path, tmp: &Path, id: &str, role: NodeRole) -> (NodeConfig, Env) {
    let state = root.join("states").join(id);
    let settings = root.join(format!("config-{id}"));
    fs::create_dir_all(&settings).unwrap();
    // The explicit parent deny must not prevent the session's own writes.
    fs::write(
        settings.join("config.json"),
        serde_json::json!({
            "allowedPaths": [home], "sandbox": {"filesystem": {"denyRead": [root.join("states")]}}
        })
        .to_string(),
    )
    .unwrap();
    let env = Env::new(
        [
            ("HOME", home.to_str().unwrap()),
            ("TMPDIR", tmp.to_str().unwrap()),
            ("PIRC_NODE_ID", id),
            ("PIRC_NODE_TOKEN", "0123456789abcdef0123456789abcdef"),
            ("PIRC_DAEMON_URL", "ws://127.0.0.1:8787"),
            ("PIRC_ALLOWED_USERS", "test-user"),
            ("PIRC_STATE_DIR", state.to_str().unwrap()),
            ("PIRC_CONFIG_DIR", settings.to_str().unwrap()),
            ("PIRC_BROWSER", "false"),
            ("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        ],
        root,
    );
    let mut config = NodeConfig::load(&env, role).unwrap();
    config.agent_command = "/bin/sh".into();
    config.agent_args.clear();
    pirc_config::registry::register_node(&config, &env, None).unwrap();
    (config, env)
}
async fn prepare(sandbox: &dyn Sandbox, config: &NodeConfig, cwd: &Path, id: &str) -> Prepared {
    let session = config.sessions_dir.join(id);
    fs::create_dir_all(&session).unwrap();
    sandbox
        .prepare(PrepareInput {
            grants: Vec::new(),
            session_id: id.into(),
            workspace_root: cwd.to_path_buf(),
            session_dir: session,
            inference_socket: None,
            protected_paths: Vec::new(),
            workspace_memory_file: None,
            project_files_dir: None,
            recovery: None,
        })
        .await
        .unwrap()
}
fn tmp(prepared: &Prepared) -> PathBuf {
    PathBuf::from(
        &prepared
            .env
            .iter()
            .find(|(name, _)| name == "CLAUDE_CODE_TMPDIR")
            .unwrap()
            .1,
    )
}
fn quote(path: &Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "'\\''"))
}
async fn run(prepared: &Prepared, cwd: &Path, script: &str) {
    let mut command = prepared.command().unwrap();
    command
        .args(["-c", script])
        .env_clear()
        .env("PATH", "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        .envs(prepared.env.iter().map(|(k, v)| (k, v)))
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let output = tokio::time::timeout(Duration::from_secs(20), command.output())
        .await
        .unwrap()
        .unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[tokio::test]
async fn isolates_registered_nodes_gateway_and_tmp_without_breaking_own_state() {
    #[cfg(target_os = "linux")]
    if pirc_node::sandbox::linux::find_bwrap(&Env::from_process()).is_none() {
        eprintln!("skipped: bubblewrap unavailable; native Linux registry enforcement not tested");
        return;
    }
    let root = tempfile::Builder::new()
        .prefix("registry-")
        .tempdir_in(env!("CARGO_TARGET_TMPDIR"))
        .unwrap();
    let root = fs::canonicalize(root.path()).unwrap();
    let short_tmp = tempfile::Builder::new()
        .prefix("pr-")
        .tempdir_in("/tmp")
        .unwrap();
    let home = root.join("home");
    fs::create_dir(&home).unwrap();
    let a_cwd = root.join("workspace");
    fs::create_dir(&a_cwd).unwrap();
    let (a, a_env) = config(&root, &home, short_tmp.path(), "coding", NodeRole::Node);
    let (b, b_env) = config(&root, &home, short_tmp.path(), "chat", NodeRole::Chat);
    let b_cwd = b.state_dir.join("chat/project");
    fs::create_dir_all(&b_cwd).unwrap();
    let gateway = root.join("gateway");
    fs::create_dir(&gateway).unwrap();
    let gateway_env = Env::new(
        [
            ("HOME", home.to_str().unwrap()),
            ("PIRC_STATE_DIR", gateway.to_str().unwrap()),
            (
                "PIRC_NODE_TOKENS",
                r#"{"coding":"0123456789abcdef0123456789abcdef"}"#,
            ),
            ("PIRC_TRUSTED_PROXIES", "127.0.0.1"),
            ("PIRC_PROXY_SECRET_REQUIRED", "false"),
            ("PIRC_ALLOWED_USERS", "test-user"),
            ("PIRC_ALLOWED_ORIGINS", "https://pirc.example"),
            ("PIRC_ALLOWED_HOSTS", "pirc.example"),
            ("PIRC_TIMEZONE", "UTC"),
        ],
        &root,
    );
    let gateway_config = pirc_config::GatewayConfig::load(&gateway_env).unwrap();
    pirc_config::registry::register_gateway(&gateway_config, &gateway_env).unwrap();
    let cache_files = [
        home.join(".cargo/registry/src/fake/build.rs"),
        home.join(".cache/ms-playwright/chromium/chrome"),
        home.join(".bun/install/cache/package/script"),
    ];
    for path in &cache_files {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, "trusted-cache").unwrap();
    }
    let a_sandbox = native(&a, &a_env);
    let b_sandbox = native(&b, &b_env);
    assert!(matches!(
        a_sandbox.check().await,
        SandboxStatus::Active { .. }
    ));
    assert!(matches!(
        b_sandbox.check().await,
        SandboxStatus::Active { .. }
    ));
    // Allocate both registered parents before the tested policies are built.
    let early = prepare(a_sandbox.as_ref(), &a, &a_cwd, "early").await;
    let b_run = prepare(b_sandbox.as_ref(), &b, &b_cwd, "b").await;
    let a_run = prepare(a_sandbox.as_ref(), &a, &a_cwd, "a").await;
    let registry_file = fs::read_dir(home.join(".local/pirc-node/nodes"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .find(|p| p.extension().is_some_and(|e| e == "json"))
        .unwrap();
    let b_files = [
        b.sessions_dir.join("b/session.jsonl"),
        b.uploads_dir.join("file"),
        b.browser.profiles_dir.join("cookies"),
        b.workspace_memory_dir.join("ledger.jsonl"),
        b_cwd.join("project-secret"),
        tmp(&b_run).join("secret"),
        gateway.join("backends/settings.json"),
        registry_file,
    ];
    for path in &b_files[..b_files.len() - 1] {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, "synthetic-secret").unwrap();
    }
    let originals: Vec<_> = b_files.iter().map(|path| fs::read(path).unwrap()).collect();
    let a_file = a.sessions_dir.join("a/session.jsonl");
    fs::write(&a_file, "own").unwrap();
    let mut script = String::from("set -eu\n");
    for file in &b_files {
        let resolved = real_resolve(&file.display().to_string());
        assert!(
            !read_allowed(&a_run.policy.paths, &resolved),
            "{}",
            file.display()
        );
        assert!(
            !write_allowed(&a_run.policy.paths, &resolved),
            "{}",
            file.display()
        );
        script.push_str(&format!(
            "if cat {} >/dev/null 2>&1; then echo 'peer read allowed'; exit 91; fi\n",
            quote(file)
        ));
        script.push_str(&format!(
            "if (printf changed >{}) 2>/dev/null; then echo 'peer write allowed'; exit 92; fi\n",
            quote(file)
        ));
    }
    script.push_str(&format!("if (printf new >{}) 2>/dev/null; then exit 93; fi\nprintf appended >>{}\nprintf own >\"$TMPDIR/own\"\n", quote(&tmp(&b_run).join("new-file")),quote(&a_file)));
    for path in &cache_files {
        let resolved = real_resolve(&path.display().to_string());
        assert!(read_allowed(&a_run.policy.paths, &resolved));
        assert!(!write_allowed(&a_run.policy.paths, &resolved));
        script.push_str(&format!(
            "cat {} >/dev/null; if (printf poisoned >{}) 2>/dev/null; then exit 97; fi\n",
            quote(path),
            quote(path)
        ));
    }
    script.push_str("mkdir -p \"$CARGO_HOME\" \"$XDG_CACHE_HOME\" \"$BUN_INSTALL_CACHE_DIR\"; printf own >\"$CARGO_HOME/probe\"; printf own >\"$XDG_CACHE_HOME/probe\"; printf own >\"$BUN_INSTALL_CACHE_DIR/probe\"\n");
    script.push_str("git init -q; git rev-parse --git-dir >/dev/null\n");
    run(&a_run, &a_cwd, &script).await;
    assert_eq!(fs::read_to_string(&a_file).unwrap(), "ownappended");
    for (file, original) in b_files.iter().zip(originals) {
        assert_eq!(fs::read(file).unwrap(), original);
    }
    run(&b_run,&b_cwd,&format!("set -eu; if cat {} >/dev/null 2>&1; then exit 94; fi; if (printf bad >{}) 2>/dev/null; then exit 95; fi; printf own > local",quote(&a_file),quote(&tmp(&a_run).join("new")))).await;
    // Read-only panel commands use the same registry snapshot.
    let readonly = a_sandbox
        .prepare_readonly(ReadonlyInput {
            workspace_root: a_cwd.clone(),
            command: vec!["/bin/sh".into()],
        })
        .await
        .unwrap();
    run(
        &readonly,
        &a_cwd,
        &format!(
            "if cat {} >/dev/null 2>&1; then exit 96; fi",
            quote(&b_files[0])
        ),
    )
    .await;
    readonly.cleanup();
    a_run.cleanup();
    b_run.cleanup();
    early.cleanup();
}
