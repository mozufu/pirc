//! C1 operation authority issued by the Gateway for one accepted transition.
//! The coordinator presents it to the Node for automatic steps when no device
//! holds control. It never impersonates a device lease or widens any grant.
use super::*;

/// How far the wall clock may step back before authority becomes uncertain.
const CLOCK_TOLERANCE_MS: i64 = 5_000;

pub(super) struct Authority {
    pub revision: i64,
    pub token: String,
    pub deadline_at: i64,
    pub revoked: bool,
}
fn latest(db: &Connection, user: &str, op: &str) -> ApiResult<Option<Authority>> {
    Ok(db
        .query_row(
            "SELECT revision,token,deadline_at,revoked_at IS NOT NULL FROM conversation_operation_authorities WHERE owner_user=?1 AND operation_id=?2 ORDER BY revision DESC LIMIT 1",
            params![user, op],
            |r| {
                Ok(Authority {
                    revision: r.get(0)?,
                    token: r.get(1)?,
                    deadline_at: r.get(2)?,
                    revoked: r.get(3)?,
                })
            },
        )
        .optional()?)
}
/// Issue the next revision with a deadline from the configured policy.
pub(super) fn issue(
    db: &Connection,
    user: &str,
    id: &str,
    op: &str,
    secs: u64,
) -> ApiResult<Authority> {
    let now = now_ms();
    let revision = latest(db, user, op)?.map_or(0, |a| a.revision) + 1;
    let token: String = crate::util::random_bytes::<32>()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let deadline = now.saturating_add(i64::try_from(secs.saturating_mul(1000)).unwrap_or(i64::MAX));
    db.execute(
        "INSERT INTO conversation_operation_authorities VALUES(?1,?2,?3,?4,?5,?6,?7,NULL)",
        params![user, op, id, revision, token, deadline, now],
    )?;
    Ok(Authority {
        revision,
        token,
        deadline_at: deadline,
        revoked: false,
    })
}
/// What the Node stores: the hash, never the token.
pub(super) fn grant(a: &Authority) -> Value {
    json!({"revision":a.revision,"tokenHash":crate::util::sha256_hex(&a.token),"deadlineAt":a.deadline_at})
}
pub(super) fn latest_grant(db: &Connection, user: &str, op: &str) -> ApiResult<Option<Value>> {
    Ok(latest(db, user, op)?
        .filter(|a| !a.revoked)
        .map(|a| grant(&a)))
}
/// `active`, `expired`, `revoked` or `clock_uncertain`; None without authority.
fn condition(db: &Connection, a: &Authority) -> ApiResult<&'static str> {
    condition_at(db, a, true)
}
/// `record` advances the clock watermark; read-only status never writes.
fn condition_at(db: &Connection, a: &Authority, record: bool) -> ApiResult<&'static str> {
    let now = now_ms();
    let seen: Option<i64> = db
        .query_row(
            "SELECT max_seen_at FROM conversation_authority_clock WHERE id=1",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if seen.is_some_and(|seen| now + CLOCK_TOLERANCE_MS < seen) {
        return Ok("clock_uncertain");
    }
    if record {
        db.execute(
            "INSERT INTO conversation_authority_clock VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET max_seen_at=max(max_seen_at,excluded.max_seen_at)",
            [now],
        )?;
    }
    Ok(if a.revoked {
        "revoked"
    } else if a.deadline_at <= now {
        "expired"
    } else {
        "active"
    })
}
/// The authority the coordinator may present now, if any is active.
pub(super) fn usable(db: &Connection, user: &str, op: &str) -> ApiResult<Option<(i64, String)>> {
    let Some(a) = latest(db, user, op)? else {
        return Ok(None);
    };
    Ok((condition(db, &a)? == "active").then_some((a.revision, a.token)))
}
/// Whether the operation has authority at all (even an expired one).
pub(super) fn exists(db: &Connection, user: &str, op: &str) -> ApiResult<bool> {
    Ok(latest(db, user, op)?.is_some())
}
/// Public status: revision, deadline and condition; never the token.
pub(super) fn status(db: &Connection, user: &str, op: &str) -> ApiResult<Value> {
    let Some(a) = latest(db, user, op)? else {
        return Ok(Value::Null);
    };
    let condition = condition_at(db, &a, false)?;
    Ok(
        json!({"revision":a.revision,"deadlineAt":a.deadline_at,"state":condition,
        "reauthorizationRequired":condition!="active"}),
    )
}
