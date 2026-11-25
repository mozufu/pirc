use std::fs;
use std::os::unix::fs::symlink;

use serde_json::json;

use super::*;
use crate::{PathGuard, read_allowed, write_allowed};

struct Layout {
    _dir: tempfile::TempDir,
    root: String,
    home: String,
    state: String,
    session: String,
    memory: String,
    socket: String,
    workspace: String,
    chat: String,
    tmp: String,
}

fn p(base: &str, rest: &str) -> String {
    format!("{base}/{rest}")
}

fn layout() -> Layout {
    let dir = tempfile::Builder::new()
        .prefix("pirc-policy-")
        .tempdir()
        .unwrap();
    let root = fs::canonicalize(dir.path()).unwrap().display().to_string();
    let home = p(&root, "home");
    let state = p(&root, "state");
    let d = Layout {
        session: p(&state, "sessions/pi_1"),
        memory: p(&state, "workspace-memory"),
        socket: p(&state, "i-abc/socket"),
        workspace: p(&root, "ws"),
        chat: p(&state, "chat/chats/sessions/s1"),
        tmp: p(&root, "tmp"),
        _dir: dir,
        root,
        home,
        state,
    };
    for dir in [
        &d.session,
        &d.memory,
        &p(&d.state, "i-abc"),
        &d.workspace,
        &d.chat,
        &d.tmp,
        &p(&d.home, ".ssh"),
        &p(&d.home, ".cache"),
    ] {
        fs::create_dir_all(dir).unwrap();
    }
    d
}

fn config(value: serde_json::Value) -> SandboxConfig {
    parse_sandbox_config(Some(&value)).unwrap()
}

fn input(d: &Layout, workspace_root: &str, config_value: serde_json::Value) -> SessionPolicyInput {
    SessionPolicyInput {
        config: config(config_value),
        config_dir: p(&d.root, "config"),
        home: d.home.clone(),
        private_dirs: vec![d.state.clone()],
        workspace_root: workspace_root.to_owned(),
        allowed_paths: Vec::new(),
        session_dir: d.session.clone(),
        workspace_memory_file: Some(p(&d.memory, "k.jsonl")),
        inference_socket: Some(d.socket.clone()),
        tmp_dirs: vec![d.tmp.clone()],
        protected_paths: Vec::new(),
        read_only_dirs: Vec::new(),
        platform: Platform::current(),
        uid: 1000,
        ssh_auth_sock: None,
    }
}

fn policy_for(d: &Layout, workspace_root: &str, config_value: serde_json::Value) -> SessionPolicy {
    session_policy(&input(d, workspace_root, config_value)).unwrap()
}

#[test]
fn hides_pirc_state_and_credentials_but_gives_the_session_its_own_directories_back() {
    let d = layout();
    fs::create_dir_all(p(&d.workspace, ".git/hooks")).unwrap();
    let SessionPolicy { paths, network, .. } = policy_for(&d, &d.workspace, json!({}));
    assert!(!read_allowed(&paths, &p(&d.state, "node.sqlite")));
    assert!(!read_allowed(&paths, &p(&d.state, "sessions/pi_2/x.jsonl")));
    assert!(read_allowed(&paths, &p(&d.session, "session.jsonl")));
    assert!(read_allowed(&paths, &p(&d.memory, "k.jsonl")));
    // Not another repository's ledger, nor a file beside the session's.
    assert!(!read_allowed(&paths, &p(&d.memory, "other.jsonl")));
    assert!(write_allowed(&paths, &p(&d.memory, "k.jsonl")));
    assert!(!write_allowed(&paths, &p(&d.memory, "other.jsonl")));
    assert!(!write_allowed(&paths, &p(&d.memory, "k.lock")));
    assert!(read_allowed(&paths, &d.socket));
    assert!(!read_allowed(&paths, &p(&d.home, ".ssh/id_ed25519")));
    assert!(read_allowed(&paths, &p(&d.home, "notes.md")));
    assert!(write_allowed(&paths, &p(&d.workspace, "src/a.ts")));
    assert!(!write_allowed(
        &paths,
        &p(&d.workspace, ".pirc/config.json")
    ));
    assert!(!write_allowed(
        &paths,
        &p(&d.workspace, ".git/hooks/pre-commit")
    ));
    assert!(!write_allowed(&paths, &p(&d.workspace, ".git/config")));
    assert!(write_allowed(&paths, &p(&d.workspace, ".git/index")));
    let git_config = policy_for(
        &d,
        &d.workspace,
        json!({ "filesystem": { "allowGitConfig": true } }),
    );
    assert!(write_allowed(
        &git_config.paths,
        &p(&d.workspace, ".git/config")
    ));
    assert!(!write_allowed(&paths, &p(&d.home, ".cache/bun/x")));
    assert!(!write_allowed(&paths, &p(&d.home, ".bashrc")));
    assert!(write_allowed(&paths, &p(&d.tmp, "x")));
    assert!(!write_allowed(&paths, &p(&d.state, "node.sqlite")));
    // Only temporary roots are shared; host build caches stay read-only.
    assert_eq!(
        paths.shared_write.as_deref().unwrap(),
        std::slice::from_ref(&d.tmp)
    );
    for domain in DEFAULT_ALLOWED_DOMAINS {
        assert!(network.allowed_domains.iter().any(|d| d == domain));
    }
    assert_eq!(network.allow_unix_sockets, std::slice::from_ref(&d.socket));
}

#[test]
fn a_temp_dir_in_a_private_parent_is_the_sessions_own() {
    let d = layout();
    // The node's private parent of every session's temp dir, inside a
    // shared write root (`/tmp`).
    let parent = p(&d.tmp, "pirc-n-abc");
    let (own, other) = (p(&parent, "pirc-1"), p(&parent, "pirc-2"));
    fs::create_dir_all(&own).unwrap();
    fs::create_dir_all(&other).unwrap();
    let mut input = input(&d, &d.workspace, json!({}));
    input.private_dirs.push(parent.clone());
    input.tmp_dirs = vec![own.clone(), d.tmp.clone()];
    let paths = session_policy(&input).unwrap().paths;
    assert!(read_allowed(&paths, &p(&own, "proxy.sock")));
    assert!(write_allowed(&paths, &p(&own, "x")));
    assert!(!read_allowed(&paths, &p(&other, "proxy.sock")));
    assert!(!write_allowed(&paths, &p(&other, "proxy.sock")));
    // As for the sessions directory: closed to reads (the sandboxes
    // mount an empty directory there), siblings closed to writes.
    assert!(!read_allowed(&paths, &p(&parent, "pirc-3")));
    assert!(write_allowed(&paths, &p(&d.tmp, "x")));
    // The shared root itself is not reopened.
    assert!(!paths.allow_read.contains(&d.tmp));
}

#[test]
fn takes_no_write_lease_for_shared_roots_the_innermost_root_otherwise() {
    let d = layout();
    let guard = PathGuard::with_home(
        &d.workspace,
        &policy_for(&d, &d.workspace, json!({})).paths,
        &[],
        &d.home,
    );
    assert_eq!(guard.lease_root(&p(&d.tmp, "x/y")), None);
    assert!(!write_allowed(
        &policy_for(&d, &d.workspace, json!({})).paths,
        &p(&d.home, ".cache/bun/x")
    ));
    assert_eq!(
        guard.lease_root(&p(&d.workspace, "src/a.ts")).as_deref(),
        Some(d.workspace.as_str())
    );
    // A workspace inside a shared root is still leased.
    let nested = p(&d.tmp, "ws");
    fs::create_dir(&nested).unwrap();
    let in_tmp = PathGuard::with_home(
        &nested,
        &policy_for(&d, &nested, json!({})).paths,
        &[],
        &d.home,
    );
    assert_eq!(
        in_tmp.lease_root(&p(&nested, "a.ts")).as_deref(),
        Some(nested.as_str())
    );
    assert_eq!(in_tmp.lease_root(&p(&d.tmp, "other")), None);
}

#[test]
fn lets_a_chat_session_work_in_its_directory_inside_the_nodes_state() {
    let d = layout();
    let paths = policy_for(&d, &d.chat, json!({})).paths;
    assert!(read_allowed(&paths, &p(&d.chat, "notes.md")));
    assert!(write_allowed(&paths, &p(&d.chat, "notes.md")));
    assert!(!read_allowed(
        &paths,
        &p(&d.state, "chat/chats/sessions/s2/x")
    ));
}

#[test]
fn never_lets_a_chat_session_touch_its_projects_instructions() {
    let d = layout();
    let instructions = p(&d.state, "chat/chats/instructions.md");
    let mut input = input(
        &d,
        &d.chat,
        json!({ "filesystem": { "allowWrite": [d.state] } }),
    );
    input.inference_socket = None;
    input.protected_paths = vec![instructions.clone()];
    let paths = session_policy(&input).unwrap().paths;
    assert!(!read_allowed(&paths, &instructions));
    assert!(!write_allowed(&paths, &instructions));
    assert!(write_allowed(&paths, &p(&d.chat, "notes.md")));
}

#[test]
fn protects_global_configuration_inside_writable_roots_including_absent_files() {
    let d = layout();
    let config_dir = p(&d.tmp, "config");
    fs::create_dir(&config_dir).unwrap();
    let mut input = input(&d, &d.workspace, json!({}));
    input.config_dir = config_dir.clone();
    input.allowed_paths = vec![d.root.clone()];
    input.inference_socket = None;
    let paths = session_policy(&input).unwrap().paths;
    assert!(read_allowed(&paths, &p(&config_dir, "config.json")));
    assert!(!write_allowed(&paths, &p(&config_dir, "config.json")));
    assert!(write_allowed(&paths, &p(&d.tmp, "ordinary.txt")));
}

#[test]
fn protects_mode_sources_and_dangling_targets_without_reading_contents() {
    let d = layout();
    let input = input(&d, &d.workspace, json!({}));
    let modes = p(&input.config_dir, "modes");
    fs::create_dir_all(&modes).unwrap();
    let source = p(&d.workspace, "source.txt");
    // Invalid UTF-8 and invalid mode syntax must not affect policy creation.
    fs::write(&source, [0xff, 0xfe]).unwrap();
    let hop = p(&d.workspace, "hop");
    symlink(&source, &hop).unwrap();
    let mode = p(&modes, "chat.md");
    symlink(&hop, &mode).unwrap();
    let dangling = p(&d.workspace, "missing/source.md");
    let dangling_hop = p(&d.workspace, "dangling-hop");
    symlink(&dangling, &dangling_hop).unwrap();
    symlink(&dangling_hop, p(&modes, "future.md")).unwrap();
    // The catalog loader ignores non-Markdown entries, even link cycles.
    symlink("ignored.txt", p(&modes, "ignored.txt")).unwrap();
    let policy = session_policy(&input).unwrap();
    let guard = crate::PathGuard::new(&d.workspace, &policy.paths, &[]);
    for path in [&source, &hop, &mode, &dangling, &dangling_hop] {
        assert!(guard.resolve(path, true).is_err(), "{path}");
    }
    for path in [&source, &dangling] {
        assert!(!write_allowed(&policy.paths, path), "{path}");
        assert!(policy.paths.deny_write.contains(path), "{path}");
    }
    let linked = policy
        .linked_denies
        .iter()
        .find(|entry| entry.spelled == mode)
        .unwrap();
    assert_eq!(linked.links, [mode, hop]);
    assert!(write_allowed(&policy.paths, &p(&d.workspace, "notes.md")));
}

#[test]
fn protects_symlinked_mode_directories_including_dangling_ones() {
    for present in [false, true] {
        let d = layout();
        let input = input(&d, &d.workspace, json!({}));
        fs::create_dir_all(&input.config_dir).unwrap();
        let catalog = p(&d.workspace, "catalog");
        let modes = p(&input.config_dir, "modes");
        symlink(&catalog, &modes).unwrap();
        let source = p(&d.workspace, "external-source.md");
        if present {
            fs::create_dir(&catalog).unwrap();
            fs::write(&source, "invalid mode").unwrap();
            symlink(&source, p(&catalog, "chat.md")).unwrap();
        }
        let policy = session_policy(&input).unwrap();
        assert!(!write_allowed(&policy.paths, &p(&catalog, "new.md")));
        assert!(policy.paths.deny_write.contains(&catalog));
        assert!(
            policy
                .linked_denies
                .iter()
                .any(|entry| { entry.spelled == modes && entry.links.contains(&modes) })
        );
        if present {
            assert!(!write_allowed(&policy.paths, &source));
        }
    }
}

#[test]
fn mode_source_targets_follow_kernel_symlink_parent_order() {
    let d = layout();
    let input = input(&d, &d.workspace, json!({}));
    let modes = p(&input.config_dir, "modes");
    fs::create_dir_all(&modes).unwrap();
    fs::create_dir_all(p(&d.workspace, "real/sub")).unwrap();
    symlink("real/sub", p(&d.workspace, "alias")).unwrap();
    symlink(p(&d.workspace, "alias/../source.md"), p(&modes, "chat.md")).unwrap();
    let target = p(&d.workspace, "real/source.md");
    let paths = session_policy(&input).unwrap().paths;
    assert!(!write_allowed(&paths, &target));
    assert!(paths.deny_write.contains(&target));
    assert!(write_allowed(&paths, &p(&d.workspace, "source.md")));
}

#[test]
fn mode_configuration_cycles_and_non_directory_catalogs_fail_closed() {
    for directory in [false, true] {
        let d = layout();
        let input = input(&d, &d.workspace, json!({}));
        fs::create_dir_all(&input.config_dir).unwrap();
        let modes = p(&input.config_dir, "modes");
        if directory {
            symlink("modes", &modes).unwrap();
        } else {
            fs::create_dir(&modes).unwrap();
            symlink("chat.md", p(&modes, "chat.md")).unwrap();
        }
        let error = session_policy(&input).unwrap_err();
        assert!(error.starts_with(MODE_PATHS_ERROR), "{error}");
    }
    let d = layout();
    fs::create_dir_all(p(&d.root, "config")).unwrap();
    fs::write(p(&d.root, "config/modes"), "not a directory").unwrap();
    let error = session_policy(&input(&d, &d.workspace, json!({}))).unwrap_err();
    assert!(error.starts_with(MODE_PATHS_ERROR), "{error}");
}

#[test]
fn walks_links_as_the_kernel_does() {
    let d = layout();
    let r = |rest: &str| p(&d.root, rest);
    fs::create_dir_all(r("real/sub")).unwrap();
    fs::create_dir_all(r("other")).unwrap();
    symlink(r("real"), r("abs")).unwrap();
    symlink("hop", r("rel")).unwrap();
    symlink("real/sub", r("hop")).unwrap();
    // `..` from the link's target, not from the link's spelling.
    symlink("real/sub/../../other", r("up")).unwrap();
    symlink("nowhere/x", r("dangling")).unwrap();
    symlink("loop", r("loop")).unwrap();
    let walk = walk_links(&r("abs/sub/missing/file"));
    assert_eq!(walk.links, [r("abs")]);
    assert_eq!(walk.target, Ok(r("real/sub/missing/file")));
    let walk = walk_links(&r("rel/f"));
    assert_eq!(walk.links, [r("rel"), r("hop")]);
    assert_eq!(walk.target, Ok(r("real/sub/f")));
    let walk = walk_links(&r("up"));
    assert_eq!(walk.links, [r("up"), r("real/sub"), r("real")]);
    assert_eq!(walk.target, Ok(r("other")));
    let walk = walk_links(&r("dangling"));
    assert_eq!(walk.links, [r("dangling")]);
    assert_eq!(walk.target, Ok(r("nowhere/x")));
    let walk = walk_links(&r("loop/x"));
    assert_eq!(walk.links, [r("loop")]);
    assert_eq!(walk.target, Err(WalkError::TooManyLinks));
    let walk = walk_links(&r("real/sub"));
    assert!(walk.links.is_empty());
    assert_eq!(walk.target, Ok(r("real/sub")));
    assert_eq!(linked_path(&r("real")), None);
}

/// `~/.ssh` linking out of the home directory is denied by its target,
/// which leaves the link replaceable under a writable `~`: the policy
/// lists it (and every other linked deny spelling) without changing
/// what it passes to srt or to the agent.
#[test]
fn lists_the_links_of_linked_deny_entries_without_serializing_them() {
    let d = layout();
    let r = |rest: &str| p(&d.root, rest);
    fs::create_dir_all(r("outside/ssh")).unwrap();
    fs::create_dir_all(r("outside/secrets")).unwrap();
    fs::create_dir_all(r("outside/bin")).unwrap();
    fs::remove_dir(p(&d.home, ".ssh")).unwrap();
    symlink(r("outside/ssh"), p(&d.home, ".ssh")).unwrap();
    // A chain: ~/.aws -> ~/hop -> outside/aws (relative hop).
    fs::create_dir_all(r("outside/aws")).unwrap();
    symlink(r("outside/aws"), p(&d.home, "hop")).unwrap();
    symlink("hop", p(&d.home, ".aws")).unwrap();
    symlink(r("state"), r("state-link")).unwrap();
    symlink(r("outside/bin"), r("bin-link")).unwrap();
    symlink(r("outside/secrets"), p(&d.home, "secrets")).unwrap();
    let notes = p(&d.workspace, "AGENTS.md");
    fs::write(r("outside/AGENTS.md"), "").unwrap();
    symlink(r("outside/AGENTS.md"), &notes).unwrap();
    let mut input = input(
        &d,
        &d.workspace,
        json!({ "filesystem": { "denyRead": ["~/secrets"] } }),
    );
    input.allowed_paths = vec![d.home.clone()];
    input.private_dirs = vec![r("state-link")];
    input.read_only_dirs = vec![r("bin-link")];
    input.protected_paths = vec![notes.clone()];
    let policy = session_policy(&input).unwrap();
    let linked = |spelled: &str| {
        policy
            .linked_denies
            .iter()
            .find(|entry| entry.spelled == spelled)
            .unwrap_or_else(|| panic!("{spelled}: {:#?}", policy.linked_denies))
            .clone()
    };
    let ssh = linked(&p(&d.home, ".ssh"));
    assert_eq!(ssh.links, [p(&d.home, ".ssh")]);
    assert_eq!(ssh.target, r("outside/ssh"));
    let aws = linked(&p(&d.home, ".aws"));
    assert_eq!(aws.links, [p(&d.home, ".aws"), p(&d.home, "hop")]);
    assert_eq!(aws.target, r("outside/aws"));
    assert_eq!(linked(&r("state-link")).links, [r("state-link")]);
    assert_eq!(linked(&r("bin-link")).links, [r("bin-link")]);
    assert_eq!(linked(&notes).links, std::slice::from_ref(&notes));
    assert_eq!(linked(&p(&d.home, "secrets")).target, r("outside/secrets"));
    assert!(
        policy
            .linked_denies
            .iter()
            .all(|entry| entry.spelled != d.workspace),
        "allows are not listed"
    );
    // The lists srt and the agent get name targets only, as before.
    assert!(policy.paths.deny_read.contains(&r("outside/ssh")));
    assert!(!policy.paths.deny_read.contains(&p(&d.home, ".ssh")));
    let json = serde_json::to_value(&policy).unwrap();
    let mut keys: Vec<&String> = json.as_object().unwrap().keys().collect();
    keys.sort();
    assert_eq!(keys, ["allowGitConfig", "network", "paths"]);
    assert!(!json.to_string().contains("hop"));
    let back: SessionPolicy = serde_json::from_value(json).unwrap();
    assert!(back.linked_denies.is_empty());
    // Nothing linked, nothing listed.
    let plain = layout();
    assert_eq!(
        policy_for(&plain, &plain.workspace, json!({})).linked_denies,
        []
    );
}

#[test]
fn keeps_a_deny_inside_an_allowed_region_and_takes_configured_additions() {
    let d = layout();
    let SessionPolicy {
        paths,
        network,
        allow_git_config,
        ..
    } = policy_for(
        &d,
        &d.workspace,
        json!({
            "network": { "defaultDomains": false, "allowedDomains": ["api.example.com", "127.0.0.1:8080"] },
            "filesystem": { "denyRead": ["~/private"], "allowWrite": ["~/out"], "allowGitConfig": true },
        }),
    );
    assert!(!read_allowed(&paths, &p(&d.home, "private/x")));
    assert!(write_allowed(&paths, &p(&d.home, "out/x")));
    assert_eq!(
        network.allowed_domains,
        ["api.example.com", "127.0.0.1:8080"]
    );
    assert!(allow_git_config);
    // A workspace inside $HOME does not re-open credentials under it.
    let in_home = policy_for(&d, &d.home, json!({})).paths;
    assert!(!read_allowed(&in_home, &p(&d.home, ".ssh/id_ed25519")));
}

#[test]
fn keeps_the_nodes_state_and_credentials_unwritable_even_inside_a_writable_root() {
    let d = layout();
    // Development layout: the node's state lives inside the workspace.
    let workspace = d.root.clone();
    fs::write(p(&d.state, "node.sqlite"), "").unwrap();
    fs::create_dir_all(p(&d.state, "sandbox/bin")).unwrap();
    // Only what exists now: the node warns that later entries are open.
    fs::create_dir_all(p(&d.state, "sessions/pi_2")).unwrap();
    // The session's ledger (the node makes it) and another repository's.
    fs::write(p(&d.memory, "k.jsonl"), "").unwrap();
    fs::write(p(&d.memory, "other.jsonl"), "").unwrap();
    let mut input = input(&d, &workspace, json!({}));
    input.allowed_paths = vec![d.home.clone()];
    input.inference_socket = None;
    input.read_only_dirs = vec![p(&d.state, "sandbox/bin")];
    let paths = session_policy(&input).unwrap().paths;
    assert!(write_allowed(&paths, &p(&workspace, "src/a.ts")));
    assert!(!write_allowed(&paths, &p(&d.state, "node.sqlite")));
    assert!(!write_allowed(
        &paths,
        &p(&d.state, "sessions/pi_2/x.jsonl")
    ));
    assert!(write_allowed(&paths, &p(&d.session, "session.jsonl")));
    assert!(write_allowed(&paths, &p(&d.memory, "k.jsonl")));
    assert!(!write_allowed(&paths, &p(&d.memory, "other.jsonl")));
    assert!(!write_allowed(
        &paths,
        &p(&d.state, "sandbox/bin/apply-seccomp")
    ));
    assert!(read_allowed(
        &paths,
        &p(&d.state, "sandbox/bin/apply-seccomp")
    ));
    assert!(!read_allowed(&paths, &p(&d.state, "sandbox/other.json")));
    // `~` in allowedPaths does not open credential stores.
    assert!(!write_allowed(&paths, &p(&d.home, ".ssh/authorized_keys")));
    assert!(write_allowed(&paths, &p(&d.home, "notes.md")));
}

#[test]
fn deny_write_around_closes_everything_but_the_way_to_kept_paths() {
    let d = layout();
    fs::write(p(&d.state, "node.sqlite"), "").unwrap();
    let mut denied = deny_write_around(&d.state, &[d.session.clone(), d.memory.clone()]);
    denied.sort();
    let mut expected = vec![
        p(&d.state, "chat"),
        p(&d.state, "i-abc"),
        p(&d.state, "node.sqlite"),
    ];
    expected.sort();
    assert_eq!(denied, expected);
    assert_eq!(
        deny_write_around(&d.state, std::slice::from_ref(&d.state)),
        Vec::<String>::new()
    );
    assert_eq!(
        deny_write_around(&d.state, std::slice::from_ref(&d.workspace)),
        std::slice::from_ref(&d.state)
    );
}

#[test]
fn hides_host_sockets_from_linux_sandboxes() {
    let d = layout();
    let agent_socket = p(&d.root, "ssh-agent.sock");
    fs::write(&agent_socket, "").unwrap();
    let mut linux = input(&d, &d.workspace, json!({}));
    linux.inference_socket = None;
    linux.ssh_auth_sock = Some(agent_socket.clone());
    linux.platform = Platform::Linux;
    let mut mac = linux.clone();
    mac.platform = Platform::Macos;
    assert!(!read_allowed(
        &session_policy(&linux).unwrap().paths,
        &agent_socket
    ));
    assert!(read_allowed(
        &session_policy(&mac).unwrap().paths,
        &agent_socket
    ));
    // `allowUnixSockets` leaves a host socket visible, even inside a
    // hidden directory.
    let in_private = p(&d.state, "agent.sock");
    fs::write(&in_private, "").unwrap();
    let mut inside = input(
        &d,
        &d.workspace,
        json!({ "network": { "allowUnixSockets": [in_private] } }),
    );
    inside.platform = Platform::Linux;
    let inside_paths = session_policy(&inside).unwrap().paths;
    assert!(read_allowed(&inside_paths, &in_private));
    assert!(!read_allowed(&inside_paths, &p(&d.state, "node.sqlite")));
    let mut allowed = input(
        &d,
        &d.workspace,
        json!({ "network": { "allowUnixSockets": [agent_socket] } }),
    );
    allowed.inference_socket = None;
    allowed.ssh_auth_sock = Some(agent_socket.clone());
    allowed.platform = Platform::Linux;
    assert!(read_allowed(
        &session_policy(&allowed).unwrap().paths,
        &agent_socket
    ));
}

#[test]
fn accepts_hosts_wildcards_ports_and_ipv4_addresses_only() {
    for ok in [
        "github.com",
        "*.github.com",
        "api.example.com:443",
        "localhost:3000",
        "127.0.0.1:8080",
    ] {
        assert!(valid_domain(ok), "{ok}");
    }
    for bad in [
        "*",
        "http://github.com",
        "github.com/path",
        "*.com.",
        "a b.com",
        "",
    ] {
        assert!(!valid_domain(bad), "{bad}");
    }
    // Recorded from DOMAIN_PATTERN.test in the TS build.
    let long = |n: usize| format!("a.{}.com", "b".repeat(n));
    for (domain, expected) in [
        ("API.Example.COM:443", true),
        ("localhost", true),
        ("*.localhost:1", true),
        ("1.2.3.4", true),
        ("999.1.1.1:99999", true),
        ("a.b", false),
        ("a.co", true),
        ("a-.com", false),
        ("-a.com", false),
        ("x.c0m", false),
        ("xn--abc.com", true),
        ("a..com", false),
        ("*.*.com", false),
        ("localhost.com", true),
        (&long(63), true),
        (&long(64), false),
        ("a.com:123456", false),
        ("a.com:", false),
        ("1.2.3.4.5", false),
        ("*.1.2.3.4", false),
        ("café.com", false),
        ("a_b.com", false),
        ("a.com\n", false),
        ("\u{17f}.com", false),
    ] {
        assert_eq!(valid_domain(domain), expected, "{domain:?}");
    }
}

/// Every problem in a `sandbox` section is reported, as `<path>: <message>`
/// joined with "; " (what `readAgentConfig` shows).
#[test]
fn reports_every_schema_issue() {
    let defaults = SandboxConfig::default();
    assert_eq!(parse_sandbox_config(None).unwrap(), defaults);
    assert_eq!(parse_sandbox_config(Some(&json!({}))).unwrap(), defaults);
    assert!(defaults.network.default_domains && defaults.network.allow_local_binding);
    for (value, expected) in [
        (json!(null), "sandbox: Expected object, received null"),
        (json!("x"), "sandbox: Expected object, received string"),
        (json!([]), "sandbox: Expected object, received array"),
        (json!(5), "sandbox: Expected object, received number"),
        (
            json!({ "network": { "allowedDomains": ["not a host"] } }),
            "sandbox.network.allowedDomains.0: Invalid domain",
        ),
        (
            json!({ "network": { "allowedDomains": ["ok.com", 5, ""] } }),
            "sandbox.network.allowedDomains.1: Expected string, received number; sandbox.network.allowedDomains.2: Invalid domain",
        ),
        (
            json!({ "network": { "allowedDomains": "github.com" } }),
            "sandbox.network.allowedDomains: Expected array, received string",
        ),
        (
            json!({ "network": { "defaultDomains": "yes", "allowLocalBinding": null } }),
            "sandbox.network.defaultDomains: Expected boolean, received string; sandbox.network.allowLocalBinding: Expected boolean, received null",
        ),
        (
            json!({ "network": { "allowUnixSockets": [""] } }),
            "sandbox.network.allowUnixSockets.0: Expected a non-empty string",
        ),
        (
            json!({ "network": null }),
            "sandbox.network: Expected object, received null",
        ),
        (
            json!({ "network": [] }),
            "sandbox.network: Expected object, received array",
        ),
        (
            json!({ "filesystem": { "denyRead": [1], "allowGitConfig": 1 } }),
            "sandbox.filesystem.denyRead.0: Expected string, received number; sandbox.filesystem.allowGitConfig: Expected boolean, received number",
        ),
        (
            json!({ "extra": 1, "network": { "bogus": true, "also": 2, "allowedDomains": ["x"] }, "more": 2 }),
            "sandbox.network.allowedDomains.0: Invalid domain; sandbox.network: Unknown key(s): 'bogus', 'also'; sandbox: Unknown key(s): 'extra', 'more'",
        ),
        (
            json!({ "filesystem": { "denyWrite": [""], "nope": 1 }, "network": { "deniedDomains": ["a b"] } }),
            "sandbox.network.deniedDomains.0: Invalid domain; sandbox.filesystem.denyWrite.0: Expected a non-empty string; sandbox.filesystem: Unknown key(s): 'nope'",
        ),
        (
            json!({ "network": { "allowedDomains": [{}, true] } }),
            "sandbox.network.allowedDomains.0: Expected string, received object; sandbox.network.allowedDomains.1: Expected string, received boolean",
        ),
        (
            json!({ "enabled": true }),
            "sandbox: Unknown key(s): 'enabled'",
        ),
        // Unknown keys are listed in file order.
        (
            json!({ "b": 1, "10": 1, "2": 1, "01": 1 }),
            "sandbox: Unknown key(s): 'b', '10', '2', '01'",
        ),
    ] {
        assert_eq!(
            parse_sandbox_config(Some(&value)).unwrap_err(),
            expected,
            "{value}"
        );
    }
}

#[test]
fn keeps_the_defaults_and_reports_a_mistake_instead_of_loosening_anything() {
    let dir = tempfile::tempdir().unwrap();
    let config_dir = dir.path().display().to_string();
    fs::write(
            p(&config_dir, "config.json"),
            json!({ "allowedPaths": ["~/extra", 5, "rel"], "sandbox": { "network": { "allowedDomains": ["not a host"] } } })
                .to_string(),
        )
        .unwrap();
    let view = read_agent_config(&config_dir, "/home/u");
    let problem = view.problem.unwrap();
    assert!(problem.contains("network.allowedDomains"), "{problem}");
    assert!(problem.starts_with(&format!("{config_dir}/config.json: invalid \"sandbox\": ")));
    assert!(view.sandbox.network.default_domains);
    assert!(view.sandbox.network.allowed_domains.is_empty());
    assert_eq!(
        view.allowed_paths,
        ["/home/u/extra".to_owned(), p(&config_dir, "rel")]
    );
}

#[test]
fn drops_the_removed_sandbox_enabled_switch_and_says_so_when_it_was_off() {
    let dir = tempfile::tempdir().unwrap();
    let config_dir = dir.path().display().to_string();
    let file = p(&config_dir, "config.json");
    fs::write(
            &file,
            json!({ "sandbox": { "enabled": false, "network": { "allowedDomains": ["api.example.com"] } } })
                .to_string(),
        )
        .unwrap();
    let view = read_agent_config(&config_dir, "/home/u");
    assert!(view.problem.unwrap().contains("sandbox.enabled"));
    assert_eq!(view.sandbox.network.allowed_domains, ["api.example.com"]);
    fs::write(&file, json!({ "sandbox": { "enabled": true } }).to_string()).unwrap();
    assert_eq!(read_agent_config(&config_dir, "/home/u").problem, None);
    // Missing, unreadable and malformed files.
    fs::remove_file(&file).unwrap();
    let missing = read_agent_config(&config_dir, "/home/u");
    assert_eq!(missing.problem, None);
    assert_eq!(missing.sandbox, SandboxConfig::default());
    fs::write(&file, "{nope").unwrap();
    let malformed = read_agent_config(&config_dir, "/home/u");
    assert!(malformed.problem.unwrap().starts_with(&format!("{file}: ")));
    fs::write(&file, "[1]").unwrap();
    assert_eq!(read_agent_config(&config_dir, "/home/u").problem, None);
}
#[test]
fn host_caches_stay_readonly_under_broad_home_grants() {
    let d = layout();
    let policy = policy_for(
        &d,
        &d.workspace,
        json!({"filesystem":{"allowWrite":[d.home]}}),
    );
    for relative in CACHE_HOME_PATHS {
        let file = p(&p(&d.home, relative), "future-code");
        assert!(!write_allowed(&policy.paths, &file), "{relative}");
        assert!(
            !policy
                .paths
                .shared_write
                .as_ref()
                .unwrap()
                .contains(&p(&d.home, relative))
        );
    }
}

#[test]
fn missing_git_directory_and_worktree_pointer_do_not_create_child_denies() {
    let d = layout();
    for worktree in [false, true] {
        if worktree {
            fs::write(p(&d.workspace, ".git"), "gitdir: /some/repository").unwrap();
        }
        let policy = policy_for(&d, &d.workspace, json!({}));
        assert!(
            !policy
                .paths
                .deny_write
                .iter()
                .any(|path| is_inside(path, &p(&d.workspace, ".git")))
        );
        assert!(write_allowed(
            &policy.paths,
            &p(&d.workspace, ".git/config")
        ));
    }
}

#[test]
fn detects_windows_profiles_only_on_wsl_and_keeps_workspace_exceptions() {
    let d = layout();
    let mounts = Path::new(&d.root).join("mnt");
    for name in [
        "c/Users/alice/AppData",
        "D/Users/bob",
        "not-a-drive/Users/ignored",
        "e/tools",
    ] {
        fs::create_dir_all(mounts.join(name)).unwrap();
    }
    assert!(wsl_user_dirs(&mounts, "6.18.0-generic").unwrap().is_empty());
    let users = wsl_user_dirs(&mounts, "6.18.0-Microsoft-standard-WSL2").unwrap();
    assert_eq!(users.len(), 2);
    let workspace = mounts.join("c/Users/alice/project");
    fs::create_dir(&workspace).unwrap();
    let mut input = input(&d, workspace.to_str().unwrap(), json!({}));
    input.private_dirs.extend(users);
    let policy = session_policy(&input).unwrap();
    assert!(read_allowed(
        &policy.paths,
        &workspace.join("main.rs").display().to_string()
    ));
    assert!(!read_allowed(
        &policy.paths,
        &mounts
            .join("c/Users/alice/AppData/token")
            .display()
            .to_string()
    ));
    assert!(!read_allowed(
        &policy.paths,
        &mounts.join("D/Users/bob/secret").display().to_string()
    ));
}
