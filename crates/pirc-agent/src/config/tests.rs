//! Ports of the config side of `agent-project-trust.test.ts`,
//! `agent-core.test.ts`, `assistant-prompts.test.ts`,
//! `agent-project-instructions.test.ts` and `memory-config.test.ts`, with
//! golden values recorded from the TS agent.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::*;
use crate::context::join_prompt;

fn env_of(vars: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> + use<> {
    let vars: Vec<(String, String)> = vars
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect();
    move |name: &str| {
        vars.iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.clone())
    }
}

fn models() -> Models {
    serde_json::from_value(json!({"providers": {
        "fake": {"api": "openai-completions", "baseUrl": "http://127.0.0.1:1/v1",
                 "models": [{"id": "fake-model"}]},
        "other": {"api": "openai-completions", "baseUrl": "http://127.0.0.1:1/v1",
                  "models": [{"id": "o1"}]}
    }}))
    .unwrap()
}

fn text(path: &Path) -> String {
    path.display().to_string()
}

struct Setup {
    _root: tempfile::TempDir,
    root: PathBuf,
    workspace: PathBuf,
    config_dir: PathBuf,
}

/// A workspace whose `.pirc/config.json` is `project`, and an empty node config dir.
fn workspace_with(project: Value) -> Setup {
    let dir = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(dir.path()).unwrap();
    let workspace = root.join("ws");
    fs::create_dir_all(workspace.join(".pirc")).unwrap();
    fs::write(
        workspace.join(".pirc/config.json"),
        serde_json::to_string(&project).unwrap(),
    )
    .unwrap();
    let config_dir = root.join("config");
    fs::create_dir(&config_dir).unwrap();
    Setup {
        _root: dir,
        root,
        workspace,
        config_dir,
    }
}

fn hash_of(workspace: &Path) -> String {
    project_trust_hash(&project_trust_fields(
        &read_project_config(&text(workspace)).unwrap(),
    ))
}

fn load(setup: &Setup, workspace: &Path, extra: &[(&str, &str)]) -> AgentConfig {
    let config_dir = text(&setup.config_dir);
    let mode = mode_json();
    let mut vars = vec![("PIRC_CONFIG_DIR", config_dir.as_str())];
    if !extra.iter().any(|(name, _)| *name == "PIRC_MODE") {
        vars.push(("PIRC_MODE", mode.as_str()));
    }
    vars.extend_from_slice(extra);
    load_agent_config(&text(workspace), models(), &env_of(&vars)).unwrap()
}

fn mode_json() -> String {
    serde_json::to_string(&pirc_protocol::mode::default_work()).unwrap()
}

fn env_lookup<'a>(config: &'a AgentConfig, name: &str) -> Option<&'a str> {
    config
        .env
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.as_str())
}

fn project(extra: &str) -> Value {
    json!({
        "defaultModel": {"provider": "fake", "id": "fake-model"},
        "env": {"PROJECT_VAR": "from-project"},
        "allowedPaths": [extra],
        "hooks": {"sessionStart": [{"command": "echo started"}]}
    })
}

#[test]
fn ignores_hooks_env_and_allowed_paths_until_their_hash_is_trusted() {
    let extra = tempfile::tempdir().unwrap();
    let extra = text(&fs::canonicalize(extra.path()).unwrap());
    let setup = workspace_with(project(&extra));
    let untrusted = load(&setup, &setup.workspace, &[]);
    assert_eq!(env_lookup(&untrusted, "PROJECT_VAR"), None);
    assert!(untrusted.hooks.session_start.is_empty());
    assert!(!untrusted.allowed_paths.contains(&extra));
    assert_eq!(
        untrusted.warnings,
        [format!(
            "{UNTRUSTED_PROJECT_WARNING} The ignored defaultModel is fake/fake-model."
        )]
    );
    // defaultModel is trust-gated too (L12).
    assert_eq!(untrusted.default_model, None);
    // A malformed hash is no trust at all.
    let bogus = load(&setup, &setup.workspace, &[("PIRC_PROJECT_TRUST", "yes")]);
    assert_eq!(env_lookup(&bogus, "PROJECT_VAR"), None);

    let hash = hash_of(&setup.workspace);
    let trusted = load(&setup, &setup.workspace, &[("PIRC_PROJECT_TRUST", &hash)]);
    assert_eq!(env_lookup(&trusted, "PROJECT_VAR"), Some("from-project"));
    assert_eq!(
        trusted
            .hooks
            .session_start
            .iter()
            .map(|hook| hook.command.as_str())
            .collect::<Vec<_>>(),
        ["echo started"]
    );
    assert_eq!(trusted.hooks.session_start[0].timeout_ms, 10_000);
    assert!(trusted.allowed_paths.contains(&extra));
    assert!(trusted.warnings.is_empty());
    assert_eq!(
        trusted.default_model,
        Some(ModelRef {
            provider: "fake".into(),
            id: "fake-model".into(),
            thinking: None
        })
    );
}

#[test]
fn ignores_the_config_again_once_it_changes_after_being_trusted() {
    let extra = "/tmp/pirc-extra-x";
    let setup = workspace_with(project(extra));
    let trusted_hash = hash_of(&setup.workspace);
    // Formatting and key order do not matter; values do.
    fs::write(
        setup.workspace.join(".pirc/config.json"),
        serde_json::to_string_pretty(&json!({
            "hooks": {"sessionStart": [{"command": "echo started"}]},
            "allowedPaths": [extra],
            "env": {"PROJECT_VAR": "from-project"},
            "defaultModel": {"id": "fake-model", "provider": "fake"}
        }))
        .unwrap(),
    )
    .unwrap();
    assert_eq!(hash_of(&setup.workspace), trusted_hash);
    let mut changed = project(extra);
    changed["env"] = json!({"PROJECT_VAR": "x", "LD_PRELOAD": "/tmp/evil.so"});
    fs::write(
        setup.workspace.join(".pirc/config.json"),
        changed.to_string(),
    )
    .unwrap();
    assert_ne!(hash_of(&setup.workspace), trusted_hash);
    let config = load(
        &setup,
        &setup.workspace,
        &[("PIRC_PROJECT_TRUST", &trusted_hash)],
    );
    assert!(config.env.is_empty());
    assert!(config.hooks.session_start.is_empty());
    assert!(!config.allowed_paths.contains(&extra.to_owned()));
    assert_eq!(config.warnings.len(), 1);
    assert!(config.warnings[0].starts_with(UNTRUSTED_PROJECT_WARNING));
}

#[test]
fn needs_no_trust_when_the_project_sets_none_of_the_gated_fields() {
    let setup = workspace_with(json!({}));
    assert!(load(&setup, &setup.workspace, &[]).warnings.is_empty());
}

#[test]
fn a_project_default_model_alone_needs_trust() {
    let setup = workspace_with(json!({"defaultModel": {"provider": "fake", "id": "fake-model"}}));
    let untrusted = load(&setup, &setup.workspace, &[]);
    assert_eq!(untrusted.default_model, None);
    assert_eq!(
        untrusted.warnings,
        [format!(
            "{UNTRUSTED_PROJECT_WARNING} The ignored defaultModel is fake/fake-model."
        )]
    );
    let hash = hash_of(&setup.workspace);
    let trusted = load(&setup, &setup.workspace, &[("PIRC_PROJECT_TRUST", &hash)]);
    assert_eq!(
        trusted.default_model.map(|model| model.id),
        Some("fake-model".to_owned())
    );
    assert!(trusted.warnings.is_empty());
}

/// A changed model needs trust again. (A config without one keeps its old
/// hash: `hashes_like_the_ts_agent` still holds.)
#[test]
fn the_model_is_part_of_the_hash() {
    let setup = workspace_with(json!({"env": {"A": "a"}}));
    let before = hash_of(&setup.workspace);
    fs::write(
        setup.workspace.join(".pirc/config.json"),
        json!({"env": {"A": "a"}, "defaultModel": {"provider": "p", "id": "m"}}).to_string(),
    )
    .unwrap();
    assert_ne!(hash_of(&setup.workspace), before);
}

/// Recorded from the TS `projectTrustHash` (Bun 1.4.2): keys in UTF-16
/// order, numbers as JS writes them.
#[test]
fn hashes_like_the_ts_agent() {
    let setup = workspace_with(json!({
        "env": {"Z": "z", "é": "1", "😀": "e", "\u{ffff}": "f", "A": "a"},
        "allowedPaths": ["../x", "~/y"],
        "hooks": {
            "beforeTool": [{"command": "c", "matcher": "bash", "timeoutMs": 5.0}],
            "sessionStart": [{"command": "echo \"hi\"\n"}]
        }
    }));
    assert_eq!(
        hash_of(&setup.workspace),
        "0fc336b589900fc10621b2b74baa902d862d0f2795faaf40f8e2679d851128ab"
    );
}

#[test]
fn loads_a_team_childs_project_config_from_the_parents_root_not_its_cwd() {
    let setup = workspace_with(json!({"env": {"FROM": "root"}}));
    let sub = setup.workspace.join("sub");
    fs::create_dir_all(sub.join(".pirc")).unwrap();
    fs::write(
        sub.join(".pirc/config.json"),
        json!({"env": {"FROM": "sub"}, "hooks": {"sessionStart": [{"command": "evil"}]}})
            .to_string(),
    )
    .unwrap();
    let trust = hash_of(&setup.workspace);
    let workspace = text(&setup.workspace);
    let child = load(
        &setup,
        &sub,
        &[
            ("PIRC_TEAM_AGENT", "worker"),
            ("PIRC_PROJECT_ROOT", &workspace),
            ("PIRC_PROJECT_TRUST", &trust),
        ],
    );
    assert_eq!(child.env, [("FROM".to_owned(), "root".to_owned())]);
    assert!(child.hooks.session_start.is_empty());
    assert_eq!(child.project_root, workspace);
    assert!(
        child
            .protected_paths
            .contains(&format!("{workspace}/.pirc"))
    );
    assert!(
        child
            .protected_paths
            .contains(&format!("{}/.pirc", text(&sub)))
    );
    // Only team children take PIRC_PROJECT_ROOT; even then the sub config needs its own trust.
    let top = load(
        &setup,
        &sub,
        &[
            ("PIRC_PROJECT_ROOT", &workspace),
            ("PIRC_PROJECT_TRUST", &trust),
        ],
    );
    assert_eq!(top.project_root, text(&sub));
    assert!(top.env.is_empty());
    assert!(top.hooks.session_start.is_empty());
    // An untrusted child warns nobody (its parent did).
    let untrusted_child = load(
        &setup,
        &sub,
        &[
            ("PIRC_TEAM_AGENT", "worker"),
            ("PIRC_PROJECT_ROOT", &workspace),
        ],
    );
    assert!(untrusted_child.warnings.is_empty());
    assert!(untrusted_child.env.is_empty());
}

#[test]
fn merges_trusted_project_config_and_prompts_from_pirc() {
    let setup = workspace_with(json!({"env": {"PIRC_TEST_VAR": "from-project"}}));
    fs::write(
        setup.workspace.join(".pirc/AGENTS.md"),
        "PROJECT-PROMPT\n\n",
    )
    .unwrap();
    fs::write(
        setup.config_dir.join("config.json"),
        json!({
            "env": {"PIRC_TEST_VAR": "global", "G": "g"},
            "allowedPaths": ["~/notes", "rel"],
            "hooks": {"beforeTool": [{"command": "global", "matcher": "bash", "timeoutMs": 500}]},
            "limits": {"maxTurns": 7},
            "features": {"todo": {"enabled": false}},
            "sandbox": {"anything": true},
            "unknown": 1
        })
        .to_string(),
    )
    .unwrap();
    let trust = hash_of(&setup.workspace);
    let config = load(&setup, &setup.workspace, &[("PIRC_PROJECT_TRUST", &trust)]);
    assert_eq!(
        config.env,
        [
            ("PIRC_TEST_VAR".to_owned(), "from-project".to_owned()),
            ("G".to_owned(), "g".to_owned())
        ]
    );
    let prompt = join_prompt(&config.system_prompt);
    assert!(prompt.starts_with("You are pirc, a coding agent"));
    assert!(prompt.ends_with("\n\nPROJECT-PROMPT"));
    let project = config.system_prompt.last().unwrap();
    assert_eq!(project.id, "agents:project");
    assert_eq!(project.title, "AGENTS.md (project)");
    assert_eq!(
        project.source,
        format!("{}/.pirc/AGENTS.md", text(&setup.workspace))
    );
    assert_eq!(config.system_prompt.len(), 2);
    assert_eq!(config.limits.max_turns, 7);
    assert_eq!(config.limits.bash_timeout_ms, 120_000);
    assert_eq!(
        config.features,
        *json!({"todo": {"enabled": false}}).as_object().unwrap()
    );
    assert_eq!(
        config.hooks.before_tool,
        [HookConfig {
            command: "global".into(),
            matcher: Some("bash".into()),
            timeout_ms: 500
        }]
    );
    assert_eq!(config.allowed_paths[0], text(&setup.workspace));
    assert_eq!(
        config.allowed_paths[1],
        js::path_join(&[&js::home_dir(), "notes"])
    );
    assert_eq!(
        config.allowed_paths[2],
        format!("{}/rel", text(&setup.config_dir))
    );
    assert_eq!(config.mode(), &pirc_protocol::mode::default_work());
    // The user's own ~/.agents/skills (this machine's) is configuration too.
    let skills = crate::skills::skill_read_paths(&crate::skills::skill_roots(
        &text(&setup.config_dir),
        &text(&setup.workspace),
    ));
    let mut expected = vec![
        format!("{}/.pirc", text(&setup.workspace)),
        format!("{}/.pirc", text(&setup.workspace)),
        format!("{}/.git/hooks", text(&setup.workspace)),
    ];
    expected.extend(skills.iter().cloned());
    expected.extend([
        format!("{}/roles", text(&setup.config_dir)),
        format!("{}/modes", text(&setup.config_dir)),
    ]);
    assert_eq!(config.protected_paths, expected);
    assert!(config.allowed_paths.ends_with(&skills));
    assert_eq!(
        config.role_dirs,
        crate::roles::role_dirs(&text(&setup.config_dir), &text(&setup.workspace))
    );
    assert!(!config.sandboxed);
    // Unsandboxed without a node policy: credential stores only.
    assert_eq!(
        config.path_policy.allow_write,
        config
            .allowed_paths
            .iter()
            .map(|path| pirc_policy::real_resolve(path))
            .collect::<Vec<_>>()
    );
    assert!(!config.path_policy.deny_read.is_empty());
}

#[test]
fn applies_the_node_sandbox_policy_it_is_given() {
    let setup = workspace_with(json!({}));
    let policy = json!({
        "denyRead": ["/state"],
        "allowRead": ["/state/s"],
        "allowWrite": ["/ws", "/state/s"],
        "denyWrite": ["/ws/.pirc"],
        "sharedWrite": ["/tmp"],
        "ignored": true
    })
    .to_string();
    let config = load(
        &setup,
        &setup.workspace,
        &[("PIRC_SANDBOX", "srt"), ("PIRC_SANDBOX_POLICY", &policy)],
    );
    assert!(config.sandboxed);
    assert_eq!(
        config.path_policy,
        PathPolicy {
            deny_read: vec!["/state".into()],
            allow_read: vec!["/state/s".into()],
            allow_write: vec!["/ws".into(), "/state/s".into()],
            deny_write: vec!["/ws/.pirc".into()],
            shared_write: Some(vec!["/tmp".into()]),
        }
    );
    // Unsandboxed, the node's read rules apply and the configured paths are writable.
    let unsandboxed = load(
        &setup,
        &setup.workspace,
        &[("PIRC_SANDBOX_POLICY", &policy)],
    );
    assert_eq!(unsandboxed.path_policy.deny_read, ["/state"]);
    assert_eq!(
        unsandboxed.path_policy.allow_write,
        unsandboxed.allowed_paths
    );
    assert!(unsandboxed.path_policy.deny_write.is_empty());
    assert_eq!(unsandboxed.path_policy.shared_write, None);
    for bad in [
        "{",
        "null",
        r#"{"denyRead": []}"#,
        r#"{"denyRead":[],"allowRead":[],"allowWrite":[],"denyWrite":[],"sharedWrite":null}"#,
    ] {
        let config_dir = text(&setup.config_dir);
        let error = load_agent_config(
            &text(&setup.workspace),
            models(),
            &env_of(&[
                ("PIRC_CONFIG_DIR", &config_dir),
                ("PIRC_SANDBOX_POLICY", bad),
                ("PIRC_MODE", &mode_json()),
            ]),
        )
        .unwrap_err();
        assert_eq!(error, "PIRC_SANDBOX_POLICY is not a valid path policy");
    }
}

#[test]
fn default_mode_sections_reproduce_legacy_prompts_exactly() {
    let setup = workspace_with(json!({}));
    let config_dir = text(&setup.config_dir);
    let workspace = text(&setup.workspace);
    let project_dir = text(&setup.workspace.join(".pirc"));
    let mut legacy_work = vec![PromptSection::new(
        "base",
        "Coding instructions",
        "built-in",
        BASE_PROMPT,
    )];
    for (dir, kind) in [
        (&config_dir, "global"),
        (&workspace, "workspace"),
        (&project_dir, "project"),
    ] {
        let file = format!("{dir}/AGENTS.md");
        fs::write(&file, format!("{kind} instructions\n")).unwrap();
        legacy_work.push(PromptSection::new(
            &format!("agents:{kind}"),
            &format!("AGENTS.md ({kind})"),
            &file,
            read_text(&file).unwrap(),
        ));
    }
    let mode = pirc_protocol::mode::default_work();
    let actual = mode_prompt_sections(&mode, &config_dir, &workspace, &project_dir).unwrap();
    assert_eq!(
        join_prompt(&actual).as_bytes(),
        join_prompt(&legacy_work).as_bytes()
    );
    assert_eq!(actual, legacy_work);
}

#[test]
fn renders_mode_sections_in_order_without_reading_unselected_files() {
    let setup = workspace_with(json!({}));
    let mut mode = pirc_protocol::mode::default_work();
    mode.prompt = vec![ModePromptSection::Body, ModePromptSection::Base];
    mode.body = "Mode instructions".into();
    // An invalid UTF-8 AGENTS.md would fail if an unselected source were read.
    fs::write(setup.config_dir.join("AGENTS.md"), [0xff]).unwrap();
    let actual = mode_prompt_sections(
        &mode,
        &text(&setup.config_dir),
        &text(&setup.workspace),
        &text(&setup.workspace.join(".pirc")),
    )
    .unwrap();
    assert_eq!(actual.len(), 2);
    assert_eq!(actual[0].id, "mode:body");
    assert_eq!(actual[0].text, "Mode instructions");
    assert_eq!(actual[1].id, "base");
}

#[test]
fn adds_skill_locations_as_readable_protected_configuration() {
    let setup = workspace_with(json!({}));
    let skills = setup.config_dir.join("skills");
    fs::create_dir_all(skills.join("pdf")).unwrap();
    fs::write(
        skills.join("pdf/SKILL.md"),
        "---\nname: pdf\ndescription: PDFs.\n---\n",
    )
    .unwrap();
    let config = load(&setup, &setup.workspace, &[]);
    for path in [text(&skills), text(&skills.join("pdf"))] {
        assert!(config.allowed_paths.contains(&path), "{path}");
        assert!(config.protected_paths.contains(&path), "{path}");
    }
}

#[test]
fn warns_about_workspace_memory_settings_at_load() {
    let setup = workspace_with(json!({}));
    fs::write(
        setup.config_dir.join("config.json"),
        json!({"features": {"workspaceMemory": {"enabled": false, "oldOption": "private-value"}}})
            .to_string(),
    )
    .unwrap();
    let config = load(&setup, &setup.workspace, &[]);
    assert_eq!(config.warnings.len(), 1);
    assert!(config.warnings[0].contains("unknown field (ignored)"));
    assert!(!config.warnings[0].contains("private-value"));
}

/// Every problem in a config file is reported, with its path.
#[test]
fn rejects_invalid_config_with_every_issue() {
    let setup = workspace_with(json!({}));
    let cases = [
        (
            json!({"limits": {"maxTurns": 0, "completionWaitMs": 1e12}, "env": {"A": 1}, "hooks": null, "allowedPaths": "x"}),
            json!({}),
            "allowedPaths: Expected array, received string\n\
             env.A: Expected string, received number\n\
             hooks: Expected object, received null\n\
             limits.maxTurns: Expected more than 0\n\
             limits.completionWaitMs: Expected at most 86400000",
        ),
        (
            json!({}),
            json!({"foo": 1, "defaultModel": {"provider": "p", "thinking": "big"}, "hooks": {"beforeTool": [{"command": "", "timeoutMs": 1.5}]}}),
            "defaultModel.id: Required (string)\n\
             defaultModel.thinking: Expected one of 'off', 'minimal', 'low', 'medium', 'high', 'xhigh', received 'big'\n\
             hooks.beforeTool[0].command: Expected at least 1 characters\n\
             hooks.beforeTool[0].timeoutMs: Expected an integer\n\
             (root): Unknown key(s): 'foo'",
        ),
        (
            json!([]),
            json!({}),
            "(root): Expected object, received array",
        ),
    ];
    for (global, project, expected) in cases {
        fs::write(setup.config_dir.join("config.json"), global.to_string()).unwrap();
        fs::write(
            setup.workspace.join(".pirc/config.json"),
            project.to_string(),
        )
        .unwrap();
        let config_dir = text(&setup.config_dir);
        let error = load_agent_config(
            &text(&setup.workspace),
            models(),
            &env_of(&[
                ("PIRC_CONFIG_DIR", &config_dir),
                ("PIRC_MODE", &mode_json()),
            ]),
        )
        .unwrap_err();
        assert_eq!(error, expected);
    }
    fs::write(setup.config_dir.join("config.json"), "{").unwrap();
    let error = load_agent_config(
        &text(&setup.workspace),
        models(),
        &env_of(&[
            ("PIRC_CONFIG_DIR", &text(&setup.config_dir)),
            ("PIRC_MODE", &mode_json()),
        ]),
    )
    .unwrap_err();
    assert_eq!(
        error,
        format!(
            "Invalid JSON in {}/config.json: {}",
            text(&setup.config_dir),
            serde_json::from_str::<serde_json::Value>("{").unwrap_err()
        )
    );
    let _ = &setup.root;
}

#[test]
fn requires_a_valid_mode_snapshot_and_rejects_legacy_environment() {
    let setup = workspace_with(json!({}));
    let config_dir = text(&setup.config_dir);
    for (extra, expected) in [
        (vec![], "PIRC_MODE is required"),
        (vec![("PIRC_MODE", "")], "Invalid PIRC_MODE"),
        (vec![("PIRC_MODE", "{}")], "Invalid PIRC_MODE"),
        (vec![("PIRC_MODE", "null")], "Invalid PIRC_MODE"),
        (
            vec![("PIRC_WORKSPACE_KIND", "chat")],
            "PIRC_WORKSPACE_KIND is retired",
        ),
    ] {
        let mut vars = vec![("PIRC_CONFIG_DIR", config_dir.as_str())];
        vars.extend(extra);
        let error =
            load_agent_config(&text(&setup.workspace), models(), &env_of(&vars)).unwrap_err();
        assert!(error.contains(expected), "{error}");
    }
    let mut mode = pirc_protocol::mode::default_work();
    mode.tools = Some(vec!["ptc".into()]);
    let raw = serde_json::to_string(&mode).unwrap();
    let error = load_agent_config(
        &text(&setup.workspace),
        models(),
        &env_of(&[("PIRC_MODE", &raw)]),
    )
    .unwrap_err();
    assert!(error.contains("unknown tools name: ptc"), "{error}");
}

#[test]
fn mode_snapshot_ignores_mode_files_and_disabled_project_config() {
    let setup = workspace_with(json!({}));
    fs::write(setup.workspace.join(".pirc/config.json"), "invalid JSON").unwrap();
    fs::create_dir(setup.config_dir.join("modes")).unwrap();
    fs::write(setup.config_dir.join("modes/chat.md"), "invalid mode").unwrap();
    // Even an explicitly allowed configuration directory cannot grant writes
    // to the gateway's mode catalog on a shared host.
    fs::write(
        setup.config_dir.join("config.json"),
        json!({"allowedPaths":[text(&setup.config_dir)]}).to_string(),
    )
    .unwrap();
    let mut mode = pirc_protocol::mode::default_work();
    mode.id = pirc_protocol::ModeId::new("custom-mode").unwrap();
    mode.prompt = vec![ModePromptSection::Body];
    mode.body = "Frozen body".into();
    mode.repository = false;
    mode.workspace_memory = false;
    mode.project_config = false;
    let config = load(
        &setup,
        &setup.workspace,
        &[("PIRC_MODE", &serde_json::to_string(&mode).unwrap())],
    );
    assert_eq!(config.mode(), &mode);
    assert_eq!(join_prompt(&config.system_prompt), "Frozen body");
    assert!(
        config
            .protected_paths
            .contains(&text(&setup.config_dir.join("modes")))
    );
    let guard = pirc_policy::PathGuard::new(
        &config.workspace,
        &config.path_policy,
        &config.protected_paths,
    );
    assert!(
        guard
            .resolve(&text(&setup.config_dir.join("modes/chat.md")), true)
            .is_err()
    );
}

#[test]
fn mode_configuration_protects_linked_sources_and_dangling_targets() {
    use std::os::unix::fs::symlink;

    for linked_directory in [false, true] {
        let setup = workspace_with(json!({}));
        let modes = setup.config_dir.join("modes");
        let catalog = if linked_directory {
            let catalog = setup.workspace.join("catalog");
            fs::create_dir(&catalog).unwrap();
            symlink(&catalog, &modes).unwrap();
            catalog
        } else {
            fs::create_dir(&modes).unwrap();
            modes.clone()
        };
        let source = setup.workspace.join("source.txt");
        // Catalog files cannot be parsed or opened as prompt text by the agent.
        fs::write(&source, [0xff, 0xfe]).unwrap();
        let hop = setup.workspace.join("hop");
        symlink(&source, &hop).unwrap();
        symlink(&hop, catalog.join("chat.md")).unwrap();
        let dangling = setup.workspace.join("missing/source.md");
        let dangling_hop = setup.workspace.join("dangling-hop");
        symlink(&dangling, &dangling_hop).unwrap();
        symlink(&dangling_hop, catalog.join("future.md")).unwrap();
        let mut mode = pirc_protocol::mode::default_work();
        mode.prompt = vec![ModePromptSection::Body];
        let config = load(
            &setup,
            &setup.workspace,
            &[("PIRC_MODE", &serde_json::to_string(&mode).unwrap())],
        );
        let guard = pirc_policy::PathGuard::new(
            &config.workspace,
            &config.path_policy,
            &config.protected_paths,
        );
        for path in [
            source,
            hop,
            dangling,
            dangling_hop,
            modes.join("chat.md"),
            modes.join("future.md"),
        ] {
            assert!(guard.resolve(&text(&path), true).is_err(), "{path:?}");
        }
        if linked_directory {
            assert!(guard.resolve(&text(&catalog.join("new.md")), true).is_err());
        }
        assert!(
            guard
                .resolve(&text(&setup.workspace.join("notes.md")), true)
                .is_ok()
        );
    }
}

#[test]
fn mode_configuration_symlink_cycles_fail_agent_loading_closed() {
    use std::os::unix::fs::symlink;

    for directory in [false, true] {
        let setup = workspace_with(json!({}));
        let modes = setup.config_dir.join("modes");
        if directory {
            symlink("modes", &modes).unwrap();
        } else {
            fs::create_dir(&modes).unwrap();
            symlink("chat.md", modes.join("chat.md")).unwrap();
        }
        let mode = mode_json();
        let config_dir = text(&setup.config_dir);
        let error = load_agent_config(
            &text(&setup.workspace),
            models(),
            &env_of(&[("PIRC_CONFIG_DIR", &config_dir), ("PIRC_MODE", &mode)]),
        )
        .unwrap_err();
        assert!(
            error.contains("Cannot safely inspect mode configuration paths"),
            "{error}"
        );
    }
}

#[test]
fn mode_feature_defaults_respect_every_explicit_node_switch_and_keep_settings() {
    for key in pirc_protocol::mode::FEATURE_NAMES {
        for explicit in [None, Some(true), Some(false)] {
            for on in [true, false] {
                let mut mode = pirc_protocol::mode::default_work();
                if on {
                    mode.features_on.push((*key).into());
                } else {
                    mode.features_off.push((*key).into());
                }
                let mut settings = json!({"customSetting": 42});
                if let Some(enabled) = explicit {
                    settings["enabled"] = json!(enabled);
                }
                let mut features = Map::from_iter([((*key).into(), settings)]);
                apply_mode_features(&mut features, &mode);
                assert_eq!(
                    features[*key]["enabled"],
                    json!(explicit.unwrap_or(on)),
                    "{key}"
                );
                assert_eq!(features[*key]["customSetting"], 42);
            }
        }
    }
    let mode = pirc_protocol::mode::default_work();
    let mut features = json!({"todo":{"enabled":false},"skills":{"customSetting":42}})
        .as_object()
        .unwrap()
        .clone();
    let original = features.clone();
    apply_mode_features(&mut features, &mode);
    assert_eq!(features, original);
}

fn entry(data: EntryData) -> SessionEntry {
    SessionEntry {
        id: "x".into(),
        parent_id: None,
        timestamp: 0,
        data,
    }
}

#[test]
fn session_settings_prefer_the_latest_recorded_change() {
    let catalog = models();
    let fallback = ModelRef {
        provider: "other".into(),
        id: "o1".into(),
        thinking: Some(ThinkingLevel::High),
    };
    let pair = |p: &str, i: &str| Some((p.to_owned(), i.to_owned()));
    // Nothing recorded: the default model and its level.
    assert_eq!(
        session_settings(&[], Some(&fallback), &catalog),
        (pair("other", "o1"), ThinkingLevel::High)
    );
    // No default: the first configured model, medium.
    assert_eq!(
        session_settings(&[], None, &catalog),
        (pair("fake", "fake-model"), ThinkingLevel::Medium)
    );
    let branch = [
        entry(EntryData::ModelChange {
            provider: "a".into(),
            model_id: "1".into(),
        }),
        entry(EntryData::ThinkingLevelChange {
            thinking_level: "low".into(),
        }),
        entry(EntryData::ModelChange {
            provider: "b".into(),
            model_id: "2".into(),
        }),
    ];
    assert_eq!(
        session_settings(&branch, Some(&fallback), &catalog),
        (pair("b", "2"), ThinkingLevel::Low)
    );
    // An unknown recorded level is medium, not the default's.
    let odd = [entry(EntryData::ThinkingLevelChange {
        thinking_level: "max".into(),
    })];
    assert_eq!(
        session_settings(&odd, Some(&fallback), &catalog).1,
        ThinkingLevel::Medium
    );
    let empty: Models = serde_json::from_value(json!({})).unwrap();
    assert_eq!(
        session_settings(&[], None, &empty),
        (None, ThinkingLevel::Medium)
    );
}
