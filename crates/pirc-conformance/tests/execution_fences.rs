//! Real Node link/restart proof for the transition admission fence. This is not
//! Gateway/UI acceptance or proof of OS-level revocation / replacement mounts.
use pirc_conformance::{FakeGateway, LoneNode, NODE_ID, NodeOptions, USER};
use serde_json::{Value, json};
async fn register(gateway: &FakeGateway) -> pirc_conformance::NodeLink {
    let mut link = gateway.accept().await;
    link.recv_where(|frame| frame["type"] == "register").await;
    link.send(
        &json!({"type":"registered","nodeId":NODE_ID,"models":{"providers":{}},"mirrors":{}}),
    )
    .await;
    link
}
fn req(method: &str, path: &str, payload: Value) -> Value {
    json!({"method":method,"url":path,"user":USER,"payload":payload})
}
#[tokio::test(flavor = "multi_thread")]
async fn persisted_fence_survives_reboot_without_rebinding_or_erasing_context() {
    let gateway = FakeGateway::bind().await;
    let Some(mut node) = LoneNode::start_with(
        gateway.port(),
        NodeOptions {
            chat_node: true,
            agent_core_only: true,
            env: vec![("PIRC_BROWSER", "false".into())],
        },
    ) else {
        return;
    };
    let mut link = register(&gateway).await;
    let capabilities = link
        .request(
            "capabilities",
            req("GET", "/api/execution-fences/capabilities", Value::Null),
        )
        .await;
    assert_eq!(capabilities["data"]["status"], 200, "{capabilities}");
    assert_eq!(capabilities["data"]["body"]["durableAdmissionFence"], true);
    assert_eq!(capabilities["data"]["body"]["confirmsRevocation"], false);
    assert_eq!(capabilities["data"]["body"]["installsEnvironment"], false);
    let create = link
        .request(
            "session",
            req("POST", "/api/sessions", json!({"workspaceId":"chats"})),
        )
        .await;
    assert_eq!(create["data"]["status"], 201, "{create}");
    let session = create["data"]["body"]["session"]["id"].as_str().unwrap();
    let epoch = create["data"]["body"]["session"]["runnerEpoch"].clone();
    let base = format!("/api/sessions/{session}");
    let before = link
        .request(
            "before",
            req("GET", &format!("{base}/snapshot"), Value::Null),
        )
        .await;
    assert_eq!(before["data"]["status"], 200, "{before}");
    let control = link
        .request(
            "control",
            req(
                "POST",
                &format!("{base}/control/acquire"),
                json!({"clientId":"phone"}),
            ),
        )
        .await;
    assert_eq!(control["data"]["status"], 200, "{control}");
    let generation = control["data"]["body"]["lease"]["generation"].clone();
    assert!(generation.is_number(), "{control}");
    let acceptance = req(
        "POST",
        &format!("{base}/execution-fences"),
        json!({"intent":{"operationId":"move-1","planHash":"a".repeat(64),"expectedWorkspaceId":"chats","expectedRunnerEpoch":epoch},"clientId":"phone","generation":generation}),
    );
    // Once acceptance commits, discard that result. A hard restart must not reopen admission.
    link.send(&json!({"type":"request","requestId":"lost-acceptance","data":acceptance.clone()}))
        .await;
    let accepted = link
        .recv_where(|v| v["type"] == "response" && v["requestId"] == "lost-acceptance")
        .await;
    assert_eq!(accepted["data"]["status"], 200, "{accepted}");
    node.restart(true);
    drop(link);
    let mut link = register(&gateway).await;
    let status_path = format!("{base}/execution-fences/move-1");
    let status = link
        .request("status", req("GET", &status_path, Value::Null))
        .await;
    assert_eq!(
        status["data"]["body"]["transition"]["state"], "fenced",
        "{status}"
    );
    let replay = link.request("duplicate", acceptance).await;
    assert_eq!(replay["data"]["body"], status["data"]["body"]);
    let mut conflicting = req(
        "POST",
        &format!("{base}/execution-fences"),
        json!({"intent":{"operationId":"move-1","planHash":"b".repeat(64),"expectedWorkspaceId":"chats","expectedRunnerEpoch":epoch},"clientId":"phone","generation":generation}),
    );
    let conflict = link.request("changed-plan", conflicting.clone()).await;
    assert_eq!(conflict["data"]["status"], 409, "{conflict}");
    conflicting["user"] = json!("outsider");
    assert_eq!(
        link.request("other-user", conflicting).await["data"]["status"],
        403
    );
    let takeover = link
        .request(
            "takeover-for-stop",
            req(
                "POST",
                &format!("{base}/control/acquire"),
                json!({"clientId":"web","force":true}),
            ),
        )
        .await;
    assert_eq!(takeover["data"]["status"], 200, "{takeover}");
    let command = req(
        "POST",
        &format!("{base}/commands"),
        json!({"commandId":"must-not-send","clientId":"phone","generation":generation,"payload":{"type":"prompt","message":"never execute","uploadIds":[]}}),
    );
    let denied = link.request("denied-command", command).await;
    assert_eq!(denied["data"]["status"], 409, "{denied}");
    assert_eq!(
        denied["data"]["body"]["error"]["code"],
        "environment_transition_pending"
    );
    let drained = link
        .request(
            "drain",
            req("POST", &format!("{status_path}/drain"), json!({})),
        )
        .await;
    assert_eq!(
        drained["data"]["body"]["transition"]["state"], "supervisor_drained",
        "{drained}"
    );
    assert_eq!(
        drained["data"]["body"]["transition"]["revocationConfirmed"],
        false
    );
    assert_eq!(
        drained["data"]["body"]["transition"]["targetInstalled"],
        false
    );
    let after = link
        .request(
            "retained-context",
            req("GET", &format!("{base}/snapshot"), Value::Null),
        )
        .await;
    assert_eq!(after["data"]["status"], 200, "{after}");
    assert_eq!(
        after["data"]["body"]["history"],
        before["data"]["body"]["history"]
    );
    assert_eq!(after["data"]["body"]["session"]["workspaceId"], "chats");
    let deleted = link
        .request("delete", req("DELETE", &base, Value::Null))
        .await;
    assert_eq!(deleted["data"]["status"], 204, "{deleted}");
    assert_eq!(
        link.request("tombstone", req("GET", &status_path, Value::Null))
            .await["data"]["body"]["transition"]["state"],
        "deleted"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn terminal_stream_reports_the_fence_while_a_peer_remains_interactive() {
    let gateway = FakeGateway::bind().await;
    let Some(_node) = LoneNode::start_with(
        gateway.port(),
        NodeOptions {
            chat_node: true,
            agent_core_only: true,
            env: vec![
                ("PIRC_BROWSER", "false".into()),
                ("PIRC_TERMINAL_SHELL", "/bin/sh".into()),
            ],
        },
    ) else {
        return;
    };
    let mut link = register(&gateway).await;
    let mut sessions = Vec::new();
    for stream in ["source", "peer"] {
        let created = link
            .request(
                &format!("create-{stream}"),
                req("POST", "/api/sessions", json!({"workspaceId":"chats"})),
            )
            .await;
        assert_eq!(created["data"]["status"], 201, "{created}");
        let session = created["data"]["body"]["session"]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let epoch = created["data"]["body"]["session"]["runnerEpoch"].clone();
        let base = format!("/api/sessions/{session}");
        let acquired = link
            .request(
                &format!("lease-{stream}"),
                req(
                    "POST",
                    &format!("{base}/control/acquire"),
                    json!({"clientId":"phone"}),
                ),
            )
            .await;
        assert_eq!(acquired["data"]["status"], 200, "{acquired}");
        let generation = acquired["data"]["body"]["lease"]["generation"].clone();
        let terminal = link
            .request(
                &format!("terminal-{stream}"),
                req(
                    "POST",
                    &format!("{base}/terminals"),
                    json!({"clientId":"phone","generation":generation}),
                ),
            )
            .await;
        assert_eq!(terminal["data"]["status"], 201, "{terminal}");
        let terminal = terminal["data"]["body"]["terminal"]["id"].as_str().unwrap();
        link.send(&json!({"type":"terminal_open","streamId":stream,"sessionId":session,"terminalId":terminal,"user":USER})).await;
        link.recv_where(|f| {
            f["type"] == "terminal_frame"
                && f["streamId"] == stream
                && f["frame"]["type"] == "ready"
        })
        .await;
        sessions.push((session, base, epoch, generation));
    }
    let (_, base, epoch, generation) = &sessions[0];
    let accepted=link.request("terminal-fence",req("POST",&format!("{base}/execution-fences"),json!({"intent":{
        "operationId":"terminal-fence","planHash":"a".repeat(64),"expectedWorkspaceId":"chats","expectedRunnerEpoch":epoch},
        "clientId":"phone","generation":generation}))).await;
    assert_eq!(accepted["data"]["status"], 200, "{accepted}");
    for command in [
        json!({"type":"input","data":"printf stale > should-not-exist\n"}),
        json!({"type":"resize","cols":180,"rows":60}),
    ] {
        let mut message = command;
        message["clientId"] = json!("phone");
        message["generation"] = generation.clone();
        link.send(&json!({"type":"terminal_input","streamId":"source","message":message}))
            .await;
        let refused = link
            .recv_where(|f| {
                f["type"] == "terminal_frame"
                    && f["streamId"] == "source"
                    && f["frame"]["type"] == "error"
            })
            .await;
        assert_eq!(
            refused["frame"]["code"], "environment_transition_pending",
            "{refused}"
        );
    }
    link.send(
        &json!({"type":"terminal_input","streamId":"peer","message":{
        "type":"input","clientId":"phone","generation":sessions[1].3,
        "data":"printf 'PEER-%s\\n' $((6*7))\n"}}),
    )
    .await;
    let mut output = String::new();
    while !output.contains("PEER-42") {
        let frame = link
            .recv_where(|f| f["type"] == "terminal_frame" && f["streamId"] == "peer")
            .await;
        assert_ne!(frame["frame"]["type"], "error", "{frame}");
        if frame["frame"]["type"] == "output" {
            output.push_str(frame["frame"]["data"].as_str().unwrap());
        }
    }
    // Draining closes the old terminal but cannot claim OS-wide revocation.
    let drained = link
        .request(
            "terminal-drain",
            req(
                "POST",
                &format!("{base}/execution-fences/terminal-fence/drain"),
                json!({}),
            ),
        )
        .await;
    assert_eq!(
        drained["data"]["body"]["transition"]["state"], "supervisor_drained",
        "{drained}"
    );
    assert_eq!(
        drained["data"]["body"]["transition"]["revocationConfirmed"],
        false
    );
    let removed = link
        .request("terminal-delete", req("DELETE", base, Value::Null))
        .await;
    assert_eq!(removed["data"]["status"], 204, "{removed}");
    let peer_removed = link
        .request("peer-delete", req("DELETE", &sessions[1].1, Value::Null))
        .await;
    assert_eq!(peer_removed["data"]["status"], 204, "{peer_removed}");
}

#[tokio::test(flavor = "multi_thread")]
async fn terminal_observation_survives_restart_and_an_unknown_shell_blocks_deletion() {
    for settle_before_crash in [true, false] {
        let gateway = FakeGateway::bind().await;
        let Some(mut node) = LoneNode::start_with(
            gateway.port(),
            NodeOptions {
                chat_node: true,
                agent_core_only: true,
                env: vec![
                    ("PIRC_BROWSER", "false".into()),
                    ("PIRC_TERMINAL_SHELL", "/bin/sh".into()),
                ],
            },
        ) else {
            return;
        };
        let mut link = register(&gateway).await;
        let created = link
            .request(
                "create",
                req("POST", "/api/sessions", json!({"workspaceId":"chats"})),
            )
            .await;
        assert_eq!(created["data"]["status"], 201, "{created}");
        let session = created["data"]["body"]["session"]["id"].as_str().unwrap();
        let epoch = created["data"]["body"]["session"]["runnerEpoch"].clone();
        let base = format!("/api/sessions/{session}");
        let acquired = link
            .request(
                "control",
                req(
                    "POST",
                    &format!("{base}/control/acquire"),
                    json!({"clientId":"phone"}),
                ),
            )
            .await;
        let generation = acquired["data"]["body"]["lease"]["generation"].clone();
        assert!(generation.is_number(), "{acquired}");
        let lease = json!({"clientId":"phone","generation":generation});
        let terminal = link
            .request(
                "terminal",
                req("POST", &format!("{base}/terminals"), lease.clone()),
            )
            .await;
        assert_eq!(terminal["data"]["status"], 201, "{terminal}");
        let terminal = terminal["data"]["body"]["terminal"]["id"].as_str().unwrap();
        if settle_before_crash {
            let closed = link
                .request(
                    "manual-close",
                    req(
                        "POST",
                        &format!("{base}/terminals/{terminal}/close"),
                        lease.clone(),
                    ),
                )
                .await;
            assert_eq!(closed["data"]["status"], 204, "{closed}");
        }
        let path = format!("{base}/execution-fences/terminal-reboot");
        let acceptance = req(
            "POST",
            &format!("{base}/execution-fences"),
            json!({"intent":{
            "operationId":"terminal-reboot","planHash":"b".repeat(64),"expectedWorkspaceId":"chats","expectedRunnerEpoch":epoch},
            "clientId":"phone","generation":generation}),
        );
        let accepted = link.request("accept", acceptance.clone()).await;
        assert_eq!(accepted["data"]["status"], 200, "{accepted}");
        if settle_before_crash {
            let drained = link
                .request("drain", req("POST", &format!("{path}/drain"), json!({})))
                .await;
            assert_eq!(
                drained["data"]["body"]["transition"]["state"], "supervisor_drained",
                "{drained}"
            );
            assert_eq!(
                drained["data"]["body"]["transition"]["terminals"]["observersSettled"],
                1
            );
        }
        node.restart(true);
        drop(link);
        let mut link = register(&gateway).await;
        let replay = link.request("replayed-acceptance", acceptance).await;
        assert_eq!(replay["data"]["status"], 200, "{replay}");
        let drained = link
            .request(
                "restart-drain",
                req("POST", &format!("{path}/drain"), json!({})),
            )
            .await;
        assert_eq!(drained["data"]["status"], 200, "{drained}");
        let result = &drained["data"]["body"]["transition"];
        assert_eq!(result["revocationConfirmed"], false);
        assert_eq!(result["targetInstalled"], false);
        assert_eq!(result["terminals"]["historyComplete"], false);
        assert_eq!(result["terminals"]["launches"], 1);
        if settle_before_crash {
            assert_eq!(result["state"], "supervisor_drained");
            assert_eq!(result["terminals"]["unresolved"], 0);
            assert_eq!(result["terminals"]["observersSettled"], 1);
        } else {
            assert_eq!(result["state"], "blocked");
            assert_eq!(result["errorCode"], "terminal_stop_unconfirmed");
            assert_eq!(result["terminals"]["unresolved"], 1);
        }
        let deleted = link
            .request("delete", req("DELETE", &base, Value::Null))
            .await;
        if settle_before_crash {
            assert_eq!(deleted["data"]["status"], 204, "{deleted}");
        } else {
            assert_eq!(deleted["data"]["status"], 503, "{deleted}");
            assert_eq!(
                deleted["data"]["body"]["error"]["code"],
                "terminal_stop_unconfirmed"
            );
        }
        let receipt = link
            .request("retained", req("GET", &path, Value::Null))
            .await;
        assert_eq!(receipt["data"]["status"], 200, "{receipt}");
        assert_eq!(
            receipt["data"]["body"]["transition"]["terminals"],
            result["terminals"]
        );
    }
}

/// Real Node and Git processes with the conformance sandbox stand-in. This
/// proves request retirement/output gating, not native OS descendant revocation.
#[tokio::test(flavor = "multi_thread")]
async fn in_flight_git_panel_stops_on_fence_and_peer_file_reads_survive() {
    use std::{fs, process::Command, time::Duration};
    let gateway = FakeGateway::bind().await;
    let Some(node) = LoneNode::start_with(
        gateway.port(),
        NodeOptions {
            chat_node: false,
            agent_core_only: true,
            env: vec![("PIRC_BROWSER", "false".into())],
        },
    ) else {
        return;
    };
    let mut link = register(&gateway).await;
    let root = node.dir.path().canonicalize().unwrap().join("workspace");
    let git = |args: &[&str]| {
        let output = Command::new("git")
            .args(args)
            .current_dir(&root)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .unwrap();
        assert!(output.status.success(), "git {args:?}: {output:?}");
    };
    git(&["init", "-q"]);
    fs::write(root.join("file.txt"), "original\n").unwrap();
    git(&["add", "file.txt"]);
    git(&[
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "-qm",
        "initial",
    ]);
    fs::write(root.join("file.txt"), "later user edit\n").unwrap();
    // The stand-in permits this marker. Production read-only policies do not
    // gain write access; no test filter is installed in the real repository.
    fs::write(
        root.join("slow-filter.sh"),
        "printf '%s' \"$$\" > panel-filter-started\nexec sleep 30\n",
    )
    .unwrap();
    fs::write(root.join(".gitattributes"), "file.txt filter=paneltest\n").unwrap();
    git(&["config", "filter.paneltest.clean", "sh slow-filter.sh"]);
    let mut sessions = Vec::new();
    for name in ["source", "peer"] {
        let created = link
            .request(
                &format!("panel-create-{name}"),
                req("POST", "/api/sessions", json!({"workspaceId":"test"})),
            )
            .await;
        assert_eq!(created["data"]["status"], 201, "{created}");
        sessions.push(created["data"]["body"]["session"].clone());
    }
    let base = format!("/api/sessions/{}", sessions[0]["id"].as_str().unwrap());
    let control = link
        .request(
            "panel-lease",
            req(
                "POST",
                &format!("{base}/control/acquire"),
                json!({"clientId":"phone"}),
            ),
        )
        .await;
    assert_eq!(control["data"]["status"], 200, "{control}");
    let generation = &control["data"]["body"]["lease"]["generation"];
    link.send(&json!({"type":"request","requestId":"slow-panel","data":req("GET", &format!("{base}/git/diff?path=file.txt"), Value::Null)})).await;
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if fs::read_to_string(root.join("panel-filter-started"))
                .is_ok_and(|p| p.parse::<u32>().is_ok())
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("Git filter must actually start before fencing");
    let accepted = link.request("fence-panel", req("POST", &format!("{base}/execution-fences"), json!({
        "intent":{"operationId":"panel-switch","planHash":"a".repeat(64),"expectedWorkspaceId":"test","expectedRunnerEpoch":sessions[0]["runnerEpoch"]},
        "clientId":"phone","generation":generation
    }))).await;
    assert_eq!(accepted["data"]["status"], 200, "{accepted}");
    let result = if let Some(i) = link
        .skipped
        .iter()
        .position(|v| v["type"] == "response" && v["requestId"] == "slow-panel")
    {
        link.skipped.remove(i)
    } else {
        tokio::time::timeout(
            Duration::from_secs(5),
            link.recv_where(|v| v["type"] == "response" && v["requestId"] == "slow-panel"),
        )
        .await
        .unwrap()
    };
    assert_eq!(result["data"]["status"], 409, "{result}");
    assert_eq!(
        result["data"]["body"]["error"]["code"],
        "environment_transition_pending"
    );
    assert!(!result.to_string().contains("later user edit"));
    for suffix in [
        "/files",
        "/files/content?path=file.txt",
        "/git/status",
        "/git/log",
        "/panel/state",
        "/panel/context",
    ] {
        let denied = link
            .request(
                "fenced-panel-read",
                req("GET", &format!("{base}{suffix}"), Value::Null),
            )
            .await;
        assert_eq!(
            denied["data"]["body"]["error"]["code"], "environment_transition_pending",
            "{denied}"
        );
    }
    let peer = link
        .request(
            "peer-panel-read",
            req(
                "GET",
                &format!(
                    "/api/sessions/{}/files/content?path=file.txt",
                    sessions[1]["id"].as_str().unwrap()
                ),
                Value::Null,
            ),
        )
        .await;
    assert_eq!(peer["data"]["status"], 200, "{peer}");
    assert!(peer.to_string().contains("later user edit"));
    assert_eq!(
        fs::read_to_string(root.join("file.txt")).unwrap(),
        "later user edit\n"
    );
}
