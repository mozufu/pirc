//! Compatibility negotiation is not authentication. Legacy clients can still
//! inspect/cancel owned outcomes, but cannot start this version's first Send.
use super::*;
use axum::http::HeaderMap;
pub(super) const CONTRACT: i64 = 2;
const HEADER: &str = "x-pirc-first-send-contract";
fn negotiated(headers: &HeaderMap) -> bool {
    let mut values = headers.get_all(HEADER).iter();
    matches!((values.next(), values.next()), (Some(value), None) if value.as_bytes() == b"2")
}
pub(super) fn require(headers: &HeaderMap) -> ApiResult<()> {
    if negotiated(headers) {
        Ok(())
    } else {
        Err(ApiError::new(
            409,
            "first_send_client_upgrade_required",
            "This client does not support the required first-send recovery contract. Update it before sending.",
        ))
    }
}
pub(super) fn capabilities(identity: &Identity, headers: &HeaderMap) -> Value {
    let compatible = negotiated(headers);
    json!({"version":1,"clientContract":if compatible {CONTRACT}else{0},"requiredClientContract":CONTRACT,
      "ownerUser":identity.user,"canFenceAccount":true,"canFindPendingSession":true,
      "canPrepare":true,"canStageAttachments":true,"canAcceptIntent":true,"canMaterialize":true,
      "canDispatchFirstMessage":true,"canRetryFirstMessage":true,"canRetireFirstMessageRetry":true,"canCancelCreation":true,"canStopBeforeAllocation":true,
      "attachmentRetentionDays":7,"canSubmit":compatible})
}
#[cfg(test)]
mod tests;
