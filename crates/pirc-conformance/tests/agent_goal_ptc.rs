//! The goal tools (`create_goal`, `get_goal`, `update_goal`) called from
//! `ptc` scripts, as `agent-goal.test.ts` calls them: rounds until the
//! model completes the goal, the round limit, the authority rules during
//! continuation rounds, blocked goals, and the tools in a session without
//! goals. Needs the `ptc` runtime (docs/architecture/ptc.md).

mod feature_support;

use feature_support::{
    Masker, notified, ptc, ptc_call, settle, settle_events, then, turn, turn_events,
};
use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

fn goal_options(config: Value) -> AgentOptions {
    AgentOptions {
        config,
        ..AgentOptions::default()
    }
    .features("goal")
}

/// A script calling capabilities in order through `tools.call`, returning
/// every outcome as JSON. `{goal}` in an argument object stands for the
/// current goal's reference (`goal_id`, `revision`).
fn calls(steps: &[(&str, &str)]) -> String {
    let mut code = String::from(
        "const out = [];\nconst ref = async () => { const g = (await tools.call('get_goal', {})).data.goal; return g ? { goal_id: g.id, revision: g.revision } : {}; };\n",
    );
    for (name, args) in steps {
        let args = args.replace("{goal}", "...(await ref())");
        code.push_str(&format!(
            "out.push(await tools.call({}, {args}));\n",
            json!(name)
        ));
    }
    code.push_str(
        "return JSON.stringify(out.map((r) => r.ok ? { text: r.data.text, goal: r.data.goal, armed: r.data.armed } : { error: r.error }));",
    );
    code
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_goal_ptc_complete() {
    let Some(mut agent) = AgentRun::start(goal_options(json!({}))).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut m = Masker::new();
    agent.push([
        ptc_call("c1", "create_goal", json!({ "objective": "Ship feature X" })),
        ModelReply::Text("First slice done.".to_owned()),
        // Round 1: the model reads the goal and completes it.
        ptc(
            "u1",
            "const g = await tools.get_goal({});\nconst r = await tools.update_goal({ goal_id: g.goal.id, revision: g.goal.revision, action: 'complete' });\nreturn r.text;",
        ),
        ModelReply::Text("All done.".to_owned()),
    ]);
    turn_events(
        &mut agent,
        &mut m,
        &mut r,
        "prompt",
        "Build feature X until it ships",
    )
    .await;
    settle(&mut agent, &mut m, &mut r, "round 1").await;
    // Complete: no further round.
    let state = agent.call(json!({ "type": "get_state" })).await;
    m.note(&mut r, "state", state);
    m.session(&mut r, &agent);
    insta::assert_json_snapshot!(
        "agent_goal_ptc_complete",
        feature_support::without_ptc_progress(r.into_value())
    );
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_goal_ptc_limit() {
    let Some(mut agent) = AgentRun::start(goal_options(json!({}))).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut m = Masker::new();
    agent.push([
        ptc_call(
            "c1",
            "create_goal",
            json!({ "objective": "Loop", "max_goal_rounds": 2 }),
        ),
        ModelReply::Text("Start.".to_owned()),
        ModelReply::Text("Round one.".to_owned()),
        ModelReply::Text("Round two.".to_owned()),
    ]);
    turn_events(&mut agent, &mut m, &mut r, "prompt", "Loop").await;
    settle_events(&mut agent, &mut m, &mut r, "round 1").await;
    settle(&mut agent, &mut m, &mut r, "round 2").await;
    then(&mut agent, &mut m, &mut r, "paused at the limit", |line| {
        notified(line, "Goal paused")
    })
    .await;
    m.session(&mut r, &agent);
    insta::assert_json_snapshot!(
        "agent_goal_ptc_limit",
        feature_support::without_ptc_progress(r.into_value())
    );
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_goal_ptc_authority() {
    let Some(mut agent) = AgentRun::start(goal_options(
        json!({ "features": { "goal": { "minBlockedRounds": 2 } } }),
    ))
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut m = Masker::new();
    agent.push([
        ModelReply::TextAndTools(
            "Setting it up.".to_owned(),
            vec![(
                "c1".to_owned(),
                "ptc".to_owned(),
                json!({ "code": calls(&[
                    ("get_goal", "{}"),
                    ("create_goal", "{ objective: '  Hard thing\\r\\n', max_goal_rounds: 1 }"),
                    ("create_goal", "{ objective: 'Another' }"),
                    ("update_goal", "{ goal_id: 'nope', revision: 1, action: 'pause' }"),
                    ("update_goal", "{ ...(await ref()), action: 'complete', objective: 'x' }"),
                    ("update_goal", "{ ...(await ref()), action: 'pause', blocked_reason: 'x' }"),
                    ("update_goal", "{ ...(await ref()), action: 'resume' }"),
                    ("update_goal", "{ ...(await ref()), action: 'edit' }"),
                ]) }),
            )],
        ),
        ModelReply::Text("Started.".to_owned()),
        // Round 1: human-only actions are refused, blocked comes too early.
        ptc(
            "r1",
            &calls(&[
                ("update_goal", "{ {goal}, action: 'pause' }"),
                (
                    "update_goal",
                    "{ {goal}, action: 'edit', objective: 'Easier' }",
                ),
                ("update_goal", "{ {goal}, action: 'resume' }"),
                (
                    "update_goal",
                    "{ {goal}, action: 'blocked', blocked_reason: 'stuck' }",
                ),
                ("create_goal", "{ objective: 'Another' }"),
            ]),
        ),
        ModelReply::Text("Still working.".to_owned()),
    ]);
    turn_events(&mut agent, &mut m, &mut r, "prompt", "Do the hard thing").await;
    settle(&mut agent, &mut m, &mut r, "round 1").await;
    then(&mut agent, &mut m, &mut r, "paused at the limit", |line| {
        notified(line, "Goal paused")
    })
    .await;
    // The user asks: resuming at the limit is refused until the limit
    // rises; then round 2 may report the blocker.
    agent.push([
        ptc(
            "h1",
            &calls(&[
                ("update_goal", "{ {goal}, action: 'resume' }"),
                ("update_goal", "{ {goal}, action: 'edit', max_goal_rounds: 3 }"),
                ("update_goal", "{ {goal}, action: 'resume' }"),
                ("update_goal", "{ {goal}, action: 'resume' }"),
            ]),
        ),
        ModelReply::Text("Resumed.".to_owned()),
        ptc(
            "r2",
            &calls(&[
                ("update_goal", "{ {goal}, action: 'blocked' }"),
                (
                    "update_goal",
                    "{ {goal}, action: 'blocked', blocked_reason: '  The API key is missing.\\r\\n' }",
                ),
            ]),
        ),
        ModelReply::Text("Blocked.".to_owned()),
    ]);
    turn_events(
        &mut agent,
        &mut m,
        &mut r,
        "the user resumes",
        "Raise the limit to 3 and go on",
    )
    .await;
    settle(&mut agent, &mut m, &mut r, "round 2").await;
    // A blocked goal is not open: the user may start another one.
    agent.push([
        ptc(
            "h2",
            &calls(&[
                ("get_goal", "{}"),
                ("create_goal", "{ objective: 'Plan B', max_goal_rounds: 1 }"),
            ]),
        ),
        ModelReply::Text("Plan B.".to_owned()),
        ModelReply::Text("Round one of plan B.".to_owned()),
    ]);
    turn_events(&mut agent, &mut m, &mut r, "a new goal", "Try plan B").await;
    settle(&mut agent, &mut m, &mut r, "plan B round 1").await;
    then(&mut agent, &mut m, &mut r, "plan B paused", |line| {
        notified(line, "Goal paused")
    })
    .await;
    m.session(&mut r, &agent);
    let value = feature_support::without_ptc_progress(r.into_value());
    insta::assert_json_snapshot!("agent_goal_ptc_authority", value);
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_goal_ptc_disabled() {
    let Some(mut agent) = AgentRun::start(goal_options(
        json!({ "features": { "goal": { "enabled": false } } }),
    ))
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut m = Masker::new();
    agent.push([
        ptc_call("c1", "create_goal", json!({ "objective": "Nope" })),
        ModelReply::Text("Hi.".to_owned()),
    ]);
    turn(&mut agent, &mut m, &mut r, "prompt", "Hello").await;
    insta::assert_json_snapshot!(
        "agent_goal_ptc_disabled",
        feature_support::without_ptc_progress(r.into_value())
    );
}
