//! Handover (plans/pots.md, Handover, pause, archive, delete): moving a pot's
//! responsibilities, pending reminders, coordinated works and group host roles
//! to another pot or to the user.
//!
//! Each item gets a fit against the receiver when proposed and again when
//! applied: `ok`, `narrowed` (it goes on with what the receiver may do) or
//! `stop` (it cannot continue there). Nothing grants permissions. A pot may
//! propose; only the user confirms. Loop-guard rule 1: a pot may not hand an
//! item to a pot that held it within the owner's cooldown (the user may).

use rusqlite::{Connection, OptionalExtension, Row, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::activity::{self, Counterpart, Entry, Kind, Refs};
use super::runtime::{self, NewWake, Source};
use super::store::{self, Access, Pot, PotState, Reach};
use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms};

const MAX_REASON: usize = 2000;
const MAX_RESPONSIBILITIES: i64 = 50;

fn invalid(message: &str) -> ApiError {
    ApiError::new(400, "invalid_input", message)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemKind {
    Responsibility,
    Reminder,
    Work,
    GroupHost,
}

impl ItemKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Responsibility => "responsibility",
            Self::Reminder => "reminder",
            Self::Work => "work",
            Self::GroupHost => "group_host",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "responsibility" => Self::Responsibility,
            "reminder" => Self::Reminder,
            "work" => Self::Work,
            "group_host" => Self::GroupHost,
            _ => return None,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Fit {
    Ok,
    Narrowed,
    Stop,
}

impl Fit {
    fn as_str(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Narrowed => "narrowed",
            Self::Stop => "stop",
        }
    }

    fn parse(text: &str) -> Self {
        match text {
            "ok" => Self::Ok,
            "narrowed" => Self::Narrowed,
            _ => Self::Stop,
        }
    }
}

/// Who receives a handover.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum To {
    Pot { pot_id: String },
    User,
}

/// One thing a pot holds.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Held {
    pub kind: ItemKind,
    pub r#ref: String,
    pub label: String,
}

/// What a pot holds that a handover can move.
pub fn held(conn: &Connection, owner: &str, pot_id: &str) -> ApiResult<Vec<Held>> {
    store::read(conn, owner, pot_id)?;
    let mut out = Vec::new();
    let mut add = |kind: ItemKind, sql: &str| -> ApiResult<()> {
        let rows: Vec<(String, String)> = conn
            .prepare(sql)?
            .query_map([pot_id], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<Result<_, _>>()?;
        out.extend(
            rows.into_iter()
                .map(|(r#ref, label)| Held { kind, r#ref, label }),
        );
        Ok(())
    };
    add(
        ItemKind::Responsibility,
        "SELECT id, title FROM pot_responsibilities WHERE pot_id=?1 ORDER BY position",
    )?;
    add(
        ItemKind::Reminder,
        "SELECT id, note FROM pot_reminders WHERE pot_id=?1 AND state='pending' ORDER BY due_at",
    )?;
    add(
        ItemKind::Work,
        "SELECT id, title FROM pot_works WHERE pot_id=?1 AND state='open' ORDER BY created_at",
    )?;
    add(
        ItemKind::GroupHost,
        "SELECT id, name FROM threads WHERE host_pot_id=?1 AND kind='group' ORDER BY created_at",
    )?;
    Ok(out)
}

fn reach_rank(reach: Reach) -> u8 {
    match reach {
        Reach::Answer => 0,
        Reach::Observe => 1,
        Reach::Work => 2,
    }
}

/// Where an item can go, and why not.
fn fit(
    conn: &Connection,
    from: &Pot,
    item: &Held,
    to: &To,
    receiver: Option<&Pot>,
) -> ApiResult<(Fit, Option<String>)> {
    let Some(receiver) = receiver else {
        // To the user: works are taken over; the rest has no place.
        return Ok(match item.kind {
            ItemKind::Work => (Fit::Ok, None),
            ItemKind::Responsibility => (
                Fit::Stop,
                Some("The user does not hold a pot's responsibilities".into()),
            ),
            ItemKind::Reminder => (Fit::Stop, Some("The reminder ends".into())),
            ItemKind::GroupHost => (Fit::Stop, Some("A group is hosted by a pot".into())),
        });
    };
    debug_assert!(matches!(to, To::Pot { .. }));
    let permissions = &receiver.input.permissions;
    Ok(match item.kind {
        ItemKind::Responsibility => {
            if reach_rank(permissions.reach) < reach_rank(from.input.permissions.reach) {
                (
                    Fit::Narrowed,
                    Some(format!("{} may do less", receiver.input.profile.name)),
                )
            } else {
                (Fit::Ok, None)
            }
        }
        ItemKind::Reminder => (Fit::Ok, None),
        ItemKind::Work => {
            let workspace: Option<String> = conn
                .query_row(
                    "SELECT workspace_id FROM pot_works WHERE id=?1",
                    [&item.r#ref],
                    |r| r.get(0),
                )
                .optional()?;
            let allowed = permissions.reach == Reach::Work
                && workspace.is_some_and(|workspace| {
                    permissions
                        .work_locations
                        .iter()
                        .any(|l| l.workspace_id == workspace && l.access == Access::Write)
                });
            if allowed {
                (Fit::Ok, None)
            } else {
                (
                    Fit::Stop,
                    Some(format!(
                        "{} may not work there",
                        receiver.input.profile.name
                    )),
                )
            }
        }
        ItemKind::GroupHost => {
            let member: bool = conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM thread_members WHERE thread_id=?1 AND pot_id=?2)",
                params![item.r#ref, receiver.id],
                |r| r.get(0),
            )?;
            if member {
                (Fit::Ok, None)
            } else {
                (
                    Fit::Stop,
                    Some(format!(
                        "{} is not in the group",
                        receiver.input.profile.name
                    )),
                )
            }
        }
    })
}

/// How an item is recognised across handovers: responsibilities by title (their
/// ids change when the pot is edited), the rest by id.
fn item_key(item: &Held) -> String {
    match item.kind {
        ItemKind::Responsibility => format!("responsibility:{}", item.label),
        kind => format!("{}:{}", kind.as_str(), item.r#ref),
    }
}

/// Loop-guard rule 1: `receiver` held this item within the cooldown.
fn handed_back(conn: &Connection, owner: &str, receiver: &str, key: &str) -> ApiResult<bool> {
    let cooldown_s = store::settings(conn, owner)?.handback_cooldown_s as i64;
    Ok(conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM pot_handover_items i JOIN pot_handovers h ON h.id=i.handover_id
          WHERE h.owner_user=?1 AND h.state='applied' AND h.from_pot_id=?2 AND i.item_key=?3
            AND i.fit!='stop' AND h.applied_at>=?4)",
        params![owner, receiver, key, now_ms() - cooldown_s * 1000],
        |r| r.get(0),
    )?)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProposedBy {
    User,
    Pot,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub kind: ItemKind,
    pub r#ref: String,
    pub label: String,
    pub fit: Fit,
    pub reason: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Handover {
    pub id: String,
    pub from_pot_id: Option<String>,
    pub to: To,
    pub proposed_by: String,
    pub reason: String,
    pub state: String,
    pub revision: i64,
    pub items: Vec<Item>,
    pub created_at: i64,
    pub applied_at: Option<i64>,
}

const SELECT: &str = "SELECT id,from_pot_id,to_kind,to_pot_id,proposed_by,reason,state,revision,created_at,applied_at FROM pot_handovers";

fn handover_row(r: &Row) -> rusqlite::Result<Handover> {
    let to_kind: String = r.get(2)?;
    let to_pot: Option<String> = r.get(3)?;
    Ok(Handover {
        id: r.get(0)?,
        from_pot_id: r.get(1)?,
        to: match (to_kind.as_str(), to_pot) {
            ("pot", Some(pot_id)) => To::Pot { pot_id },
            _ => To::User,
        },
        proposed_by: r.get(4)?,
        reason: r.get(5)?,
        state: r.get(6)?,
        revision: r.get(7)?,
        items: Vec::new(),
        created_at: r.get(8)?,
        applied_at: r.get(9)?,
    })
}

fn with_items(conn: &Connection, mut handover: Handover) -> ApiResult<Handover> {
    handover.items = conn
        .prepare("SELECT kind,ref,label,fit,reason FROM pot_handover_items WHERE handover_id=?1 ORDER BY rowid")?
        .query_map([&handover.id], |r| {
            let kind: String = r.get(0)?;
            let fit: String = r.get(3)?;
            Ok(Item {
                kind: ItemKind::parse(&kind).unwrap_or(ItemKind::Responsibility),
                r#ref: r.get(1)?,
                label: r.get(2)?,
                fit: Fit::parse(&fit),
                reason: r.get(4)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(handover)
}

pub fn get(conn: &Connection, owner: &str, id: &str) -> ApiResult<Handover> {
    let handover = conn
        .query_row(
            &format!("{SELECT} WHERE id=?1 AND owner_user=?2"),
            params![id, owner],
            handover_row,
        )
        .optional()?
        .ok_or_else(|| ApiError::not_found("Handover not found"))?;
    with_items(conn, handover)
}

pub fn list(conn: &Connection, owner: &str, state: Option<&str>) -> ApiResult<Vec<Handover>> {
    if state.is_some_and(|s| !matches!(s, "proposed" | "applied" | "rejected")) {
        return Err(invalid("state is proposed, applied or rejected"));
    }
    let rows: Vec<Handover> = conn
        .prepare(&format!(
            "{SELECT} WHERE owner_user=?1 AND (?2 IS NULL OR state=?2) ORDER BY created_at DESC, rowid DESC LIMIT 200"
        ))?
        .query_map(params![owner, state], handover_row)?
        .collect::<Result<_, _>>()?;
    rows.into_iter().map(|h| with_items(conn, h)).collect()
}

/// Which items to move: all, or the listed ones.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ItemRef {
    pub kind: ItemKind,
    pub r#ref: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NewHandover {
    pub from_pot_id: String,
    pub to: To,
    /// Absent: everything the pot holds.
    #[serde(default)]
    pub items: Option<Vec<ItemRef>>,
    #[serde(default)]
    pub reason: String,
}

fn receiver(conn: &Connection, owner: &str, from: &str, to: &To) -> ApiResult<Option<Pot>> {
    match to {
        To::User => Ok(None),
        To::Pot { pot_id } => {
            if pot_id == from {
                return Err(invalid("A pot cannot hand over to itself"));
            }
            let pot = store::read(conn, owner, pot_id)?;
            if pot.state == PotState::Archived {
                return Err(ApiError::new(409, "pot_archived", "That pot is archived"));
            }
            Ok(Some(pot))
        }
    }
}

/// Propose a handover; the user confirms it (a user's own proposal too).
pub fn propose(
    conn: &Connection,
    owner: &str,
    input: NewHandover,
    by: ProposedBy,
) -> ApiResult<Handover> {
    let reason = input.reason.trim();
    if reason.chars().count() > MAX_REASON {
        return Err(invalid("A reason is at most 2000 characters"));
    }
    let from = store::read(conn, owner, &input.from_pot_id)?;
    let receiver = receiver(conn, owner, &from.id, &input.to)?;
    let all = held(conn, owner, &from.id)?;
    let chosen: Vec<Held> = match &input.items {
        None => all,
        Some(refs) => {
            let mut chosen = Vec::new();
            for wanted in refs {
                let item = all
                    .iter()
                    .find(|h| h.kind == wanted.kind && h.r#ref == wanted.r#ref)
                    .ok_or_else(|| invalid("Hand over only what the pot holds"))?;
                if !chosen.contains(item) {
                    chosen.push(item.clone());
                }
            }
            chosen
        }
    };
    if chosen.is_empty() {
        return Err(invalid("There is nothing to hand over"));
    }
    let id = new_id("handover");
    let (to_kind, to_pot) = match &input.to {
        To::Pot { pot_id } => ("pot", Some(pot_id.as_str())),
        To::User => ("user", None),
    };
    let by_text = match by {
        ProposedBy::User => "user",
        ProposedBy::Pot => "pot",
    };
    conn.execute(
        "INSERT INTO pot_handovers(id,owner_user,from_pot_id,to_kind,to_pot_id,proposed_by,reason,created_at)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
        params![id, owner, from.id, to_kind, to_pot, by_text, reason, now_ms()],
    )?;
    for item in &chosen {
        let (mut fit, mut why) = fit(conn, &from, item, &input.to, receiver.as_ref())?;
        if by == ProposedBy::Pot
            && let Some(receiver) = &receiver
            && handed_back(conn, owner, &receiver.id, &item_key(item))?
        {
            fit = Fit::Stop;
            why = Some(format!(
                "{} had this recently; only the user can hand it back",
                receiver.input.profile.name
            ));
        }
        conn.execute(
            "INSERT INTO pot_handover_items(handover_id,kind,ref,label,item_key,fit,reason) VALUES(?1,?2,?3,?4,?5,?6,?7)",
            params![id, item.kind.as_str(), item.r#ref, item.label, item_key(item), fit.as_str(), why],
        )?;
    }
    let to_name = receiver
        .as_ref()
        .map_or_else(|| "the user".to_owned(), |p| p.input.profile.name.clone());
    activity::log(
        conn,
        owner,
        &from.id,
        Entry::new(
            Kind::HandoverProposed,
            format!("Handover of {} items to {to_name} proposed", chosen.len()),
        )
        .toward(match &input.to {
            To::Pot { pot_id } => Counterpart::Pot(pot_id.clone()),
            To::User => Counterpart::User,
        })
        .refs(Refs {
            handover: Some(id.clone()),
            ..Refs::default()
        }),
    )?;
    get(conn, owner, &id)
}

/// Move one item that fits; `false` when it is gone or stops after all.
fn move_item(conn: &Connection, owner: &str, from: &Pot, item: &Item, to: &To) -> ApiResult<bool> {
    let changed = match (item.kind, to) {
        (ItemKind::Responsibility, To::Pot { pot_id }) => {
            let count: i64 =
                conn.query_row("SELECT count(*) FROM pot_responsibilities WHERE pot_id=?1", [pot_id], |r| r.get(0))?;
            if count >= MAX_RESPONSIBILITIES {
                return Ok(false);
            }
            conn.execute(
                "UPDATE pot_responsibilities SET pot_id=?2,
                  position=(SELECT COALESCE(max(position),-1)+1 FROM pot_responsibilities WHERE pot_id=?2)
                 WHERE id=?1 AND pot_id=?3",
                params![item.r#ref, pot_id, from.id],
            )?
        }
        (ItemKind::Reminder, To::Pot { pot_id }) => conn.execute(
            "UPDATE pot_reminders SET pot_id=?2 WHERE id=?1 AND pot_id=?3 AND state='pending'",
            params![item.r#ref, pot_id, from.id],
        )?,
        (ItemKind::Work, To::Pot { pot_id }) => conn.execute(
            "UPDATE pot_works SET pot_id=?2, updated_at=?4 WHERE id=?1 AND pot_id=?3 AND state='open'",
            params![item.r#ref, pot_id, from.id, now_ms()],
        )?,
        (ItemKind::Work, To::User) => {
            let open: bool = conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM pot_works WHERE id=?1 AND pot_id=?2 AND state='open')",
                params![item.r#ref, from.id],
                |r| r.get(0),
            )?;
            if open {
                super::work::take_over(conn, owner, &item.r#ref)?;
            }
            usize::from(open)
        }
        (ItemKind::GroupHost, To::Pot { pot_id }) => conn.execute(
            "UPDATE threads SET host_pot_id=?2 WHERE id=?1 AND host_pot_id=?3 AND kind='group'",
            params![item.r#ref, pot_id, from.id],
        )?,
        _ => 0,
    };
    Ok(changed == 1)
}

/// The user confirms: fits are checked again, what fits moves, the receiver
/// is woken. Returns the handover and the pot to kick, if any.
pub fn confirm(
    conn: &mut Connection,
    owner: &str,
    id: &str,
    revision: i64,
) -> ApiResult<(Handover, Option<String>)> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let applied = apply(&tx, owner, id, revision)?;
    tx.commit()?;
    Ok(applied)
}

/// [`confirm`] inside the caller's transaction (retire applies several).
pub fn apply(
    conn: &Connection,
    owner: &str,
    id: &str,
    revision: i64,
) -> ApiResult<(Handover, Option<String>)> {
    let handover = get(conn, owner, id)?;
    if handover.revision != revision {
        return Err(ApiError::new(
            409,
            "revision_conflict",
            "The handover changed; read it again",
        ));
    }
    if handover.state != "proposed" {
        return Err(ApiError::new(
            409,
            "already_decided",
            "This handover was already decided",
        ));
    }
    let from_id = handover
        .from_pot_id
        .clone()
        .ok_or_else(|| ApiError::not_found("Pot not found"))?;
    let from = store::read(conn, owner, &from_id)?;
    let receiver = receiver(conn, owner, &from.id, &handover.to)?;
    let mut moved = Vec::new();
    for item in &handover.items {
        let current = Held {
            kind: item.kind,
            r#ref: item.r#ref.clone(),
            label: item.label.clone(),
        };
        // A rule-1 stop stays a stop; otherwise the fit is checked again now.
        let (fit, why) = if item.fit == Fit::Stop {
            (Fit::Stop, item.reason.clone())
        } else {
            fit(conn, &from, &current, &handover.to, receiver.as_ref())?
        };
        let done = fit != Fit::Stop && move_item(conn, owner, &from, item, &handover.to)?;
        let (fit, why) = if fit != Fit::Stop && !done {
            (Fit::Stop, Some("It changed or is gone".to_owned()))
        } else {
            (fit, why)
        };
        conn.execute(
            "UPDATE pot_handover_items SET fit=?3, reason=?4 WHERE handover_id=?1 AND kind=?2 AND ref=?5",
            params![id, item.kind.as_str(), fit.as_str(), why, item.r#ref],
        )?;
        if done {
            moved.push(item.clone());
        }
    }
    conn.execute(
        "UPDATE pot_handovers SET state='applied', applied_at=?2, revision=revision+1 WHERE id=?1",
        params![id, now_ms()],
    )?;
    if moved
        .iter()
        .any(|item| item.kind == ItemKind::Responsibility)
    {
        conn.execute(
            "UPDATE pots SET revision=revision+1, updated_at=?2 WHERE id=?1",
            params![from.id, now_ms()],
        )?;
        if let To::Pot { pot_id } = &handover.to {
            conn.execute(
                "UPDATE pots SET revision=revision+1, updated_at=?2 WHERE id=?1",
                params![pot_id, now_ms()],
            )?;
        }
    }
    let to_name = receiver
        .as_ref()
        .map_or_else(|| "the user".to_owned(), |p| p.input.profile.name.clone());
    activity::log(
        conn,
        owner,
        &from.id,
        Entry::new(
            Kind::Assign,
            format!("Handed {} items over to {to_name}", moved.len()),
        )
        .toward(match &handover.to {
            To::Pot { pot_id } => Counterpart::Pot(pot_id.clone()),
            To::User => Counterpart::User,
        })
        .refs(Refs {
            handover: Some(id.to_owned()),
            ..Refs::default()
        }),
    )?;
    let mut kick = None;
    if let (To::Pot { pot_id }, false) = (&handover.to, moved.is_empty()) {
        let list: Vec<String> = moved
            .iter()
            .map(|item| format!("- {} ({})", item.label, item.kind.as_str()))
            .collect();
        let thread = super::threads::direct(conn, owner, pot_id)?;
        runtime::enqueue(
            conn,
            owner,
            pot_id,
            NewWake {
                source: Source::Handover,
                thread_id: Some(&thread.id),
                causal_root: None,
                depth: 0,
                from_pot: None,
                caused_by: None,
                purpose: super::guard::purpose(
                    &format!("pot:{pot_id}"),
                    "handover",
                    &format!("handover:{id}"),
                ),
                content: &format!(
                    "The user handed you these from {}:\n{}\n\nYou act on them with your own permissions.",
                    from.input.profile.name,
                    list.join("\n")
                ),
                details: json!({ "handoverId": id, "fromPotId": from.id }),
            },
        )?;
        kick = Some(pot_id.clone());
    }
    Ok((get(conn, owner, id)?, kick))
}

pub fn reject(conn: &Connection, owner: &str, id: &str) -> ApiResult<Handover> {
    let changed = conn.execute(
        "UPDATE pot_handovers SET state='rejected', revision=revision+1 WHERE id=?1 AND owner_user=?2 AND state='proposed'",
        params![id, owner],
    )?;
    if changed == 0 {
        get(conn, owner, id)?;
        return Err(ApiError::new(
            409,
            "already_decided",
            "This handover was already decided",
        ));
    }
    get(conn, owner, id)
}
