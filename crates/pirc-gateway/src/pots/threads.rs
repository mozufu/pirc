//! Threads with and between pots (plans/pots.md, Threads and messaging).
//!
//! - A direct thread per pot holds the user's conversation with it.
//! - A group has members, a host, and optionally a project. A user message
//!   without a mention wakes only the host; `@pot` wakes that member; `@all`
//!   (the user's only) wakes every member.
//! - A pot DM thread holds two pots' messages; sending needs the sender's send
//!   rule and the receiver's receive rule.
//!
//! Every thread is readable by the user. Authors come from the Gateway: a
//! user message from the signed-in owner, a pot message from the pot whose
//! session sent it or whose wake it answers.

use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::activity::{self, Counterpart, Entry, Kind, Refs};
use super::runtime::{self, NewWake, Source};
use super::store::{self, DmRule, PotState};
use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms};

pub const MAX_THREADS: i64 = 200;
pub const MAX_MEMBERS: usize = 16;
pub const MAX_BODY: usize = 32 * 1024;
const PAGE: i64 = 50;

fn invalid(message: &str) -> ApiError {
    ApiError::new(400, "invalid_input", message)
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Thread {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub avatar_color: Option<u8>,
    pub host_pot_id: Option<String>,
    pub project_id: Option<String>,
    /// Member pots: the direct thread's pot, a DM's two pots, a group's members.
    pub pots: Vec<String>,
    pub last_seq: i64,
    /// Messages after the user's read position.
    pub unread: i64,
    /// The newest message in short: who wrote it and its first line.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_message: Option<LastMessage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avatar_image: Option<String>,
    pub revision: i64,
    pub updated_at: i64,
}

/// The newest message of a thread, for its row.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LastMessage {
    /// `user`, `pot` or `system`.
    pub author_kind: String,
    /// The pot that wrote it, when one did.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author_id: Option<String>,
    pub author_name: String,
    pub body: String,
    pub created_at: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    pub thread_id: String,
    pub seq: i64,
    pub author_kind: String,
    pub author_id: Option<String>,
    /// A deleted author pot's name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author_name: Option<String>,
    pub body: String,
    pub mentions: Vec<String>,
    pub all: bool,
    pub created_at: i64,
    /// A Gateway card on a system message; the client reads the item by id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub card: Option<Card>,
}

/// What a card points at. The item's own route has its current state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum Card {
    /// `GET /api/model-approvals/{approvalId}`.
    ModelApproval { approval_id: String },
    /// `GET /api/budget-requests/{requestId}`.
    BudgetRequest { request_id: String },
    /// `GET /api/pot-works/{workId}`; the work session is `sessionId`.
    Work { work_id: String, session_id: String },
    /// `GET /api/handovers/{handoverId}`: a pot proposes a handover.
    Handover { handover_id: String },
    /// `GET /api/causal-roots/{rootId}`: the loop guard suspended the root.
    LoopGuard { root_id: String },
}

fn thread_row(row: &Row) -> rusqlite::Result<Thread> {
    Ok(Thread {
        id: row.get(0)?,
        kind: row.get(1)?,
        name: row.get(2)?,
        avatar_color: row.get(3)?,
        host_pot_id: row.get(4)?,
        project_id: row.get(5)?,
        pots: [row.get::<_, Option<String>>(6)?, row.get(7)?]
            .into_iter()
            .flatten()
            .collect(),
        last_seq: row.get(8)?,
        unread: 0,
        last_message: None,
        avatar_image: row.get(10)?,
        revision: row.get(11)?,
        updated_at: row.get(9)?,
    })
}

const THREAD: &str = "SELECT id,kind,name,avatar_color,host_pot_id,project_id,pot_a,pot_b,last_seq,updated_at,avatar_image,revision FROM threads";

/// Unread count and the newest message of a thread.
fn summary(conn: &Connection, thread: &mut Thread) -> rusqlite::Result<()> {
    thread.unread = conn.query_row(
        "SELECT count(*) FROM messages m JOIN threads t ON t.id=m.thread_id
         WHERE m.thread_id=?1 AND m.seq>t.last_read_seq",
        [&thread.id],
        |r| r.get(0),
    )?;
    thread.last_message = conn
        .query_row(
            "SELECT m.author_kind, m.author_id, COALESCE(m.author_name,
               (SELECT p.name FROM pots p WHERE p.id=m.author_id), ''),
               m.body, m.created_at
             FROM messages m WHERE m.thread_id=?1 ORDER BY m.seq DESC LIMIT 1",
            [&thread.id],
            |r| {
                Ok(LastMessage {
                    author_kind: r.get(0)?,
                    author_id: r.get(1)?,
                    author_name: r.get(2)?,
                    body: r.get(3)?,
                    created_at: r.get(4)?,
                })
            },
        )
        .optional()?;
    Ok(())
}

fn members(conn: &Connection, thread: &mut Thread) -> rusqlite::Result<()> {
    if thread.kind == "group" {
        thread.pots = conn
            .prepare("SELECT pot_id FROM thread_members WHERE thread_id=?1 ORDER BY pot_id")?
            .query_map([&thread.id], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
    }
    Ok(())
}

pub fn get(conn: &Connection, owner: &str, id: &str) -> ApiResult<Thread> {
    let mut thread = conn
        .query_row(
            &format!("{THREAD} WHERE id=?1 AND owner_user=?2"),
            params![id, owner],
            thread_row,
        )
        .optional()?
        .ok_or_else(|| ApiError::not_found("Thread not found"))?;
    members(conn, &mut thread)?;
    summary(conn, &mut thread)?;
    Ok(thread)
}

pub fn list(conn: &Connection, owner: &str) -> ApiResult<Vec<Thread>> {
    let mut threads: Vec<Thread> = conn
        .prepare(&format!(
            "{THREAD} WHERE owner_user=?1 ORDER BY updated_at DESC, id"
        ))?
        .query_map([owner], thread_row)?
        .collect::<Result<_, _>>()?;
    for thread in &mut threads {
        members(conn, thread)?;
        summary(conn, thread)?;
    }
    Ok(threads)
}

fn count(conn: &Connection, owner: &str) -> ApiResult<()> {
    let n: i64 = conn.query_row(
        "SELECT count(*) FROM threads WHERE owner_user=?1",
        [owner],
        |r| r.get(0),
    )?;
    if n >= MAX_THREADS {
        return Err(ApiError::new(
            409,
            "limit_reached",
            "You have the most threads allowed",
        ));
    }
    Ok(())
}

fn insert(
    conn: &Connection,
    owner: &str,
    kind: &str,
    pot_a: Option<&str>,
    pot_b: Option<&str>,
) -> ApiResult<String> {
    // A pot's direct thread is not counted: there is one per pot (at most 32),
    // and notices to the pot must always find it.
    if kind != "direct" {
        count(conn, owner)?;
    }
    let id = new_id("thread");
    let stamp = now_ms();
    conn.execute(
        "INSERT INTO threads(id,owner_user,kind,pot_a,pot_b,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?6)",
        params![id, owner, kind, pot_a, pot_b, stamp],
    )?;
    Ok(id)
}

/// The user's direct thread with `pot_id`, made on first use.
pub fn direct(conn: &Connection, owner: &str, pot_id: &str) -> ApiResult<Thread> {
    store::read(conn, owner, pot_id)?;
    let found: Option<String> = conn
        .query_row(
            "SELECT id FROM threads WHERE owner_user=?1 AND kind='direct' AND pot_a=?2",
            params![owner, pot_id],
            |r| r.get(0),
        )
        .optional()?;
    let id = match found {
        Some(id) => id,
        None => insert(conn, owner, "direct", Some(pot_id), None)?,
    };
    get(conn, owner, &id)
}

/// A Gateway notice in the pot's direct thread (`author_kind='system'`), such
/// as the reason a model approval was denied. It wakes no one.
pub fn post_system(conn: &Connection, owner: &str, pot_id: &str, body: &str) -> ApiResult<Message> {
    let thread = direct(conn, owner, pot_id)?;
    append(conn, &thread, &Author::System, body, &[], false, None, None)
}

/// A card from the Gateway about something the pot did, in the thread of the
/// wake it is handling (so a group that asked sees it there), or else in the
/// pot's direct thread. It wakes no one.
pub fn post_card(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    body: &str,
    card: Card,
) -> ApiResult<Message> {
    let current: Option<String> = conn
        .query_row(
            "SELECT w.thread_id FROM pot_wakes w JOIN threads t ON t.id=w.thread_id
             WHERE w.pot_id=?1 AND w.owner_user=?2 AND w.state IN ('delivering','delivered')",
            params![pot_id, owner],
            |r| r.get(0),
        )
        .optional()?;
    post_card_in(conn, owner, pot_id, current.as_deref(), body, card)
}

/// [`post_card`] in a named thread (a causal root's thread), else the pot's
/// direct thread.
pub fn post_card_in(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    thread_id: Option<&str>,
    body: &str,
    card: Card,
) -> ApiResult<Message> {
    let thread = match thread_id {
        Some(id) => match get(conn, owner, id) {
            Ok(thread) => thread,
            Err(error) if error.status == 404 => direct(conn, owner, pot_id)?,
            Err(error) => return Err(error),
        },
        None => direct(conn, owner, pot_id)?,
    };
    append(
        conn,
        &thread,
        &Author::System,
        body,
        &[],
        false,
        None,
        Some(&card),
    )
}

/// The DM thread between two pots, made on first use.
pub(super) fn pot_dm(conn: &Connection, owner: &str, a: &str, b: &str) -> ApiResult<Thread> {
    let (a, b) = if a < b { (a, b) } else { (b, a) };
    let found: Option<String> = conn
        .query_row(
            "SELECT id FROM threads WHERE owner_user=?1 AND kind='pot_dm' AND pot_a=?2 AND pot_b=?3",
            params![owner, a, b],
            |r| r.get(0),
        )
        .optional()?;
    let id = match found {
        Some(id) => id,
        None => insert(conn, owner, "pot_dm", Some(a), Some(b))?,
    };
    get(conn, owner, &id)
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GroupInput {
    pub name: String,
    #[serde(default)]
    pub avatar_color: Option<u8>,
    #[serde(default)]
    pub avatar_image: Option<String>,
    pub host_pot_id: String,
    pub member_pot_ids: Vec<String>,
    #[serde(default)]
    pub project_id: Option<String>,
}

pub fn create_group(conn: &Connection, owner: &str, input: GroupInput) -> ApiResult<Thread> {
    let name = input.name.trim();
    if name.is_empty() || name.chars().count() > 60 {
        return Err(invalid("A group name is 1 to 60 characters"));
    }
    if input.avatar_color.is_some_and(|c| !(1..=5).contains(&c)) {
        return Err(invalid("avatarColor must be 1 to 5"));
    }
    let mut members = input.member_pot_ids.clone();
    if !members.contains(&input.host_pot_id) {
        members.push(input.host_pot_id.clone());
    }
    members.sort();
    members.dedup();
    if members.len() < 2 || members.len() > MAX_MEMBERS {
        return Err(invalid("A group has 2 to 16 pots"));
    }
    for pot in &members {
        store::read(conn, owner, pot)?;
    }
    count(conn, owner)?;
    let id = new_id("thread");
    let stamp = now_ms();
    if let Some(image) = &input.avatar_image {
        super::images_owned(conn, owner, image)?;
    }
    conn.execute(
        "INSERT INTO threads(id,owner_user,kind,name,avatar_color,avatar_image,host_pot_id,project_id,created_at,updated_at)
         VALUES(?1,?2,'group',?3,?4,?8,?5,?6,?7,?7)",
        params![id, owner, name, input.avatar_color, input.host_pot_id, input.project_id, stamp, input.avatar_image],
    )?;
    for pot in &members {
        conn.execute(
            "INSERT INTO thread_members(thread_id,pot_id) VALUES(?1,?2)",
            params![id, pot],
        )?;
    }
    get(conn, owner, &id)
}

fn message_row(row: &Row) -> rusqlite::Result<Message> {
    let mentions: String = row.get(6)?;
    Ok(Message {
        id: row.get(0)?,
        thread_id: row.get(1)?,
        seq: row.get(2)?,
        author_kind: row.get(3)?,
        author_id: row.get(4)?,
        body: row.get(5)?,
        mentions: serde_json::from_str(&mentions).unwrap_or_default(),
        all: row.get(7)?,
        created_at: row.get(8)?,
        card: row
            .get::<_, Option<String>>(9)?
            .and_then(|card| serde_json::from_str(&card).ok()),
        author_name: row.get(10)?,
    })
}

/// The user has read up to `seq` (never past what the thread has).
pub fn mark_read(conn: &Connection, owner: &str, id: &str, seq: i64) -> ApiResult<Thread> {
    let thread = get(conn, owner, id)?;
    let seq = seq.max(0).min(thread.last_seq);
    conn.execute(
        "UPDATE threads SET last_read_seq=max(last_read_seq,?2) WHERE id=?1",
        params![id, seq],
    )?;
    get(conn, owner, id)
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GroupPatch {
    pub revision: i64,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default, deserialize_with = "crate::me::present_u8")]
    pub avatar_color: Option<Option<u8>>,
    #[serde(default, deserialize_with = "crate::me::present")]
    pub avatar_image: Option<Option<String>>,
    #[serde(default)]
    pub host_pot_id: Option<String>,
    #[serde(default)]
    pub member_pot_ids: Option<Vec<String>>,
}

/// A group's name, colour, picture, host and members; the user only.
pub fn update_group(
    conn: &Connection,
    owner: &str,
    id: &str,
    patch: GroupPatch,
) -> ApiResult<Thread> {
    let thread = get(conn, owner, id)?;
    if thread.kind != "group" {
        return Err(ApiError::new(
            400,
            "invalid_input",
            "Only a group can be changed",
        ));
    }
    if patch.revision != thread.revision {
        return Err(ApiError::new(
            409,
            "revision_conflict",
            "The group changed; read it again",
        ));
    }
    let name = match patch.name.as_deref().map(str::trim) {
        None => thread.name.clone(),
        Some(name) if name.is_empty() || name.chars().count() > 60 => {
            return Err(invalid("A group name is 1 to 60 characters"));
        }
        Some(name) => name.to_owned(),
    };
    let color = match patch.avatar_color {
        None => thread.avatar_color,
        Some(color) => {
            if color.is_some_and(|c| !(1..=5).contains(&c)) {
                return Err(invalid("avatarColor must be 1 to 5"));
            }
            color
        }
    };
    let image = match patch.avatar_image {
        None => thread.avatar_image.clone(),
        Some(None) => None,
        Some(Some(id)) => {
            super::images_owned(conn, owner, &id)?;
            Some(id)
        }
    };
    let host = patch
        .host_pot_id
        .unwrap_or_else(|| thread.host_pot_id.clone().unwrap_or_default());
    let mut members = patch.member_pot_ids.unwrap_or_else(|| thread.pots.clone());
    if host.is_empty() {
        return Err(invalid("A group has a host"));
    }
    if !members.contains(&host) {
        members.push(host.clone());
    }
    members.sort();
    members.dedup();
    if members.len() < 2 || members.len() > MAX_MEMBERS {
        return Err(invalid("A group has 2 to 16 pots"));
    }
    for pot in &members {
        store::read(conn, owner, pot)?;
    }
    let tx = conn.unchecked_transaction()?;
    tx.execute(
        "UPDATE threads SET name=?2,avatar_color=?3,avatar_image=?4,host_pot_id=?5,revision=revision+1,updated_at=?6
         WHERE id=?1",
        params![id, name, color, image, host, now_ms()],
    )?;
    tx.execute("DELETE FROM thread_members WHERE thread_id=?1", [id])?;
    for pot in &members {
        tx.execute(
            "INSERT INTO thread_members(thread_id,pot_id) VALUES(?1,?2)",
            params![id, pot],
        )?;
    }
    if thread.avatar_image != image {
        super::images_release(&tx, thread.avatar_image.as_deref())?;
    }
    tx.commit()?;
    get(conn, owner, id)
}

pub fn delete_group(conn: &Connection, owner: &str, id: &str) -> ApiResult<()> {
    let thread = get(conn, owner, id)?;
    if thread.kind != "group" {
        return Err(ApiError::new(
            400,
            "invalid_input",
            "Only a group can be deleted",
        ));
    }
    conn.execute(
        "DELETE FROM threads WHERE id=?1 AND owner_user=?2",
        params![id, owner],
    )?;
    super::images_release(conn, thread.avatar_image.as_deref())?;
    Ok(())
}

/// A page of messages, newest last; `before` is a sequence number.
pub fn messages(
    conn: &Connection,
    owner: &str,
    thread_id: &str,
    before: Option<i64>,
) -> ApiResult<Vec<Message>> {
    get(conn, owner, thread_id)?;
    let mut page: Vec<Message> = conn
        .prepare(
            "SELECT id,thread_id,seq,author_kind,author_id,body,mentions_json,all_mention,created_at,card_json,author_name
             FROM messages WHERE thread_id=?1 AND seq<?2 ORDER BY seq DESC LIMIT ?3",
        )?
        .query_map(params![thread_id, before.unwrap_or(i64::MAX), PAGE], message_row)?
        .collect::<Result<_, _>>()?;
    page.reverse();
    Ok(page)
}

/// Who wrote a message.
pub enum Author<'a> {
    User,
    Pot(&'a str),
    /// A Gateway notice in a thread, such as an approval's denial reason.
    System,
}

#[allow(clippy::too_many_arguments)]
fn append(
    conn: &Connection,
    thread: &Thread,
    author: &Author,
    body: &str,
    mentions: &[String],
    all: bool,
    causal_root: Option<&str>,
    card: Option<&Card>,
) -> ApiResult<Message> {
    let body = body.trim();
    if body.is_empty() || body.len() > MAX_BODY {
        return Err(invalid("A message is 1 byte to 32 KiB"));
    }
    let (kind, id) = match author {
        Author::User => ("user", None),
        Author::Pot(pot) => ("pot", Some(*pot)),
        Author::System => ("system", None),
    };
    let seq = conn.query_row(
        "UPDATE threads SET last_seq=last_seq+1,updated_at=?2 WHERE id=?1 RETURNING last_seq",
        params![thread.id, now_ms()],
        |r| r.get::<_, i64>(0),
    )?;
    let message_id = new_id("msg");
    conn.execute(
        "INSERT INTO messages(id,thread_id,seq,author_kind,author_id,body,mentions_json,all_mention,causal_root,created_at,card_json)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
        params![
            message_id,
            thread.id,
            seq,
            kind,
            id,
            body,
            serde_json::to_string(mentions).expect("strings serialize"),
            all,
            causal_root,
            now_ms(),
            card.map(|card| serde_json::to_string(card).expect("cards serialize")),
        ],
    )?;
    if matches!(author, Author::User) {
        // The user's own message is read by them where it was written.
        conn.execute(
            "UPDATE threads SET last_read_seq=max(last_read_seq,?2) WHERE id=?1",
            params![thread.id, seq],
        )?;
    }
    message(conn, &message_id)
}

/// One message by id (callers have checked the owner).
pub fn message(conn: &Connection, id: &str) -> ApiResult<Message> {
    Ok(conn.query_row(
        "SELECT id,thread_id,seq,author_kind,author_id,body,mentions_json,all_mention,created_at,card_json,author_name FROM messages WHERE id=?1",
        [id],
        message_row,
    )?)
}

pub(crate) fn pot_name(conn: &Connection, pot: &str) -> String {
    conn.query_row("SELECT name FROM pots WHERE id=?1", [pot], |r| r.get(0))
        .unwrap_or_else(|_| pot.to_owned())
}

/// What a woken pot reads: where the message is, who wrote it, and the text.
fn wake_text(
    conn: &Connection,
    owner: &str,
    thread: &Thread,
    author: &Author,
    body: &str,
) -> String {
    let who = match author {
        Author::User => format!("the user ({owner})"),
        Author::Pot(pot) => format!("pot {}", pot_name(conn, pot)),
        Author::System => "the Gateway".to_owned(),
    };
    let place = match thread.kind.as_str() {
        "direct" => "your direct conversation with the user".to_owned(),
        "group" => format!("the group \"{}\"", thread.name),
        _ => "a direct message between pots".to_owned(),
    };
    format!("Message from {who} in {place}. Your final answer is posted there.\n\n{body}")
}

/// Which pots a message wakes.
fn addressees(thread: &Thread, author: &Author, mentions: &[String], all: bool) -> Vec<String> {
    let sender = match author {
        Author::Pot(pot) => Some(*pot),
        Author::User | Author::System => None,
    };
    let mut woken: Vec<String> = match thread.kind.as_str() {
        "direct" | "pot_dm" => thread.pots.clone(),
        _ if all => thread.pots.clone(),
        _ if !mentions.is_empty() => mentions
            .iter()
            .filter(|m| thread.pots.contains(m))
            .cloned()
            .collect(),
        _ => thread.host_pot_id.iter().cloned().collect(),
    };
    woken.retain(|pot| Some(pot.as_str()) != sender);
    woken.sort();
    woken.dedup();
    woken
}

/// A pot that was not woken, and why, for the sender's notice.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Refused {
    pub pot_id: String,
    pub code: String,
    pub reason: String,
}

/// A posted message: what was stored, who was woken, who was not and why.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Posted {
    pub message: Message,
    pub woken: Vec<String>,
    pub refused: Vec<Refused>,
}

/// The user posts in a thread. A user message starts a causal root that every
/// wake it causes, and everything those wakes cause, inherits.
pub fn post_user(
    conn: &Connection,
    owner: &str,
    thread_id: &str,
    body: &str,
    mentions: Vec<String>,
    all: bool,
) -> ApiResult<Posted> {
    let thread = get(conn, owner, thread_id)?;
    if thread.kind == "pot_dm" {
        return Err(ApiError::new(
            403,
            "read_only",
            "Pots' messages to each other are read-only",
        ));
    }
    if all && thread.kind != "group" {
        return Err(invalid("@all is for groups"));
    }
    if mentions.iter().any(|m| !thread.pots.contains(m)) {
        return Err(invalid("Mentions must be members of the thread"));
    }
    let message = append(
        conn,
        &thread,
        &Author::User,
        body,
        &mentions,
        all,
        None,
        None,
    )?;
    let woken = addressees(&thread, &Author::User, &mentions, all);
    // The host leads a group; otherwise the first addressee is the root's
    // initiating pot and its remaining budget caps the root.
    let initiator = thread
        .host_pot_id
        .clone()
        .filter(|host| woken.contains(host))
        .or_else(|| woken.first().cloned());
    let root = match initiator {
        Some(pot) => Some(
            super::roots::start(
                conn,
                owner,
                &pot,
                super::roots::Origin::UserMessage,
                &message.id,
                Some(&thread.id),
            )?
            .id,
        ),
        None => None,
    };
    let text = wake_text(conn, owner, &thread, &Author::User, &message.body);
    let source = if thread.kind == "group" {
        Source::Group
    } else {
        Source::User
    };
    let purpose = super::guard::purpose(
        &format!("thread:{}", thread.id),
        "user_message",
        &format!("message:{}", message.id),
    );
    for pot in &woken {
        runtime::enqueue(
            conn,
            owner,
            pot,
            NewWake {
                source,
                thread_id: Some(&thread.id),
                causal_root: root.as_deref(),
                depth: 0,
                from_pot: None,
                caused_by: None,
                purpose: purpose.clone(),
                content: &text,
                details: json!({ "threadId": thread.id, "messageId": message.id }),
            },
        )?;
    }
    Ok(Posted {
        message,
        woken,
        refused: Vec::new(),
    })
}

/// Whether `from` may message `to` under both pots' rules.
pub fn dm_allowed(conn: &Connection, owner: &str, from: &str, to: &str) -> ApiResult<bool> {
    let sender = store::read(conn, owner, from)?;
    let receiver = store::read(conn, owner, to)?;
    if receiver.state == PotState::Archived {
        return Ok(false);
    }
    let send = match sender.input.permissions.dm.send {
        DmRule::All => true,
        DmRule::Selected => sender.input.permissions.dm.send_to.iter().any(|p| p == to),
        DmRule::Off => false,
    };
    let receive = match receiver.input.permissions.dm.receive {
        DmRule::All => true,
        DmRule::Selected => receiver
            .input
            .permissions
            .dm
            .receive_from
            .iter()
            .any(|p| p == from),
        DmRule::Off => false,
    };
    Ok(send && receive)
}

/// Where a pot sends: an existing thread it belongs to, or another pot.
pub enum Target<'a> {
    Thread(&'a str),
    Pot(&'a str),
}

/// A pot sends a message. In a group, mentions wake only members the DM rules
/// allow; a pot can never address everyone. The message inherits the root and
/// depth+1 of the wake the pot is handling; every message it causes does too.
pub fn post_pot(
    conn: &Connection,
    owner: &str,
    from: &str,
    target: Target,
    body: &str,
    mentions: Vec<String>,
    causal_root: Option<&str>,
) -> ApiResult<Posted> {
    let handling = super::roots::handling(conn, owner, from)?;
    let root = causal_root
        .map(str::to_owned)
        .or_else(|| handling.root.clone());
    let depth = handling.depth + 1;
    let thread = match target {
        Target::Pot(to) => {
            if to == from {
                return Err(invalid("A pot cannot message itself"));
            }
            if !dm_allowed(conn, owner, from, to)? {
                activity::log(
                    conn,
                    owner,
                    from,
                    Entry::new(
                        Kind::Dm,
                        format!(
                            "Message to {} refused by the message rules",
                            pot_name(conn, to)
                        ),
                    )
                    .toward(Counterpart::Pot(to.to_owned()))
                    .root(root.as_deref()),
                )?;
                return Err(ApiError::new(
                    403,
                    "dm_refused",
                    "Your or their message rules do not allow this",
                ));
            }
            pot_dm(conn, owner, from, to)?
        }
        Target::Thread(id) => {
            let thread = get(conn, owner, id)?;
            if !thread.pots.iter().any(|p| p == from) {
                return Err(ApiError::new(
                    403,
                    "not_a_member",
                    "You are not in that thread",
                ));
            }
            thread
        }
    };
    if thread.kind != "group" && !mentions.is_empty() {
        return Err(invalid("Mentions are for groups"));
    }
    let author = Author::Pot(from);
    let message = append(
        conn,
        &thread,
        &author,
        body,
        &mentions,
        false,
        root.as_deref(),
        None,
    )?;
    // A message the user reads is progress; a pot DM is part of a possible
    // no-progress exchange and counts as a message.
    if let Some(root_id) = &root
        && matches!(thread.kind.as_str(), "direct" | "group")
        && let Err(error) = super::guard::progress(conn, root_id, from, "message")
    {
        crate::log::warn(&format!("loop guard progress: {}", error.message));
    }
    let preview: String = message
        .body
        .lines()
        .next()
        .unwrap_or_default()
        .chars()
        .take(160)
        .collect();
    let (kind, counterpart, summary) = match (&target, thread.kind.as_str()) {
        (Target::Pot(to), _) => (
            Kind::Dm,
            Counterpart::Pot((*to).to_owned()),
            format!("Message to {}: {preview}", pot_name(conn, to)),
        ),
        (_, "group") => (
            Kind::GroupMessage,
            Counterpart::System,
            format!("In {}: {preview}", thread.name),
        ),
        _ => (
            Kind::ForwardedToUser,
            Counterpart::User,
            format!("To the user: {preview}"),
        ),
    };
    activity::log(
        conn,
        owner,
        from,
        Entry::new(kind, summary)
            .toward(counterpart)
            .refs(Refs {
                thread: Some(thread.id.clone()),
                message: Some(message.id.clone()),
                ..Refs::default()
            })
            .root(root.as_deref()),
    )?;
    let mut woken = Vec::new();
    let mut refused = Vec::new();
    for pot in addressees(&thread, &author, &mentions, false) {
        // In a group, only a mention wakes another pot, and only if allowed.
        if thread.kind == "group" && (mentions.is_empty() || !dm_allowed(conn, owner, from, &pot)?)
        {
            continue;
        }
        if thread.kind == "direct" {
            // A pot writing in its own direct thread notifies the user, wakes no one.
            continue;
        }
        let action = if thread.kind == "group" {
            "group_message"
        } else {
            "dm"
        };
        let purpose = super::guard::purpose(
            &format!("pot:{pot}"),
            action,
            &format!("root:{}", root.as_deref().unwrap_or("")),
        );
        if let Some(root_id) = &root
            && thread.kind == "pot_dm"
            && let Err(error) = super::guard::note_message(conn, root_id, from, &pot, &purpose)
        {
            crate::log::warn(&format!("loop guard message: {}", error.message));
        }
        let text = wake_text(conn, owner, &thread, &author, &message.body);
        let source = if thread.kind == "group" {
            Source::Group
        } else {
            Source::Dm
        };
        let wake = runtime::enqueue(
            conn,
            owner,
            &pot,
            NewWake {
                source,
                thread_id: Some(&thread.id),
                causal_root: root.as_deref(),
                depth,
                from_pot: Some(from),
                caused_by: handling.wake_id.as_deref(),
                purpose,
                content: &text,
                details: json!({ "threadId": thread.id, "messageId": message.id, "fromPot": from }),
            },
        );
        match wake {
            Ok(_) => woken.push(pot),
            Err(error) if error.status == 409 => {
                let refused_pot = Refused {
                    pot_id: pot,
                    code: error.code.to_owned(),
                    reason: error.message.clone(),
                };
                activity::log(
                    conn,
                    owner,
                    from,
                    Entry::new(
                        Kind::LoopGuard,
                        format!(
                            "Did not wake {}: {}",
                            pot_name(conn, &refused_pot.pot_id),
                            refused_pot.reason
                        ),
                    )
                    .toward(Counterpart::Pot(refused_pot.pot_id.clone()))
                    .refs(Refs {
                        thread: Some(thread.id.clone()),
                        message: Some(message.id.clone()),
                        root: root.clone(),
                        ..Refs::default()
                    })
                    .root(root.as_deref()),
                )?;
                refused.push(refused_pot);
            }
            Err(error) => return Err(error),
        }
    }
    if !refused.is_empty() {
        let lines: Vec<String> = refused
            .iter()
            .map(|refused| {
                format!(
                    "{} was not woken: {}",
                    pot_name(conn, &refused.pot_id),
                    refused.reason
                )
            })
            .collect();
        append(
            conn,
            &thread,
            &Author::System,
            &format!("Not everything here was woken.\n\n{}", lines.join("\n")),
            &[],
            false,
            root.as_deref(),
            None,
        )?;
    }
    Ok(Posted {
        message,
        woken,
        refused,
    })
}

/// A settled wake's answer becomes the pot's message in the wake's thread.
/// Replies wake no one: a pot addresses others only by sending.
pub fn post_reply(conn: &Connection, wake_id: &str) -> ApiResult<Option<Message>> {
    type Settled = (
        String,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        String,
    );
    let found: Option<Settled> = conn
        .query_row(
            "SELECT owner_user,pot_id,thread_id,reply,causal_root,purpose_json
             FROM pot_wakes WHERE id=?1 AND state='settled'",
            [wake_id],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                ))
            },
        )
        .optional()?;
    let Some((owner, pot, Some(thread_id), Some(reply), root, purpose)) = found else {
        return Ok(None);
    };
    if reply.trim().is_empty() {
        return Ok(None);
    }
    // The thread may have been deleted while the pot worked.
    let thread = match get(conn, &owner, &thread_id) {
        Ok(thread) => thread,
        Err(error) if error.status == 404 => return Ok(None),
        Err(error) => return Err(error),
    };
    let reply: String = reply.chars().take(MAX_BODY / 4).collect();
    let message = append(
        conn,
        &thread,
        &Author::Pot(&pot),
        &reply,
        &[],
        false,
        root.as_deref(),
        None,
    )?;
    if let Some(root_id) = &root {
        // A reply the user reads is progress; a reply into a pot DM is another
        // message in a possible no-progress exchange.
        let result = if matches!(thread.kind.as_str(), "direct" | "group") {
            super::guard::progress(conn, root_id, &pot, "reply")
        } else {
            let peer = thread
                .pots
                .iter()
                .find(|candidate| *candidate != &pot)
                .map(String::as_str)
                .unwrap_or("");
            let purpose: serde_json::Value =
                serde_json::from_str(&purpose).unwrap_or_else(|_| json!({}));
            if peer.is_empty() {
                Ok(())
            } else {
                super::guard::note_message(conn, root_id, &pot, peer, &purpose)
            }
        };
        if let Err(error) = result {
            crate::log::warn(&format!("loop guard reply: {}", error.message));
        }
    }
    Ok(Some(message))
}
