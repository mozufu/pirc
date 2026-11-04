//! Restart recovery requires BOTH the scoped namespace and its Node I/O owner
//! to be gone. A registry miss, a new incarnation or a shell exit is not proof.
use crate::{
    error::{ApiError, ApiResult},
    sandbox::{
        linux::processes::owner,
        processes::{Identity, ObserverIdentity},
    },
    services::Node,
    store,
    util::now_ms,
};
use rusqlite::{Connection, params};
use std::{collections::HashMap, sync::Arc};

pub(super) fn record(
    db: &Connection,
    incarnation: &str,
    identity: &ObserverIdentity,
) -> ApiResult<()> {
    if db.is_autocommit() {
        return Err(ApiError::internal());
    }
    owner::validate(identity).map_err(|_| ApiError::internal())?;
    let json = serde_json::to_string(identity).map_err(|_| ApiError::internal())?;
    let at = now_ms();
    db.execute("INSERT INTO terminal_io_owners VALUES(?1,?2,'captured',?3,?3) ON CONFLICT(incarnation) DO NOTHING",params![incarnation,json,at])?;
    let (saved, state): (String, String) = db.query_row(
        "SELECT identity_json,state FROM terminal_io_owners WHERE incarnation=?1",
        [incarnation],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    if saved != json || state != "captured" {
        return Err(ApiError::conflict("Terminal I/O owner identity changed"));
    }
    Ok(())
}
fn require_fenced(db: &Connection, session: &str) -> ApiResult<()> {
    let fenced: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM execution_fences WHERE session_id=?1 AND state!='deleted')",
        [session],
        |r| r.get(0),
    )?;
    if !fenced {
        return Err(ApiError::conflict(
            "Terminal owner recovery requires a transition fence",
        ));
    }
    Ok(())
}
struct Candidate {
    row: i64,
    id: String,
    incarnation: String,
    owner: String,
    owner_gone: bool,
    kernel: String,
}
fn batch(db: &Connection, session: &str, after: i64, ceiling: i64) -> ApiResult<Vec<Candidate>> {
    require_fenced(db, session)?;
    let mut query = db.prepare(
        "SELECT t.rowid,t.id,t.incarnation,o.identity_json,o.state='gone',l.identity_json
      FROM terminal_runs t JOIN terminal_io_owners o ON o.incarnation=t.incarnation
      JOIN sandbox_launches l ON l.launch_id=t.id AND l.session_id=t.session_id
       AND l.workspace_id=t.workspace_id AND l.incarnation=t.incarnation
      WHERE t.session_id=?1 AND t.rowid>?2 AND t.rowid<=?3
       AND t.state IN ('launching','running','unconfirmed')
       AND l.resource_kind='terminal' AND l.state='terminated' AND l.identity_json IS NOT NULL
      ORDER BY t.rowid LIMIT 64",
    )?;
    Ok(query
        .query_map(params![session, after, ceiling], |r| {
            Ok(Candidate {
                row: r.get(0)?,
                id: r.get(1)?,
                incarnation: r.get(2)?,
                owner: r.get(3)?,
                owner_gone: r.get(4)?,
                kernel: r.get(5)?,
            })
        })?
        .collect::<Result<_, _>>()?)
}
fn matches(owner: &ObserverIdentity, kernel: &Identity) -> bool {
    crate::sandbox::linux::processes::owner::matches(owner, kernel)
}
fn commit(db: &Connection, session: &str, row: &Candidate) -> ApiResult<()> {
    store::atomic(db, |db| {
        require_fenced(db, session)?;
        // The owner observation is read-only and irreversible. Its recorded
        // identity cannot be replaced by another Node process or reader.
        db.execute("UPDATE terminal_io_owners SET state='gone',updated_at=?3 WHERE incarnation=?1 AND identity_json=?2 AND state='captured'",params![row.incarnation,row.owner,now_ms()])?;
        db.execute("UPDATE terminal_runs SET state='settled',updated_at=?4
          WHERE id=?1 AND session_id=?2 AND incarnation=?3 AND state IN ('launching','running','unconfirmed')
          AND EXISTS(SELECT 1 FROM sandbox_launches l JOIN terminal_io_owners o ON o.incarnation=terminal_runs.incarnation
           WHERE l.launch_id=terminal_runs.id AND l.session_id=terminal_runs.session_id
            AND l.workspace_id=terminal_runs.workspace_id AND l.incarnation=terminal_runs.incarnation
            AND l.resource_kind='terminal' AND l.state='terminated' AND l.identity_json=?5
            AND o.identity_json=?6 AND o.state='gone')",params![row.id,session,row.incarnation,now_ms(),row.kernel,row.owner])?;
        Ok(())
    })
}
type Check = Arc<dyn Fn(&ObserverIdentity) -> std::io::Result<bool> + Send + Sync>;
pub(crate) async fn recover(node: &Node, session: &str) -> ApiResult<()> {
    recover_with(node, session, Arc::new(owner::gone)).await
}
async fn recover_with(node: &Node, session: &str, check: Check) -> ApiResult<()> {
    let ceiling = {
        let db = node.db.lock();
        require_fenced(&db, session)?;
        db.query_row(
            "SELECT coalesce(max(rowid),0) FROM terminal_runs WHERE session_id=?1",
            [session],
            |r| r.get::<_, i64>(0),
        )?
    };
    let mut after = 0;
    let mut cache = HashMap::<String, bool>::new();
    loop {
        let rows = batch(&node.db.lock(), session, after, ceiling)?;
        if rows.is_empty() {
            break;
        }
        after = rows.last().unwrap().row;
        let check = check.clone();
        let (verified, next_cache) = tokio::task::spawn_blocking(move || {
            let mut verified = Vec::new();
            for row in rows {
                let Ok(identity) = serde_json::from_str::<ObserverIdentity>(&row.owner) else {
                    continue;
                };
                let Ok(kernel) = serde_json::from_str::<Identity>(&row.kernel) else {
                    continue;
                };
                if !matches(&identity, &kernel) {
                    continue;
                }
                let gone = if row.owner_gone {
                    true
                } else if let Some(gone) = cache.get(&row.owner) {
                    *gone
                } else {
                    let gone = check(&identity).unwrap_or(false);
                    if cache.len() >= 128 {
                        cache.clear();
                    }
                    cache.insert(row.owner.clone(), gone);
                    gone
                };
                if gone {
                    verified.push(row);
                }
            }
            (verified, cache)
        })
        .await
        .map_err(|_| ApiError::internal())?;
        cache = next_cache;
        for row in verified {
            commit(&node.db.lock(), session, &row)?;
        }
        // Bounded DB pages and owner cache: unresolved early rows cannot hide
        // later retired owners, and large histories yield between pages.
        tokio::task::yield_now().await;
    }
    Ok(())
}

#[cfg(test)]
mod tests;
