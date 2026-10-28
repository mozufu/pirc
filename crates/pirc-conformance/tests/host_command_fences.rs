//! Real Node/Agent/PTC processes: Node-owned approval, ordinary Stop and a
//! durable transition drain share supervised host-command lifetimes.
mod node_link_side_support;
use node_link_side_support::{Gateway, last_message, models, registered, settled_in};
use pirc_conformance::{FakeGateway, LoneNode, NodeOptions};
use serde_json::{Value, json};
use std::{path::Path, time::Duration};

async fn approved(gw: &mut Gateway, session: &str, generation: &Value, key: &str, marker: &Path) {
    let sent = gw
        .prompt(
            session,
            generation,
            key,
            "Run the approved bounded host fixture",
        )
        .await;
    assert_eq!(sent["data"]["status"], 202, "{sent}");
    let start = gw.model_start().await;
    let args = json!({"command":format!("echo $$ > '{}'; exec /bin/sleep 30",marker.display()),"reason":"Local owned cancellation fixture","timeout":40});
    gw.reply_tool(
        &start,
        key,
        "ptc",
        json!({"code":format!("return await tools.call('unsandboxed_bash', {args});")}),
    )
    .await;
    let created = gw
        .take(|frame| {
            frame["type"] == "event"
                && frame["sessionId"] == session
                && frame["event"]["type"] == "interaction_created"
        })
        .await;
    assert!(!marker.exists(), "must wait for the human");
    let id = created["event"]["data"]["id"].as_str().unwrap();
    let answer = gw
        .ask(
            "POST",
            &format!("/api/sessions/{session}/interactions/{id}/answer"),
            Some(json!({"clientId":"browser","generation":generation,"answer":{"confirmed":true}})),
        )
        .await;
    assert_eq!(answer["data"]["status"], 200, "{answer}");
    tokio::time::timeout(Duration::from_secs(10), async {
        while !std::fs::read_to_string(marker).is_ok_and(|s| s.trim().parse::<u32>().is_ok()) {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("approved host command should start");
}

#[tokio::test(flavor = "multi_thread")]
async fn approved_host_commands_settle_before_stop_and_transition_acknowledgement() {
    let server = FakeGateway::bind().await;
    let Some(mut node) = LoneNode::start_with(
        server.port(),
        NodeOptions {
            env: vec![
                ("PIRC_BROWSER", "false".into()),
                ("TMPDIR", "{run_dir}".into()),
            ],
            ..Default::default()
        },
    ) else {
        return;
    };
    let mut gw = Gateway::new(server.accept().await);
    gw.link.recv().await;
    gw.link
        .send(&registered(models("fake", "fake-model", "low"), json!({})))
        .await;
    let (a, control) = gw.session().await;
    let (b, peer_control) = gw.session().await;
    let first = node.dir.path().join("workspace/host-first");
    approved(&mut gw, &a, &control, "first-host", &first).await;
    // Another session's inference must survive stopping the host owner.
    gw.prompt(&b, &peer_control, "peer", "Finish independently")
        .await;
    let peer = gw.model_start().await;
    let shared = node.dir.path().join("workspace/user.txt");
    std::fs::write(&shared, "user's later change").unwrap();
    gw.reply_tool(&peer, "peer-write-blocked", "ptc", json!({"code":"return await tools.call('write', {path:'user.txt',content:'must not overwrite'});"})).await;
    let peer = gw.model_start().await;
    assert!(
        last_message(&peer).to_string().contains("host command"),
        "{}",
        last_message(&peer)
    );
    assert_eq!(
        std::fs::read_to_string(&shared).unwrap(),
        "user's later change"
    );
    let first_pid = std::fs::read_to_string(&first).unwrap();
    let stopped = gw
        .command(&a, &control, "stop-host", json!({"type":"stop"}))
        .await;
    assert_eq!(stopped["data"]["status"], 202, "{stopped}");
    assert!(
        !std::process::Command::new("/bin/kill")
            .args(["-0", first_pid.trim()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success(),
        "Stop must await its owned host leader"
    );
    let repeated = gw
        .command(&a, &control, "stop-host", json!({"type":"stop"}))
        .await;
    assert_eq!(repeated["data"]["status"], 200, "{repeated}");
    assert_eq!(repeated["data"]["body"]["duplicate"], true);
    assert_eq!(repeated["data"]["body"]["command"]["status"], "accepted");
    // Once the observer settles, a fresh peer call may acquire the range.
    gw.reply_tool(&peer, "peer-write-after-stop", "ptc", json!({"code":"return await tools.call('write', {path:'peer-result.txt',content:'peer completed'});"})).await;
    let peer = gw.model_start().await;
    assert_eq!(
        std::fs::read_to_string(node.dir.path().join("workspace/peer-result.txt")).unwrap(),
        "peer completed"
    );
    assert_eq!(
        std::fs::read_to_string(&shared).unwrap(),
        "user's later change"
    );
    gw.reply_text(&peer, "Independent reply survived.").await;
    gw.take(settled_in(&b)).await;
    // Ordinary Stop retains a usable conversation, and a fresh command still
    // needs a fresh human approval. Then transition drain must join that command.
    let second = node.dir.path().join("workspace/host-second");
    approved(&mut gw, &a, &control, "second-host", &second).await;
    let second_pid = std::fs::read_to_string(&second).unwrap();
    let base = format!("/api/sessions/{a}");
    let before = gw.ask("GET", &format!("{base}/snapshot"), None).await;
    let fenced=gw.ask("POST",&format!("{base}/execution-fences"),Some(json!({"intent":{"operationId":"host-switch","planHash":"a".repeat(64),"expectedWorkspaceId":"test","expectedRunnerEpoch":before["data"]["body"]["session"]["runnerEpoch"]},"clientId":"browser","generation":control}))).await;
    assert_eq!(fenced["data"]["status"], 200, "{fenced}");
    let drained = gw
        .ask(
            "POST",
            &format!("{base}/execution-fences/host-switch/drain"),
            Some(json!({})),
        )
        .await;
    let receipt = &drained["data"]["body"]["transition"];
    assert_eq!(receipt["state"], "supervisor_drained", "{drained}");
    assert_eq!(receipt["hostCommands"]["launches"], 2);
    assert_eq!(receipt["hostCommands"]["observersSettled"], 2);
    assert_eq!(receipt["hostCommands"]["unresolved"], 0);
    assert_eq!(receipt["hostCommands"]["historyComplete"], false);
    assert_eq!(receipt["revocationConfirmed"], false);
    assert_eq!(receipt["targetInstalled"], false);
    assert!(
        !std::process::Command::new("/bin/kill")
            .args(["-0", second_pid.trim()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success(),
        "Drain must await its owned host leader"
    );
    node.restart(false);
    let mut gw = Gateway::new(server.accept().await);
    gw.link.recv().await;
    gw.link
        .send(&registered(models("fake", "fake-model", "low"), json!({})))
        .await;
    let saved = gw
        .ask("GET", &format!("{base}/execution-fences/host-switch"), None)
        .await;
    assert_eq!(
        saved["data"]["body"]["transition"]["hostCommands"],
        receipt["hostCommands"]
    );
    assert_eq!(std::fs::read_to_string(first).unwrap(), first_pid);
    assert_eq!(std::fs::read_to_string(second).unwrap(), second_pid);
}

#[tokio::test(flavor = "multi_thread")]
async fn crash_lost_host_observation_does_not_skip_terminal_shutdown_on_drain() {
    let server = FakeGateway::bind().await;
    let Some(mut node) = LoneNode::start_with(
        server.port(),
        NodeOptions {
            env: vec![
                ("PIRC_BROWSER", "false".into()),
                ("PIRC_TERMINAL_SHELL", "/bin/sh".into()),
                ("TMPDIR", "{run_dir}".into()),
            ],
            ..Default::default()
        },
    ) else {
        return;
    };
    let mut gw = Gateway::new(server.accept().await);
    gw.link.recv().await;
    gw.link
        .send(&registered(models("fake", "fake-model", "low"), json!({})))
        .await;
    let (source, control) = gw.session().await;
    let marker = node.dir.path().join("workspace/crash-host");
    approved(&mut gw, &source, &control, "crash-host", &marker).await;
    let pid = std::fs::read_to_string(&marker).unwrap();
    // Kill only this fixture's Node. Its durable host launch now has no observer;
    // the replacement Node must not manufacture a settled receipt or signal a PID
    // from that historical journal.
    node.restart(true);
    drop(gw);
    let mut gw = Gateway::new(server.accept().await);
    gw.link.recv().await;
    gw.link
        .send(&registered(models("fake", "fake-model", "low"), json!({})))
        .await;
    let base = format!("/api/sessions/{source}");
    let acquired = gw
        .ask(
            "POST",
            &format!("{base}/control/acquire"),
            Some(json!({"clientId":"browser","force":true})),
        )
        .await;
    assert_eq!(acquired["data"]["status"], 200, "{acquired}");
    let control = acquired["data"]["body"]["lease"]["generation"].clone();
    let (peer, peer_control) = gw.session().await;
    for (session, generation) in [(&source, &control), (&peer, &peer_control)] {
        let created = gw
            .ask(
                "POST",
                &format!("/api/sessions/{session}/terminals"),
                Some(json!({"clientId":"browser","generation":generation})),
            )
            .await;
        assert_eq!(created["data"]["status"], 201, "{created}");
    }
    let before = gw.ask("GET", &format!("{base}/snapshot"), None).await;
    let accepted = gw.ask("POST", &format!("{base}/execution-fences"), Some(json!({
        "intent":{"operationId":"lost-host","planHash":"c".repeat(64),"expectedWorkspaceId":"test",
        "expectedRunnerEpoch":before["data"]["body"]["session"]["runnerEpoch"]},
        "clientId":"browser","generation":control
    }))).await;
    assert_eq!(accepted["data"]["status"], 200, "{accepted}");
    let path = format!("{base}/execution-fences/lost-host");
    for _ in 0..2 {
        let drained = gw
            .ask("POST", &format!("{path}/drain"), Some(json!({})))
            .await;
        assert_eq!(drained["data"]["status"], 200, "{drained}");
        let receipt = &drained["data"]["body"]["transition"];
        assert_eq!(receipt["state"], "blocked", "{drained}");
        assert_eq!(receipt["errorCode"], "host_stop_unconfirmed");
        assert_eq!(receipt["hostCommands"]["unresolved"], 1);
        assert_eq!(receipt["terminals"]["observersSettled"], 1);
        assert_eq!(receipt["terminals"]["unresolved"], 0);
        assert_eq!(receipt["revocationConfirmed"], false);
        assert_eq!(receipt["targetInstalled"], false);
        let terminals = gw.ask("GET", &format!("{base}/terminals"), None).await;
        assert_eq!(terminals["data"]["body"]["terminals"], json!([]));
        let peer_terminals = gw
            .ask("GET", &format!("/api/sessions/{peer}/terminals"), None)
            .await;
        assert_eq!(
            peer_terminals["data"]["body"]["terminals"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }
    let denied = gw
        .ask(
            "POST",
            &format!("{base}/terminals"),
            Some(json!({"clientId":"browser","generation":control})),
        )
        .await;
    assert_eq!(denied["data"]["status"], 409, "{denied}");
    assert_eq!(
        denied["data"]["body"]["error"]["code"],
        "environment_transition_pending"
    );
    node.restart(false);
    drop(gw);
    let mut gw = Gateway::new(server.accept().await);
    gw.link.recv().await;
    gw.link
        .send(&registered(models("fake", "fake-model", "low"), json!({})))
        .await;
    let retained = gw.ask("GET", &path, None).await;
    assert_eq!(retained["data"]["body"]["transition"]["state"], "blocked");
    assert_eq!(
        retained["data"]["body"]["transition"]["hostCommands"]["unresolved"],
        1
    );
    assert_eq!(
        retained["data"]["body"]["transition"]["terminals"]["observersSettled"],
        1
    );
    assert_eq!(std::fs::read_to_string(&marker).unwrap(), pid);
    // The deliberately orphaned fixture command has a finite lifetime. Wait for
    // its own exit rather than leaving test work behind or killing by saved PID.
    tokio::time::timeout(Duration::from_secs(35), async {
        while std::process::Command::new("/bin/kill")
            .args(["-0", pid.trim()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success()
        {
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .expect("bounded fixture host command exits without journal-based signaling");
}
