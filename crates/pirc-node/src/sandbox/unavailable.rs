//! The backend of platforms without a sandbox: every check is unavailable,
//! so no agent starts and the Git panel cannot run. Owner: **hardening**.
//!
//! `PIRC_SANDBOX_SRT` still works there ([`super::srt`]), as TS's external
//! srt did.

use super::{
    BoxFuture, PrepareInput, Prepared, ReadonlyInput, Sandbox, SandboxStatus, unavailable_error,
};
use crate::error::ApiResult;

/// Why, on a platform without a native sandbox: shown in the node's log
/// and in every refused start.
pub const PLATFORM_REASON: &str = "this node has no sandbox for its platform yet (the native sandbox runs on Linux); set PIRC_SANDBOX_SRT to an srt-compatible sandbox";

/// No sandbox, for `reason`.
pub struct UnavailableSandbox {
    reason: String,
}

impl UnavailableSandbox {
    pub fn new(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
        }
    }
}

impl Sandbox for UnavailableSandbox {
    fn check(&self) -> BoxFuture<'_, SandboxStatus> {
        Box::pin(async {
            SandboxStatus::Unavailable {
                reason: self.reason.clone(),
            }
        })
    }

    fn prepare(&self, input: PrepareInput) -> BoxFuture<'_, ApiResult<Prepared>> {
        let _ = input;
        Box::pin(async { Err(unavailable_error(&self.reason)) })
    }

    fn prepare_readonly(&self, input: ReadonlyInput) -> BoxFuture<'_, ApiResult<Prepared>> {
        let _ = input;
        Box::pin(async { Err(unavailable_error(&self.reason)) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn refuses_every_agent() {
        let sandbox = UnavailableSandbox::new(PLATFORM_REASON);
        assert!(matches!(
            sandbox.check().await,
            SandboxStatus::Unavailable { .. }
        ));
        let error = sandbox
            .prepare(PrepareInput {
                grants: Vec::new(),
                session_id: "s".into(),
                workspace_root: "/w".into(),
                session_dir: "/s".into(),
                inference_socket: None,
                protected_paths: Vec::new(),
                workspace_memory_file: None,
                project_files_dir: None,
                recovery: None,
            })
            .await
            .err()
            .unwrap();
        assert_eq!(
            (error.status, error.code.as_ref()),
            (503, "runner_unavailable")
        );
        assert!(error.message.ends_with(PLATFORM_REASON));
    }
}
