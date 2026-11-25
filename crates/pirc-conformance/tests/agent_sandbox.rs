//! The `sandbox` feature without `ptc` scripts (docs/deploy/sandbox-and-browser.md):
//! its system prompt section in coding sessions and chats inside the
//! node's sandbox (`PIRC_SANDBOX=srt`), its tools' definitions through
//! `ptc_docs`, and its absence outside the sandbox. The tools run only from
//! `ptc` scripts (`agent_sandbox_ptc.rs`).

mod feature_support;

use feature_support::{Masker, tools, turn};
use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::json;

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_sandbox_prompt() {
    for (name, env, args) in [
        ("coding", vec![("PIRC_SANDBOX", "srt")], vec![]),
        ("unsandboxed", vec![("PIRC_SANDBOX", "none")], vec![]),
        (
            "without bash",
            vec![("PIRC_SANDBOX", "srt")],
            vec!["--tools", "read,ls,sandbox_allow_domains"],
        ),
    ] {
        let mut options = AgentOptions {
            args: args.into_iter().map(str::to_owned).collect(),
            ..AgentOptions::default()
        }
        .features("sandbox");
        options.env.extend(
            env.into_iter()
                .map(|(key, value)| (key.to_owned(), value.to_owned())),
        );
        let Some(mut agent) = AgentRun::start(options).await else {
            return;
        };
        let mut r = Recorder::new(&agent);
        let mut m = Masker::new();
        agent.push([
            tools(&[(
                "d1",
                "ptc_docs",
                json!({ "names": ["sandbox_allow_domains", "unsandboxed_bash"] }),
            )]),
            ModelReply::Text("Hi.".to_owned()),
        ]);
        turn(&mut agent, &mut m, &mut r, "prompt", "Hello").await;
        insta::assert_json_snapshot!(
            format!("agent_sandbox_prompt_{}", name.replace(' ', "_")),
            r.into_value()
        );
    }
}
