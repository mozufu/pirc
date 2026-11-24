//! Actual Web client + IndexedDB against the real Gateway, Node and Agent.
//! Explicit browser acceptance; see docs/development/first-send-acceptance.md.
mod conversation_clients_support;
use conversation_clients_support::{ClientProcess, verify};
use pirc_conformance::{CHATS_WORKSPACE_ID, Cluster, GatewayOptions, HOST, ORIGIN, Reply, USER};
use serde_json::json;
use std::fs::{self, File};
use std::path::Path;
use std::process::{Command, Stdio};

#[tokio::test(flavor = "multi_thread")]
#[ignore = "requires installed Web dependencies and a dedicated Headless Shell; run the documented live Web acceptance command"]
async fn web_reconciles_lost_reply_and_local_commit_after_browser_and_hosts_restart() {
    let mut cluster = Cluster::start_with(GatewayOptions {
        chat_node: true,
        agent_core_only: true,
        ..Default::default()
    })
    .await
    .expect("set PIRC_CONFORMANCE_BIN_DIR to the Gateway/Node executables");
    cluster.llm.push([
        Reply::Text("First completed once".into()),
        Reply::Text("Second completed once".into()),
        Reply::Text("Third completed once".into()),
    ]);
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let directory = cluster.dir.path().join("web-acceptance");
    fs::create_dir(&directory).unwrap();
    let config = directory.join("config.json");
    fs::write(
        &config,
        serde_json::to_vec(&json!({
            "gateway": format!("http://127.0.0.1:{}", cluster.port),
            "host": HOST, "origin": ORIGIN, "owner": USER,
            "workspace": CHATS_WORKSPACE_ID, "directory": directory,
        }))
        .unwrap(),
    )
    .unwrap();
    let log = directory.join("browser.log");
    let output = File::create(&log).unwrap();
    let mut browser = ClientProcess {
        child: Command::new(std::env::var_os("PIRC_TEST_NODE").unwrap_or_else(|| "node".into()))
            .current_dir(root)
            .arg("scripts/first-send-browser.mjs")
            .arg(config)
            .stdin(Stdio::null())
            .stdout(output.try_clone().unwrap())
            .stderr(output)
            .spawn()
            .unwrap(),
        log,
    };
    let pending = browser.stage(&directory, "before-restart").await;
    let operations = pending["operations"].as_array().unwrap();
    assert_eq!(operations.len(), 3);
    let commands = verify(&cluster, operations).await;
    cluster.restart_node(true).await;
    cluster.restart_gateway(true).await;
    fs::write(directory.join("hosts-restarted.json"), b"{}").unwrap();
    let result = browser.stage(&directory, "result").await;
    browser.finish().await;
    assert_eq!(result["readOnlyAfterRestart"], true);
    assert_eq!(result["operations"], pending["operations"]);
    assert_eq!(verify(&cluster, operations).await, commands);
}
