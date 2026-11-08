//! C1 operation authority: backend permission to advance exactly one accepted
//! transition when no device holds control. It is not a control lease, not an
//! execution grant and never a folder or host-management permission. The Node
//! keeps only the token hash and checks it at each automatic effect admission.
use super::*;

/// How far the wall clock may step back (NTP slew) before authority is
/// treated as uncertain rather than extended.
const CLOCK_TOLERANCE_MS: i64 = 5_000;

/// Issued with the fence (revision 1) or by explicit reauthorization.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Grant {
    pub revision: i64,
    pub token_hash: String,
    pub deadline_at: i64,
}
/// Presented by the coordinator for an automatic step.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Presented {
    pub revision: i64,
    pub token: String,
}

fn refused(code: &'static str, message: &str) -> ApiError {
    ApiError::new(409, code, message)
}
fn hex64(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
/// Record a grant in the caller's transaction. Any newer revision supersedes the
/// latest, so a reauthorization whose reply was lost can be issued again.
pub(crate) fn record(db: &Connection, owner: &str, op: &str, grant: &Grant) -> ApiResult<()> {
    let now = now_ms();
    if !hex64(&grant.token_hash) || grant.deadline_at <= now {
        return Err(ApiError::invalid_input());
    }
    let latest: Option<i64> = db.query_row(
        "SELECT max(revision) FROM operation_authorities WHERE owner_user=?1 AND operation_id=?2",
        params![owner, op],
        |r| r.get(0),
    )?;
    if grant.revision <= latest.unwrap_or(0) {
        return Err(refused(
            "operation_authority_revision",
            "Operation authority revisions must be newer than the latest one",
        ));
    }
    db.execute(
        "INSERT INTO operation_authorities VALUES(?1,?2,?3,?4,?5,?6,NULL)",
        params![
            owner,
            op,
            grant.revision,
            grant.token_hash,
            grant.deadline_at,
            now
        ],
    )?;
    Ok(())
}
/// Advance the persisted clock watermark, refusing when time moved back.
fn clock(db: &Connection, now: i64) -> ApiResult<()> {
    let seen: Option<i64> = db
        .query_row(
            "SELECT max_seen_at FROM operation_authority_clock WHERE id=1",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if seen.is_some_and(|seen| now + CLOCK_TOLERANCE_MS < seen) {
        return Err(refused(
            "operation_authority_clock_uncertain",
            "The clock moved back; reauthorize before continuing",
        ));
    }
    db.execute(
        "INSERT INTO operation_authority_clock VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET max_seen_at=max(max_seen_at,excluded.max_seen_at)",
        [now],
    )?;
    Ok(())
}
/// Verify the presented authority is the latest, unrevoked and unexpired one.
pub(crate) fn verify(
    db: &Connection,
    owner: &str,
    op: &str,
    presented: &Presented,
) -> ApiResult<()> {
    clock(db, now_ms())?;
    let latest: Option<(i64, String, i64, Option<i64>)> = db
        .query_row(
            "SELECT revision,token_hash,deadline_at,revoked_at FROM operation_authorities WHERE owner_user=?1 AND operation_id=?2 ORDER BY revision DESC LIMIT 1",
            params![owner, op],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()?;
    let Some((revision, hash, deadline, revoked)) = latest else {
        return Err(refused(
            "operation_authority_missing",
            "This transition has no operation authority",
        ));
    };
    if presented.revision != revision {
        return Err(refused(
            "operation_authority_superseded",
            "A newer operation authority replaced this one",
        ));
    }
    if crate::util::sha256_hex(&presented.token) != hash {
        return Err(ApiError::new(
            403,
            "operation_authority_invalid",
            "The operation authority does not match",
        ));
    }
    if revoked.is_some() {
        return Err(refused(
            "operation_authority_revoked",
            "The operation authority was revoked",
        ));
    }
    if deadline <= now_ms() {
        return Err(refused(
            "operation_authority_expired",
            "The operation authority expired; reauthorize to continue",
        ));
    }
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Renewal {
    plan_hash: String,
    client_id: String,
    generation: i64,
    #[serde(default)]
    grant: Option<Grant>,
    #[serde(default)]
    revoke: bool,
}
/// Explicit reauthorization or revocation by the current controller. It keeps
/// the same operation and step identities and never changes the frozen target.
pub async fn renew(node: Node, request: Request) -> ApiResult<Response> {
    let body: Renewal = request.parse_body()?;
    let session = request.param("id").unwrap_or_default();
    let op = request.param("operation").unwrap_or_default();
    if body.revoke == body.grant.is_some() {
        return Err(ApiError::invalid_input());
    }
    {
        let db = node.db.lock();
        db.claim_session(session, &request.user, false)?;
        let saved = receipt(&db, &request.user, session, op)?
            .ok_or_else(|| ApiError::not_found("Transition not found"))?;
        if saved.intent.plan_hash != body.plan_hash {
            return Err(ApiError::conflict(
                "This request targets a different transition plan",
            ));
        }
        if matches!(saved.state.as_str(), "installed" | "released" | "deleted") {
            return Err(refused(
                "transition_ended",
                "An ended transition needs no operation authority",
            ));
        }
        db.validate_lease(session, &body.client_id, body.generation)?;
        match &body.grant {
            Some(grant) => record(&db, &request.user, op, grant)?,
            None => {
                db.execute("UPDATE operation_authorities SET revoked_at=?3 WHERE owner_user=?1 AND operation_id=?2 AND revoked_at IS NULL",params![request.user,op,now_ms()])?;
            }
        }
    }
    let saved =
        receipt(&node.db.lock(), &request.user, session, op)?.ok_or_else(ApiError::internal)?;
    Ok(Response::json(
        json!({"transition":network_observation(&node, session, saved)}),
    ))
}
