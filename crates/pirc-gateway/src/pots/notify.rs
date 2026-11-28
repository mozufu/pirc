//! Pushes about pots (plans/roadmap.md M8 step 0.3–0.4). Each names its
//! category and what it opens; none carries a pot's reply or other content
//! the app must read from the Gateway.

use rusqlite::Connection;
use serde_json::json;

use crate::push::text::{self, PushText};
use crate::push::{Category, PushMessage};

fn pot_name(conn: &Connection, pot_id: &str) -> String {
    super::threads::pot_name(conn, pot_id)
}

/// A pot asks to use a model for work (E25): it needs the user.
pub fn approval(conn: &Connection, approval: &super::approvals::Approval) -> PushMessage {
    let pot = pot_name(conn, &approval.pot_id);
    PushMessage {
        title: format!("{pot} asks to use a model"),
        body: format!(
            "{}/{} for \"{}\"",
            approval.provider, approval.model, approval.work_title
        ),
        tag: format!("approval:{}", approval.id),
        target: json!({ "approvalId": approval.id }),
        category: Some(Category::NeedsYou),
        interaction: None,
        text: Some(PushText::new(
            text::POT_APPROVAL,
            &[
                ("pot", &pot),
                ("provider", &approval.provider),
                ("model", &approval.model),
                ("work", &approval.work_title),
            ],
        )),
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
    let pot = pot_name(conn, pot_id);
    PushMessage {
        title: format!("{pot} is blocked by its budget"),
        body: text::BUDGET_BLOCKED_BODY.to_owned(),
        tag: format!("budget-exhausted:{pot_id}:{key}"),
        target: json!({ "potId": pot_id, "threadId": thread_id }),
        category: Some(Category::NeedsYou),
        interaction: None,
        text: Some(PushText::new(text::POT_BUDGET_BLOCKED, &[("pot", &pot)])),
    }
}

/// A pot asks for more budget: it needs the user.
pub fn budget_request(conn: &Connection, request: &super::budget::BudgetRequest) -> PushMessage {
    let pot = pot_name(conn, &request.pot_id);
    PushMessage {
        title: format!("{pot} asks for more budget"),
        body: text::BUDGET_REQUEST_BODY.to_owned(),
        tag: format!("budget-request:{}", request.id),
        target: json!({ "budgetRequestId": request.id }),
        category: Some(Category::NeedsYou),
        interaction: None,
        text: Some(PushText::new(text::POT_BUDGET_REQUEST, &[("pot", &pot)])),
    }
}

/// A pot proposes a handover: it needs the user.
pub fn handover(conn: &Connection, pot_id: &str, card: &super::threads::Message) -> PushMessage {
    let pot = pot_name(conn, pot_id);
    PushMessage {
        title: format!("{pot} proposes a handover"),
        body: text::HANDOVER_BODY.to_owned(),
        tag: format!("thread-message:{}", card.id),
        target: json!({ "potId": pot_id, "threadId": card.thread_id }),
        category: Some(Category::NeedsYou),
        interaction: None,
        text: Some(PushText::new(text::POT_HANDOVER, &[("pot", &pot)])),
    }
}

/// A pot replied in a thread: done. The reply itself stays in the thread.
pub fn reply(conn: &Connection, pot_id: &str, message: &super::threads::Message) -> PushMessage {
    let pot = pot_name(conn, pot_id);
    PushMessage {
        title: format!("{pot} replied"),
        body: text::REPLIED_BODY.to_owned(),
        tag: format!("thread:{}", message.thread_id),
        target: json!({ "potId": pot_id, "threadId": message.thread_id }),
        category: Some(Category::Done),
        interaction: None,
        text: Some(PushText::new(text::POT_REPLIED, &[("pot", &pot)])),
    }
}

/// A pot opened work: progress (off by default).
pub fn work_opened(
    conn: &Connection,
    pot_id: &str,
    title: &str,
    card: &super::threads::Message,
) -> PushMessage {
    let pot = pot_name(conn, pot_id);
    PushMessage {
        title: format!("{pot} opened work"),
        body: title.to_owned(),
        tag: format!("thread-message:{}", card.id),
        target: json!({ "potId": pot_id, "threadId": card.thread_id }),
        category: Some(Category::Progress),
        interaction: None,
        text: Some(PushText::new(text::POT_OPENED_WORK, &[("pot", &pot)])),
    }
}
