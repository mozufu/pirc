//! What the gateway does when its nodes report something
//! (`apps/gateway/src/daemon/app.ts`, "node link"): registration,
//! disconnection, session events and live activity.

use std::collections::HashMap;

use pirc_protocol::{NodeRole, SessionActivity, SessionRun};
use serde_json::{Map, Value, json};

use crate::app::App;
use crate::db::Store;
use crate::nodes::ConnectedNode;

/// A session's open run and write lease, as its node reported them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LiveActivity {
    pub run: Option<SessionRun>,
    pub write_lease: bool,
}

pub fn run_name(run: SessionRun) -> &'static str {
    match run {
        SessionRun::Queued => "queued",
        SessionRun::Running => "running",
        SessionRun::WaitingInput => "waiting_input",
        SessionRun::Stopping => "stopping",
    }
}

impl App {
    /// Browsers refresh their node and workspace lists (`directory=1`).
    pub fn directory_changed(&self) {
        self.hints.directory.notify(&());
    }

    /// The user's session list changed (`sessions=1`).
    pub fn sessions_changed(&self, user: Option<&str>) {
        if let Some(user) = user {
            self.hints.sessions.notify(&user.to_owned());
        }
    }

    pub fn pots_changed(&self, user: &str) {
        self.hints.pots.notify(&user.to_owned());
    }

    pub fn threads_changed(&self, user: &str) {
        self.hints.threads.notify(&user.to_owned());
    }

    pub fn approvals_changed(&self, user: &str) {
        self.hints.approvals.notify(&user.to_owned());
    }

    pub fn activity_changed(&self, user: &str) {
        self.hints.activity.notify(&user.to_owned());
    }

    pub fn budget_requests_changed(&self, user: &str) {
        self.hints.budget_requests.notify(&user.to_owned());
    }

    pub fn schedules_changed(&self, user: &str) {
        self.hints.schedules.notify(&user.to_owned());
    }

    /// The live activity of a session, if its node reported any.
    pub fn activity_of(&self, node_id: Option<&str>, session_id: &str) -> Option<LiveActivity> {
        let activity = self.activity.lock().unwrap_or_else(|p| p.into_inner());
        activity.get(node_id?)?.get(session_id).copied()
    }

    /// A chat node binds the gateway's assistant; a chat node's id cannot
    /// come back as a plain node.
    pub fn accept_node_role(&self, node_id: &str, role: NodeRole) -> bool {
        let conn = self.db.lock();
        let accepted = match role {
            NodeRole::Chat => conn.claim_assistant_node(node_id),
            NodeRole::Node => conn
                .assistant_node()
                .map(|bound| bound.as_deref() != Some(node_id)),
        };
        accepted.unwrap_or(false)
    }

    pub fn on_node_register(&self, node: &ConnectedNode) {
        let workspaces: Vec<_> = node
            .workspaces
            .iter()
            .map(|workspace| {
                (
                    workspace.id.clone(),
                    workspace.display_name.clone(),
                    workspace.mode.clone(),
                )
            })
            .collect();
        let repos: Vec<_> = node
            .workspaces
            .iter()
            .map(|workspace| {
                (
                    workspace.id.clone(),
                    workspace.repo.clone().filter(|_| {
                        self.mode(&workspace.mode)
                            .is_some_and(|mode| mode.repository)
                    }),
                )
            })
            .collect();
        let synced = {
            let conn = self.db.lock();
            conn.sync_remote_workspaces(&node.id, &workspaces)
                .and_then(|()| conn.set_workspace_repos(&node.id, &repos))
                .and_then(|()| {
                    for workspace in node
                        .workspaces
                        .iter()
                        .filter(|item| item.checkpoint_private)
                    {
                        conn.mark_checkpoint_workspace_private(&format!(
                            "{}:{}",
                            node.id, workspace.id
                        ))?;
                    }
                    Ok(())
                })
        };
        if let Err(error) = synced {
            crate::log::error(&format!("workspace sync of {}: {error}", node.id));
        }
        self.directory_changed();
        let sessions = self
            .db
            .lock()
            .remote_session_ids(&node.id)
            .unwrap_or_default();
        for session_id in sessions {
            let Ok(epoch) = self.db.lock().increment_epoch(&session_id) else {
                continue;
            };
            self.events.publish(
                &session_id,
                epoch,
                "node_reconnected",
                json!({ "nodeId": node.id }),
            );
        }
    }

    pub fn on_node_disconnect(&self, node_id: &str) {
        self.replace_activity(node_id, HashMap::new(), false);
        let sessions = self
            .db
            .lock()
            .remote_session_ids(node_id)
            .unwrap_or_default();
        for session_id in sessions {
            let epoch = {
                let conn = self.db.lock();
                let _ = conn.interrupt_remote_session(&session_id);
                let _ = conn.set_runner_state(&session_id, "failed");
                conn.get_session(&session_id)
                    .map(|session| session.runner_epoch)
            };
            if let Ok(epoch) = epoch {
                self.events.publish(
                    &session_id,
                    epoch,
                    "node_offline",
                    json!({ "nodeId": node_id }),
                );
            }
        }
        self.directory_changed();
    }

    pub fn on_node_event(&self, node_id: &str, remote_id: &str, event: Map<String, Value>) {
        let Ok(Some(session_id)) = self.db.lock().resolve_remote_session(node_id, remote_id) else {
            return;
        };
        let Ok(session) = self.db.lock().get_session(&session_id) else {
            return;
        };
        if session.node_id.as_deref() != Some(node_id) {
            return;
        }
        let kind = event.get("type").and_then(Value::as_str);
        let data = event.get("data").cloned();
        // `typeof data === 'object'`: arrays too (they carry no name).
        if kind == Some("session_renamed")
            && let Some(data @ (Value::Object(_) | Value::Array(_))) = &data
        {
            if let Value::Object(data) = data {
                self.apply_session_name(&session_id, session.runner_epoch, data);
            }
            self.sessions_changed(session.owner_user.as_deref());
        } else if kind == Some("checkpoints_changed") {
            self.events.publish(
                &session_id,
                session.runner_epoch,
                "checkpoints_changed",
                json!({ "sessionId": session_id }),
            );
        } else if let Some(kind) = kind {
            // An absent `data` stays absent, as `undefined` did.
            self.events
                .publish_optional(&session_id, session.runner_epoch, kind, data);
        }
    }

    /// Persist a name reported by the agent (or set by the user) and tell
    /// clients. A generated (`auto`) title never replaces a user's name.
    pub fn apply_session_name(&self, session_id: &str, epoch: i64, data: &Map<String, Value>) {
        // `name.trim().slice(0, 200)`: JS whitespace, UTF-16 units.
        let trimmed = data
            .get("name")
            .and_then(Value::as_str)
            .map(|name| name.trim_matches(pirc_config::text::is_space))
            .unwrap_or_default();
        let units: Vec<u16> = trimmed.encode_utf16().take(200).collect();
        let name = String::from_utf16_lossy(&units);
        if name.is_empty() {
            return;
        }
        let auto = data.get("source").and_then(Value::as_str) == Some("auto");
        {
            let conn = self.db.lock();
            if auto {
                if !conn.auto_rename_session(session_id, &name).unwrap_or(false) {
                    return;
                }
            } else {
                let Ok(session) = conn.get_session(session_id) else {
                    return;
                };
                if session.name == name && session.name_source == "user" {
                    return;
                }
                if conn.rename_session(session_id, &name).is_err() {
                    return;
                }
            }
        }
        self.events.publish(
            session_id,
            epoch,
            "session_renamed",
            json!({ "name": name, "source": if auto { "auto" } else { "user" } }),
        );
    }

    pub fn on_node_activity(&self, node_id: &str, sessions: &[SessionActivity]) {
        let mut next = HashMap::new();
        for item in sessions {
            if let Ok(Some(session_id)) = self.db.lock().resolve_remote_session(node_id, &item.id) {
                next.insert(
                    session_id,
                    LiveActivity {
                        run: item.run,
                        write_lease: item.write_lease.unwrap_or(false),
                    },
                );
            }
        }
        self.replace_activity(node_id, next, true);
    }

    /// `settled`: the node reported its runs, so a run it no longer lists
    /// has finished; a disconnect only forgets them (interrupted, not done).
    fn replace_activity(&self, node_id: &str, next: HashMap<String, LiveActivity>, settled: bool) {
        let before = {
            let mut activity = self.activity.lock().unwrap_or_else(|p| p.into_inner());
            let before = activity.remove(node_id).unwrap_or_default();
            if !next.is_empty() {
                activity.insert(node_id.to_owned(), next.clone());
            }
            before
        };
        let mut sessions: Vec<&String> = before.keys().chain(next.keys()).collect();
        sessions.sort();
        sessions.dedup();
        let mut owners = Vec::new();
        for session_id in sessions {
            let a = before.get(session_id).copied().unwrap_or_default();
            let b = next.get(session_id).copied().unwrap_or_default();
            if a == b {
                continue;
            }
            // Something for the user to read: the run finished, or it asks a question.
            let finished = settled && a.run.is_some() && b.run.is_none();
            let asks =
                b.run == Some(SessionRun::WaitingInput) && a.run != Some(SessionRun::WaitingInput);
            let conn = self.db.lock();
            if finished || asks {
                let _ = conn.mark_session_activity(session_id);
            }
            if let Ok(session) = conn.get_session(session_id)
                && let Some(owner) = session.owner_user
                && !owners.contains(&owner)
            {
                owners.push(owner);
            }
        }
        for owner in owners {
            self.sessions_changed(Some(&owner));
        }
    }
}
