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
    pub updated_at: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    pub thread_id: String,
    pub seq: i64,
    pub author_kind: String,
    pub author_id: Option<String>,
    pub body: String,
    pub mentions: Vec<String>,
    pub all: bool,
    pub created_at: i64,
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
        updated_at: row.get(9)?,
    })
}

const THREAD: &str = "SELECT id,kind,name,avatar_color,host_pot_id,project_id,pot_a,pot_b,last_seq,updated_at FROM threads";

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
    count(conn, owner)?;
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

/// The DM thread between two pots, made on first use.
fn pot_dm(conn: &Connection, owner: &str, a: &str, b: &str) -> ApiResult<Thread> {
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
    conn.execute(
        "INSERT INTO threads(id,owner_user,kind,name,avatar_color,host_pot_id,project_id,created_at,updated_at)
         VALUES(?1,?2,'group',?3,?4,?5,?6,?7,?7)",
        params![id, owner, name, input.avatar_color, input.host_pot_id, input.project_id, stamp],
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
    })
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
            "SELECT id,thread_id,seq,author_kind,author_id,body,mentions_json,all_mention,created_at
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
}

fn append(
    conn: &Connection,
    thread: &Thread,
    author: &Author,
    body: &str,
    mentions: &[String],
    all: bool,
    causal_root: Option<&str>,
) -> ApiResult<Message> {
    let body = body.trim();
    if body.is_empty() || body.len() > MAX_BODY {
        return Err(invalid("A message is 1 byte to 32 KiB"));
    }
    let (kind, id) = match author {
        Author::User => ("user", None),
        Author::Pot(pot) => ("pot", Some(*pot)),
    };
    let seq = conn.query_row(
        "UPDATE threads SET last_seq=last_seq+1,updated_at=?2 WHERE id=?1 RETURNING last_seq",
        params![thread.id, now_ms()],
        |r| r.get::<_, i64>(0),
    )?;
    let message_id = new_id("msg");
    conn.execute(
        "INSERT INTO messages(id,thread_id,seq,author_kind,author_id,body,mentions_json,all_mention,causal_root,created_at)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
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
        ],
    )?;
    Ok(conn.query_row(
        "SELECT id,thread_id,seq,author_kind,author_id,body,mentions_json,all_mention,created_at FROM messages WHERE id=?1",
        [&message_id],
        message_row,
    )?)
}

fn pot_name(conn: &Connection, pot: &str) -> String {
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
        Author::User => None,
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

/// The user posts in a thread; returns the message and the pots to kick.
pub fn post_user(
    conn: &Connection,
    owner: &str,
    thread_id: &str,
    body: &str,
    mentions: Vec<String>,
    all: bool,
) -> ApiResult<(Message, Vec<String>)> {
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
    let message = append(conn, &thread, &Author::User, body, &mentions, all, None)?;
    let woken = addressees(&thread, &Author::User, &mentions, all);
    let text = wake_text(conn, owner, &thread, &Author::User, &message.body);
    let source = if thread.kind == "group" {
        Source::Group
    } else {
        Source::User
    };
    for pot in &woken {
        runtime::enqueue(
            conn,
            owner,
            pot,
            NewWake {
                source,
                thread_id: Some(&thread.id),
                causal_root: None,
                content: &text,
                details: json!({ "threadId": thread.id, "messageId": message.id }),
            },
        )?;
    }
    Ok((message, woken))
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
/// allow; a pot can never address everyone.
pub fn post_pot(
    conn: &Connection,
    owner: &str,
    from: &str,
    target: Target,
    body: &str,
    mentions: Vec<String>,
    causal_root: Option<&str>,
) -> ApiResult<(Message, Vec<String>)> {
    let thread = match target {
        Target::Pot(to) => {
            if to == from {
                return Err(invalid("A pot cannot message itself"));
            }
            if !dm_allowed(conn, owner, from, to)? {
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
    let message = append(conn, &thread, &author, body, &mentions, false, causal_root)?;
    let mut woken = Vec::new();
    for pot in addressees(&thread, &author, &mentions, false) {
        // In a group, only a mention wakes another pot, and only if allowed.
        if thread.kind == "group" && (mentions.is_empty() || !dm_allowed(conn, owner, from, &pot)?)
        {
            continue;
        }
        woken.push(pot);
    }
    if thread.kind == "direct" {
        // A pot writing in its own direct thread notifies the user, wakes no one.
        woken.clear();
    }
    let text = wake_text(conn, owner, &thread, &author, &message.body);
    let source = if thread.kind == "group" {
        Source::Group
    } else {
        Source::Dm
    };
    for pot in &woken {
        runtime::enqueue(
            conn,
            owner,
            pot,
            NewWake {
                source,
                thread_id: Some(&thread.id),
                causal_root,
                content: &text,
                details: json!({ "threadId": thread.id, "messageId": message.id, "fromPot": from }),
            },
        )?;
    }
    Ok((message, woken))
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
    );
    let found: Option<Settled> = conn
        .query_row(
            "SELECT owner_user,pot_id,thread_id,reply,causal_root FROM pot_wakes WHERE id=?1 AND state='settled'",
            [wake_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()?;
    let Some((owner, pot, Some(thread_id), Some(reply), root)) = found else {
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
    Ok(Some(append(
        conn,
        &thread,
        &Author::Pot(&pot),
        &reply,
        &[],
        false,
        root.as_deref(),
    )?))
}
