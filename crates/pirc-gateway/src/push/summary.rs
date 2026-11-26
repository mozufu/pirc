//! The summary sender (plans/roadmap.md M8 default D): items at level
//! `digest`, and items held during quiet hours, wait in `push_digest_items`
//! and go out as one push per target at its digest time or when its quiet
//! hours end.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use rusqlite::params;
use serde_json::json;

use super::{Delivery, Push, PushMessage, SubscriptionRow, clip, payload, prune, topic_of};
use crate::util::now_ms;

/// A kept item: its row ID, category and title.
type DigestItem = (i64, String, String);

/// Items kept per target for its next summary; older ones are dropped.
const MAX_DIGEST_ITEMS: i64 = 100;
/// How often the summary sender looks for due summaries.
const SUMMARY_TICK: Duration = Duration::from_secs(60);

impl Push {
    /// Keep a message for the target's next summary.
    pub(super) fn keep_for_summary(&self, subscription_id: &str, message: &PushMessage, now: i64) {
        let Some(category) = message.category else {
            return;
        };
        let title = String::from_utf16_lossy(&clip(&message.title, 120));
        let conn = self.db.lock();
        let kept = conn
            .execute(
                "INSERT INTO push_digest_items (subscription_id,category,title,created_at) VALUES (?,?,?,?)",
                params![subscription_id, category.as_str(), title, now],
            )
            .and_then(|_| {
                conn.execute(
                    "DELETE FROM push_digest_items WHERE subscription_id=?1 AND id NOT IN
                       (SELECT id FROM push_digest_items WHERE subscription_id=?1 ORDER BY id DESC LIMIT ?2)",
                    params![subscription_id, MAX_DIGEST_ITEMS],
                )
            });
        if let Err(error) = kept {
            crate::log::warn(&format!(
                "push: cannot keep an item for the summary: {error}"
            ));
        }
    }

    /// Send every summary that is due as of `now`: one push per target at
    /// its digest time and one when its quiet hours end, each only when
    /// items wait. A summary missed while the Gateway was offline goes out
    /// on the first call after it starts. The items and the target's mark
    /// change only after the push service took the summary; a failed one is
    /// tried again on the next call. Calls run one at a time, so no items are
    /// sent twice. How many summaries were sent.
    pub async fn send_summaries(self: &Arc<Self>, now: i64) -> usize {
        let _one_at_a_time = self.summaries.lock().await;
        let due: Vec<(SubscriptionRow, Vec<DigestItem>)> = {
            let conn = self.db.lock();
            let rows = prune(&conn).and_then(|()| {
                conn.prepare("SELECT * FROM push_subscriptions")?
                    .query_map([], SubscriptionRow::from_row)?
                    .collect::<rusqlite::Result<Vec<_>>>()
            });
            let rows = match rows {
                Ok(rows) => rows,
                Err(error) => {
                    crate::log::warn(&format!("push: cannot read subscriptions: {error}"));
                    return 0;
                }
            };
            let mut due = Vec::new();
            for row in rows {
                let prefs = &row.preferences;
                let summary_due = !prefs.quiet_at(now)
                    && (row.summary_now || prefs.summary_due(row.summary_mark, now));
                if !summary_due {
                    continue;
                }
                let items = conn
                    .prepare(
                        "SELECT id,category,title FROM push_digest_items WHERE subscription_id=? ORDER BY id",
                    )
                    .and_then(|mut statement| {
                        statement
                            .query_map([&row.id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                            .collect::<rusqlite::Result<Vec<DigestItem>>>()
                    });
                match items {
                    Ok(items) if items.is_empty() => {
                        // Nothing waits: this moment is handled.
                        let _ = settle(&conn, &row.id, None, now, row.revision);
                    }
                    Ok(items) => due.push((row, items)),
                    Err(error) => {
                        crate::log::warn(&format!("push: cannot read a summary: {error}"));
                    }
                }
            }
            due
        };
        let mut sends = tokio::task::JoinSet::new();
        for (row, items) in due {
            let message = summary_message(&items);
            let payload = payload(
                &message,
                now_ms(),
                Delivery {
                    silent: false,
                    lock_screen: Some(row.preferences.lock_screen),
                },
            );
            let push = self.clone();
            let topic = topic_of(&message.tag);
            let read = (row.id.clone(), row.revision);
            let last = items.last().map(|(id, _, _)| *id);
            sends.spawn(async move { (read, last, push.send(row, &payload, &topic).await) });
        }
        let mut sent = 0;
        while let Some(done) = sends.join_next().await {
            let Ok(((id, revision), last, true)) = done else {
                continue;
            };
            sent += 1;
            if let Err(error) = settle(&self.db.lock(), &id, last, now, revision) {
                crate::log::warn(&format!("push: cannot settle a summary: {error}"));
            }
        }
        sent
    }
}

/// A summary went out (or nothing waited): drop the items it listed and mark
/// the target's summary moments up to `now` handled. A preference change
/// that landed while the summary was sent (a newer `revision`) keeps its own
/// later mark and its "summary due now" flag.
pub(super) fn settle(
    conn: &rusqlite::Connection,
    subscription_id: &str,
    last_item: Option<i64>,
    now: i64,
    read_revision: i64,
) -> rusqlite::Result<()> {
    if let Some(last) = last_item {
        conn.execute(
            "DELETE FROM push_digest_items WHERE subscription_id=? AND id<=?",
            params![subscription_id, last],
        )?;
    }
    conn.execute(
        "UPDATE push_subscriptions SET summary_mark=MAX(summary_mark, ?1),
           summary_now=CASE WHEN revision=?3 THEN 0 ELSE summary_now END
         WHERE id=?2",
        params![now, subscription_id, read_revision],
    )?;
    Ok(())
}

/// One summary push: how many items wait and their titles, opening the
/// Activity tab. The items stay in their own lists; this only points there.
fn summary_message(items: &[DigestItem]) -> PushMessage {
    let count = items.len();
    let titles: Vec<&str> = items
        .iter()
        .map(|(_, _, title)| title.as_str())
        .filter(|title| !title.is_empty())
        .collect();
    let mut categories: BTreeMap<&str, usize> = BTreeMap::new();
    for (_, category, _) in items {
        *categories.entry(category.as_str()).or_default() += 1;
    }
    PushMessage {
        title: if count == 1 {
            "1 new update".to_owned()
        } else {
            format!("{count} new updates")
        },
        body: titles.join(" · "),
        tag: "summary".to_owned(),
        target: json!({ "activity": true, "summary": { "count": count, "categories": categories } }),
        category: None,
        interaction: None,
    }
}

/// The summary sender: every minute, and once at startup so a summary that
/// fell due while the Gateway was offline goes out on its first tick.
pub(super) fn start(push: Arc<Push>) {
    let weak = Arc::downgrade(&push);
    drop(push);
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(SUMMARY_TICK);
        loop {
            interval.tick().await;
            let Some(push) = weak.upgrade() else {
                return;
            };
            push.send_summaries(now_ms()).await;
        }
    });
}
