//! The interaction watcher: a session that starts waiting for its user
//! pushes to them, and an answer updates every device's notification.

use std::sync::Arc;

use pirc_config::text::{is_space as js_space, utf16_len};
use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::{Category, Choice, InteractionPush, Push, PushMessage};
use crate::db::{Db, Store};
use crate::events::{EventHub, GatewayEvent};

/// At most this many options get buttons; the agent's "Other" option is not
/// counted ([`pirc_protocol::ASK_OTHER_LABEL`]).
pub(crate) const MAX_CHOICES: usize = 3;
/// An option longer than this (UTF-16 units) gets no button.
const MAX_CHOICE_UNITS: usize = 100;

/// The buttons of a question: only a single choice (`select`, not
/// `multiple`) with 1 to 3 short options, plus the agent's "Other" option
/// when it comes last (flagged `other`); any other question gets none.
pub fn single_choices(kind: &str, request: &Value) -> Vec<Choice> {
    if kind != "select"
        || request
            .get("multiple")
            .is_some_and(|multiple| multiple != false)
    {
        return Vec::new();
    }
    let Some(options) = request.get("options").and_then(Value::as_array) else {
        return Vec::new();
    };
    let other = options.last().and_then(Value::as_str) == Some(pirc_protocol::ASK_OTHER_LABEL);
    let counted = options.len() - usize::from(other);
    if counted == 0 || counted > MAX_CHOICES {
        return Vec::new();
    }
    let labels: Option<Vec<&str>> = options
        .iter()
        .map(|option| {
            option
                .as_str()
                .filter(|text| utf16_len(text) <= MAX_CHOICE_UNITS)
        })
        .collect();
    labels
        .map(|labels| {
            labels
                .into_iter()
                .enumerate()
                .map(|(index, label)| Choice {
                    id: label.to_owned(),
                    label: label.to_owned(),
                    other: other && index == counted,
                })
                .collect()
        })
        .unwrap_or_default()
}

/// `{deviceName, at}` for the client that answered, by the name its owner
/// sees for it; `None` without a client.
pub fn answered_by(
    conn: &rusqlite::Connection,
    owner: &str,
    client_id: Option<&str>,
    at: Option<i64>,
) -> Option<Value> {
    let client_id = client_id.filter(|id| !id.is_empty())?;
    let name = crate::clients::find(conn, owner, client_id)
        .ok()
        .flatten()
        .map_or_else(|| "Another device".to_owned(), |client| client.name);
    Some(json!({ "deviceName": name, "at": at }))
}

/// A session that starts waiting for its user (a dangerous command to
/// confirm, a question) pushes to them; the gateway's own confirmations (a
/// schedule to approve) count too (`watchInteractions`).
pub(super) fn waiting_message(
    conn: &rusqlite::Connection,
    session_id: &str,
    data: Option<&Value>,
) -> Option<(String, PushMessage)> {
    let session = conn.get_session(session_id).ok()?;
    let user = session.owner_user?;
    let request = data.and_then(|data| data.get("request"));
    let asked = request
        .and_then(|request| request.get("title"))
        .and_then(Value::as_str)
        .filter(|title| !title.trim_matches(js_space).is_empty());
    let interaction =
        exact_interaction_push("interaction_created", session_id, data).map(|mut interaction| {
            interaction.expires_at = data
                .and_then(|data| data.get("expiresAt"))
                .and_then(Value::as_i64);
            interaction.choices = single_choices(
                data.and_then(|data| data.get("kind"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                request.unwrap_or(&Value::Null),
            );
            interaction
        });
    Some((
        user,
        PushMessage {
            title: format!("{} is waiting for you", session.name),
            body: asked.unwrap_or("It needs your answer to go on.").to_owned(),
            tag: interaction
                .as_ref()
                .map(interaction_tag)
                .unwrap_or_else(|| format!("session:{}", session.id)),
            target: json!({ "sessionId": session.id }),
            category: Some(Category::NeedsYou),
            interaction,
        },
    ))
}

fn exact_interaction_push(
    kind: &'static str,
    session_id: &str,
    data: Option<&Value>,
) -> Option<InteractionPush> {
    let data = data?;
    let id_key = if kind == "interaction_created" {
        "id"
    } else {
        "interactionId"
    };
    let id = data.get(id_key)?.as_str()?.to_owned();
    if id.is_empty() {
        return None;
    }
    // `interactionEpoch` is copied from the row's `runnerEpoch`. The hub
    // envelope epoch is deliberately never used as a fallback.
    let epoch = data
        .get("interactionEpoch")
        .or_else(|| data.get("runnerEpoch"))?;
    let epoch = match epoch {
        Value::Number(number) => number.as_u64()?.to_string(),
        Value::String(text) => text.parse::<u64>().ok()?.to_string(),
        _ => return None,
    };
    Some(InteractionPush {
        kind,
        session_id: session_id.to_owned(),
        interaction_id: Some(id),
        interaction_epoch: Some(epoch),
        ..InteractionPush::default()
    })
}

pub(super) fn hex_utf8(text: &str) -> String {
    text.as_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn interaction_tag(interaction: &InteractionPush) -> String {
    format!(
        "interaction:{}:{}:{}",
        hex_utf8(&interaction.session_id),
        interaction.interaction_epoch.as_deref().unwrap_or_default(),
        hex_utf8(interaction.interaction_id.as_deref().unwrap_or_default()),
    )
}

pub(super) fn answered_message(
    conn: &rusqlite::Connection,
    session_id: &str,
    data: Option<&Value>,
) -> Option<(String, PushMessage)> {
    let session = conn.get_session(session_id).ok()?;
    let user = session.owner_user?;
    let interaction = exact_interaction_push("interaction_answered", session_id, data)
        .map(|mut interaction| {
            // The node names the answering client; other devices say who.
            interaction.answered_by = answered_by(
                conn,
                &user,
                data.and_then(|data| data.get("answeredBy"))
                    .and_then(Value::as_str),
                data.and_then(|data| data.get("resolvedAt"))
                    .and_then(Value::as_i64),
            );
            interaction
        })
        .or_else(|| {
            Some(InteractionPush {
                kind: "interaction_refresh",
                session_id: session_id.to_owned(),
                ..InteractionPush::default()
            })
        });
    let exact = interaction
        .as_ref()
        .is_some_and(|interaction| interaction.kind == "interaction_answered");
    Some((
        user,
        PushMessage {
            title: String::new(),
            body: String::new(),
            tag: if exact {
                interaction
                    .as_ref()
                    .map(interaction_tag)
                    .unwrap_or_default()
            } else {
                format!("session:{}", session.id)
            },
            target: json!({ "sessionId": session.id }),
            category: Some(Category::NeedsYou),
            interaction,
        },
    ))
}

/// Hand `interaction_created` events from the hub (whose listeners run
/// under its lock) to a task that pushes them, for as long as the hub lives.
pub(super) fn watch_interactions(events: &Arc<EventHub>, db: Arc<Db>, push: Arc<Push>) {
    let (sender, mut receiver) = mpsc::unbounded_channel();
    let subscription = events.subscribe_all(Arc::new(move |event: &GatewayEvent| {
        if matches!(
            event.kind.as_str(),
            "interaction_created" | "interaction_answered"
        ) {
            let _ = sender.send((
                event.session_id.clone(),
                event.kind.clone(),
                event.data.clone(),
            ));
        }
    }));
    tokio::spawn(async move {
        let _subscription = subscription;
        while let Some((session_id, kind, data)) = receiver.recv().await {
            let message = match kind.as_str() {
                "interaction_created" => waiting_message(&db.lock(), &session_id, data.as_ref()),
                "interaction_answered" => answered_message(&db.lock(), &session_id, data.as_ref()),
                _ => None,
            };
            if let Some((user, message)) = message {
                let push = push.clone();
                tokio::spawn(async move { push.notify(&user, &message).await });
            }
        }
    });
}
