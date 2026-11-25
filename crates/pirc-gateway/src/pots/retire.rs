//! Archive and delete (plans/pots.md, Handover, pause, archive, delete).
//!
//! First each item the pot holds gets a target (another pot, the user, or
//! none) and the preview shows what moves, what stops and what is kept; then,
//! in order: hand over, drop what has no target, fail the queued wakes, and
//! archive, or delete the pot's session and the pot. Restoring an archived pot
//! does not take handed-over items back.
//!
//! A deleted pot's activity, messages, direct and DM threads keep its name
//! until the owner's activity retention removes them.

use std::collections::BTreeMap;

use rusqlite::{Connection, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::activity::{self, Counterpart, Entry, Kind};
use super::handover::{self, Held, ItemKind, ItemRef, NewHandover, ProposedBy, To};
use super::store::{self, PotState};
use crate::error::{ApiError, ApiResult};
use crate::util::now_ms;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Archive,
    Delete,
}

/// Where one held item goes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum Target {
    Pot { pot_id: String },
    User,
    None,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ItemTarget {
    pub kind: ItemKind,
    pub r#ref: String,
    pub to: Target,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Plan {
    pub mode: Mode,
    /// Items without a target go nowhere.
    #[serde(default)]
    pub targets: Vec<ItemTarget>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Retire {
    pub mode: Mode,
    pub revision: i64,
    #[serde(default)]
    pub targets: Vec<ItemTarget>,
}

fn target_of<'a>(targets: &'a [ItemTarget], item: &Held) -> &'a Target {
    targets
        .iter()
        .find(|t| t.kind == item.kind && t.r#ref == item.r#ref)
        .map_or(&Target::None, |t| &t.to)
}

fn check_targets(held: &[Held], targets: &[ItemTarget]) -> ApiResult<()> {
    for target in targets {
        if !held
            .iter()
            .any(|h| h.kind == target.kind && h.r#ref == target.r#ref)
        {
            return Err(ApiError::new(
                400,
                "invalid_input",
                "Targets must name what the pot holds",
            ));
        }
    }
    Ok(())
}

/// What happens to an item that goes nowhere.
fn dropped(item: &Held, mode: Mode) -> &'static str {
    match (item.kind, mode) {
        (ItemKind::Responsibility, Mode::Archive) => "stays with the archived pot",
        (ItemKind::Responsibility, Mode::Delete) => "is removed",
        (ItemKind::Reminder, _) => "is cancelled",
        (ItemKind::Work, _) => "goes on without a pot; you take it over",
        (ItemKind::GroupHost, _) => "the group has no host",
    }
}

/// The preview: each item's fit at its target, what stops, what is kept.
pub fn preview(conn: &Connection, owner: &str, pot_id: &str, plan: &Plan) -> ApiResult<Value> {
    let pot = store::read(conn, owner, pot_id)?;
    let held = handover::held(conn, owner, pot_id)?;
    check_targets(&held, &plan.targets)?;
    let mut items = Vec::new();
    let mut groups: BTreeMap<String, (To, Vec<ItemRef>)> = BTreeMap::new();
    for item in &held {
        match target_of(&plan.targets, item) {
            Target::None => items.push(json!({
                "kind": item.kind, "ref": item.r#ref, "label": item.label,
                "to": { "kind": "none" }, "fit": "stop", "reason": dropped(item, plan.mode),
            })),
            target => {
                let to = match target {
                    Target::Pot { pot_id } => To::Pot {
                        pot_id: pot_id.clone(),
                    },
                    _ => To::User,
                };
                let key = serde_json::to_string(&to).expect("targets serialize");
                groups
                    .entry(key)
                    .or_insert_with(|| (to, Vec::new()))
                    .1
                    .push(ItemRef {
                        kind: item.kind,
                        r#ref: item.r#ref.clone(),
                    });
            }
        }
    }
    // Fits come from a handover proposal that is never saved.
    let sp = conn.unchecked_transaction()?;
    for (to, refs) in groups.into_values() {
        let proposed = handover::propose(
            &sp,
            owner,
            NewHandover {
                from_pot_id: pot_id.to_owned(),
                to: to.clone(),
                items: Some(refs),
                reason: String::new(),
            },
            ProposedBy::User,
        )?;
        for item in proposed.items {
            items.push(json!({
                "kind": item.kind, "ref": item.r#ref, "label": item.label,
                "to": to, "fit": item.fit, "reason": item.reason,
            }));
        }
    }
    sp.rollback()?;
    let queued: i64 = conn.query_row(
        "SELECT count(*) FROM pot_wakes WHERE pot_id=?1 AND state='queued'",
        [pot_id],
        |r| r.get(0),
    )?;
    let mut stops = vec![format!("{queued} waiting messages and events are dropped")];
    let mut kept = vec!["Its activity and its messages in threads, with its name, until your retention removes them".to_owned()];
    match plan.mode {
        Mode::Archive => {
            stops.push(format!(
                "{} takes no wakes and does nothing until restored",
                pot.input.profile.name
            ));
            kept.push("Its personality, settings and memory; restoring does not take handed-over items back".to_owned());
        }
        Mode::Delete => {
            stops.push("Its session, memory, personality and settings are deleted".to_owned());
        }
    }
    Ok(
        json!({ "mode": plan.mode, "revision": pot.revision, "items": items, "stops": stops, "kept": kept }),
    )
}

/// What retiring did, and what to do once the transaction is committed.
#[derive(Debug)]
pub struct Retired {
    pub result: Value,
    /// Pots that received items, to kick.
    pub woken: Vec<String>,
    /// The deleted pot's session, to delete on its node.
    pub session_id: Option<String>,
}

/// Apply a retire plan in one transaction.
pub fn retire(
    conn: &mut Connection,
    owner: &str,
    pot_id: &str,
    input: Retire,
) -> ApiResult<Retired> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let pot = store::read(&tx, owner, pot_id)?;
    if pot.revision != input.revision {
        return Err(ApiError::new(
            409,
            "revision_conflict",
            "The pot changed; read it again",
        ));
    }
    if pot.state == PotState::Archived && input.mode == Mode::Archive {
        return Err(ApiError::new(
            409,
            "invalid_transition",
            "The pot is already archived",
        ));
    }
    let held = handover::held(&tx, owner, pot_id)?;
    check_targets(&held, &input.targets)?;
    // 1. Hand over, one handover per receiver.
    let mut groups: BTreeMap<String, (To, Vec<ItemRef>)> = BTreeMap::new();
    let mut nowhere = Vec::new();
    for item in &held {
        match target_of(&input.targets, item) {
            Target::None => nowhere.push(item.clone()),
            target => {
                let to = match target {
                    Target::Pot { pot_id } => To::Pot {
                        pot_id: pot_id.clone(),
                    },
                    _ => To::User,
                };
                let key = serde_json::to_string(&to).expect("targets serialize");
                groups
                    .entry(key)
                    .or_insert_with(|| (to, Vec::new()))
                    .1
                    .push(ItemRef {
                        kind: item.kind,
                        r#ref: item.r#ref.clone(),
                    });
            }
        }
    }
    let mut handovers = Vec::new();
    let mut woken = Vec::new();
    for (to, refs) in groups.into_values() {
        let proposed = handover::propose(
            &tx,
            owner,
            NewHandover {
                from_pot_id: pot_id.to_owned(),
                to,
                items: Some(refs),
                reason: String::new(),
            },
            ProposedBy::User,
        )?;
        let (applied, kick) = handover::apply(&tx, owner, &proposed.id, proposed.revision)?;
        handovers.push(applied);
        woken.extend(kick);
    }
    // 2. What has no target.
    for item in &nowhere {
        match item.kind {
            ItemKind::Responsibility => {}
            ItemKind::Reminder => {
                tx.execute(
                    "DELETE FROM pot_reminders WHERE id=?1 AND pot_id=?2",
                    params![item.r#ref, pot_id],
                )?;
            }
            ItemKind::Work => {
                tx.execute(
                    "UPDATE pot_works SET state='taken_over', updated_at=?2 WHERE id=?1",
                    params![item.r#ref, now_ms()],
                )?;
                super::observe::release_work(&tx, &item.r#ref)?;
            }
            ItemKind::GroupHost => {
                tx.execute(
                    "UPDATE threads SET host_pot_id=NULL WHERE id=?1 AND host_pot_id=?2",
                    params![item.r#ref, pot_id],
                )?;
            }
        }
    }
    // 3. Nothing more reaches it.
    let why = match input.mode {
        Mode::Archive => "The pot was archived",
        Mode::Delete => "The pot was deleted",
    };
    tx.execute(
        "UPDATE pot_wakes SET state='failed', error=?2, settled_at=?3 WHERE pot_id=?1 AND state='queued'",
        params![pot_id, why, now_ms()],
    )?;
    let name = pot.input.profile.name.clone();
    let result = match input.mode {
        Mode::Archive => {
            tx.execute(
                "UPDATE pots SET state='archived', revision=revision+1, updated_at=?2 WHERE id=?1",
                params![pot_id, now_ms()],
            )?;
            activity::log(
                &tx,
                owner,
                pot_id,
                Entry::new(Kind::Archived, format!("The user archived {name}"))
                    .toward(Counterpart::User),
            )?;
            json!({ "pot": store::read(&tx, owner, pot_id)?, "handovers": handovers })
        }
        Mode::Delete => {
            activity::log(
                &tx,
                owner,
                pot_id,
                Entry::new(Kind::Deleted, format!("The user deleted {name}"))
                    .toward(Counterpart::User),
            )?;
            // What outlives the pot keeps its name.
            tx.execute(
                "UPDATE messages SET author_name=?2 WHERE author_kind='pot' AND author_id=?1",
                params![pot_id, name],
            )?;
            tx.execute(
                "UPDATE threads SET name=?2 WHERE kind='direct' AND pot_a=?1",
                params![pot_id, name],
            )?;
            tx.execute(
                "UPDATE threads SET name=COALESCE(NULLIF(name,''), ?2) WHERE kind='pot_dm' AND (pot_a=?1 OR pot_b=?1)",
                params![pot_id, format!("{name} (deleted)")],
            )?;
            tx.execute(
                "DELETE FROM pots WHERE id=?1 AND owner_user=?2",
                params![pot_id, owner],
            )?;
            json!({ "deleted": true, "handovers": handovers })
        }
    };
    tx.commit()?;
    Ok(Retired {
        result,
        woken,
        session_id: match input.mode {
            Mode::Delete => pot.session_id,
            Mode::Archive => None,
        },
    })
}

/// Threads left by deleted pots, older than the owner's retention.
pub fn sweep(conn: &Connection, now: i64) -> rusqlite::Result<usize> {
    conn.execute(
        "DELETE FROM threads
         WHERE ((kind='direct' AND pot_a IS NULL) OR (kind='pot_dm' AND (pot_a IS NULL OR pot_b IS NULL)))
           AND updated_at < ?1 - 86400000 * COALESCE(
             (SELECT activity_retention_days FROM pot_settings s WHERE s.owner_user=threads.owner_user), 90)",
        [now],
    )
}
