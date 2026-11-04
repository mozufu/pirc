//! A model-provided dialog, an approval mode or an old launch cannot authorize
//! host management. Only a Node-issued, durably answered, exact-intent question
//! can be consumed at the same commit that reserves a new host run.
use super::Origin;
use crate::{
    error::{ApiError, ApiResult},
    services::Node,
    util::now_ms,
};
use rusqlite::{Connection, params};

pub(crate) enum Authority {
    HostManagement {
        interaction: String,
        intent_hash: String,
    },
    /// Low-level supervisor fixtures model previously authorized host execution.
    /// This variant does not exist in product binaries or manufacture evidence.
    #[cfg(test)]
    SupervisorFixture,
}

pub(crate) struct Request<'a> {
    pub session: &'a str,
    pub workspace: &'a str,
    pub epoch: i64,
    pub request: &'a str,
    pub intent_hash: &'a str,
}

pub(crate) fn record(
    db: &Connection,
    node: &Node,
    request: Request<'_>,
    interaction: &str,
) -> ApiResult<()> {
    let changed = db.execute(
        "INSERT INTO host_execution_approvals
         (interaction_id,execution_path,session_id,workspace_id,runner_epoch,incarnation,request_id,intent_hash,created_at)
         VALUES(?1,'host_management',?2,?3,?4,?5,?6,?7,?8)
         ON CONFLICT(session_id,runner_epoch,incarnation,request_id) DO NOTHING",
        params![interaction,request.session,request.workspace,request.epoch,node.incarnation,request.request,request.intent_hash,now_ms()],
    )?;
    if changed != 1 {
        return Err(ApiError::conflict(
            "This host-management request already has a question; use its existing result instead of requesting another approval",
        ));
    }
    Ok(())
}

fn required() -> ApiError {
    ApiError::new(
        409,
        "host_management_approval_required",
        "Host management requires a current Node-issued approval for this exact command and environment",
    )
}

impl Authority {
    pub(super) fn validate(&self, db: &Connection, node: &Node, origin: &Origin) -> ApiResult<()> {
        let (interaction, intent_hash) = match self {
            Self::HostManagement {
                interaction,
                intent_hash,
            } => (interaction, intent_hash),
            #[cfg(test)]
            Self::SupervisorFixture => return Ok(()),
        };
        let valid: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM host_execution_approvals a
             JOIN interactions i ON i.id=a.interaction_id
             WHERE a.interaction_id=?1 AND a.intent_hash=?2 AND a.session_id=?3
             AND a.workspace_id=?4 AND a.runner_epoch=?5 AND a.incarnation=?6
             AND a.request_id=?7 AND a.run_id IS NULL
             AND i.session_id=a.session_id AND i.runner_epoch=a.runner_epoch
             AND i.kind='confirm' AND i.status='answered' AND i.expires_at>?8
             AND json_type(i.answer_json,'$.confirmed')='true'
             AND coalesce(json_type(i.answer_json,'$.cancelled'),'null')!='true')",
            params![
                interaction,
                intent_hash,
                origin.session,
                origin.workspace,
                origin.epoch,
                node.incarnation,
                origin.request,
                now_ms()
            ],
            |r| r.get(0),
        )?;
        if !valid {
            return Err(required());
        }
        Ok(())
    }

    pub(super) fn consume(
        &self,
        db: &Connection,
        node: &Node,
        origin: &Origin,
        run: &str,
    ) -> ApiResult<()> {
        self.validate(db, node, origin)?;
        match self {
            Self::HostManagement { interaction, .. } => {
                let changed = db.execute(
                    "UPDATE host_execution_approvals SET run_id=?2 WHERE interaction_id=?1 AND run_id IS NULL",
                    params![interaction, run],
                )?;
                if changed != 1 {
                    return Err(required());
                }
            }
            #[cfg(test)]
            Self::SupervisorFixture => {}
        }
        Ok(())
    }
}

#[cfg(test)]
pub(crate) mod tests;
