//! Pushes about pots (plans/roadmap.md M8 step 0.3–0.4). Each names its
//! category and what it opens; none carries a pot's reply or other content
//! the app must read from the Gateway.

use rusqlite::Connection;
use serde_json::json;

use crate::push::{Category, PushMessage};

fn pot_name(conn: &Connection, pot_id: &str) -> String {
    super::threads::pot_name(conn, pot_id)
}

/// A pot asks to use a model for work (E25): it needs the user.
pub fn approval(conn: &Connection, approval: &super::approvals::Approval) -> PushMessage {
    PushMessage {
        title: format!("{} asks to use a model", pot_name(conn, &approval.pot_id)),
        body: format!(
            "{}/{} for \"{}\"",
            approval.provider, approval.model, approval.work_title
        ),
        tag: format!("approval:{}", approval.id),
        target: json!({ "approvalId": approval.id }),
        category: Some(Category::NeedsYou),
        interaction: None,
    }
}

/// One of a pot's own caps is used up: its model work waits for the user.
/// The tag and the activity key make this once per cap and window.
pub fn budget_exhausted(
    conn: &Connection,
    pot_id: &str,
    thread_id: &str,
    key: &str,
) -> PushMessage {
    PushMessage {
        title: format!("{} is blocked by its budget", pot_name(conn, pot_id)),
        body: "A budget limit is used up. Open the thread to review its limits.".to_owned(),
        tag: format!("budget-exhausted:{pot_id}:{key}"),
        target: json!({ "potId": pot_id, "threadId": thread_id }),
        category: Some(Category::NeedsYou),
        interaction: None,
    }
}

/// A pot asks for more budget: it needs the user.
pub fn budget_request(conn: &Connection, request: &super::budget::BudgetRequest) -> PushMessage {
    PushMessage {
        title: format!("{} asks for more budget", pot_name(conn, &request.pot_id)),
        body: "Open it to approve or deny.".to_owned(),
        tag: format!("budget-request:{}", request.id),
        target: json!({ "budgetRequestId": request.id }),
        category: Some(Category::NeedsYou),
        interaction: None,
    }
}

/// A pot proposes a handover: it needs the user.
pub fn handover(conn: &Connection, pot_id: &str, card: &super::threads::Message) -> PushMessage {
    PushMessage {
        title: format!("{} proposes a handover", pot_name(conn, pot_id)),
        body: "Open the thread to review it.".to_owned(),
        tag: format!("thread-message:{}", card.id),
        target: json!({ "potId": pot_id, "threadId": card.thread_id }),
        category: Some(Category::NeedsYou),
        interaction: None,
    }
}

/// A pot replied in a thread: done. The reply itself stays in the thread.
pub fn reply(conn: &Connection, pot_id: &str, message: &super::threads::Message) -> PushMessage {
    PushMessage {
        title: format!("{} replied", pot_name(conn, pot_id)),
        body: "Open the thread to read it.".to_owned(),
        tag: format!("thread:{}", message.thread_id),
        target: json!({ "potId": pot_id, "threadId": message.thread_id }),
        category: Some(Category::Done),
        interaction: None,
    }
}

/// A pot opened work: progress (off by default).
pub fn work_opened(
    conn: &Connection,
    pot_id: &str,
    title: &str,
    card: &super::threads::Message,
) -> PushMessage {
    PushMessage {
        title: format!("{} opened work", pot_name(conn, pot_id)),
        body: title.to_owned(),
        tag: format!("thread-message:{}", card.id),
        target: json!({ "potId": pot_id, "threadId": card.thread_id }),
        category: Some(Category::Progress),
        interaction: None,
    }
}
