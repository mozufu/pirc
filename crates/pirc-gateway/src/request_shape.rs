//! The shape every state-changing API request must have.
//!
//! A request that changes state (any method other than `GET`, `HEAD` and
//! `OPTIONS`) must be something a plain HTML form cannot produce, whichever
//! identity it carries (forward auth or device token):
//!
//! - it carries the [`REQUEST_HEADER`] header with the value
//!   [`REQUEST_VALUE`] (exactly one such header), or
//! - it declares exactly one `Content-Type` whose media type is
//!   `application/json` (parameters such as `charset` are allowed) and its
//!   body is non-empty, valid JSON.
//!
//! The check runs in the authentication middleware, before routing, so a
//! route added later is covered without opting in. It is in addition to the
//! checks of [`crate::auth`] (proxy, secret, Host, Origin, identity, device
//! scope); it replaces none of them.

use axum::body::Body as AxumBody;
use axum::extract::Request;
use axum::http::{HeaderMap, header};
use http_body_util::{BodyExt, Limited};

use crate::error::{ApiError, ApiResult};
use crate::http::{JSON_BODY_MAX_BYTES, parse_json};

/// The request header clients send on every state-changing request.
pub const REQUEST_HEADER: &str = "x-pirc-request";
/// The only accepted value of [`REQUEST_HEADER`].
pub const REQUEST_VALUE: &str = "1";
/// The machine-readable error code of a request of the wrong shape.
pub const SHAPE_CODE: &str = "request_shape_required";

/// The text shown to a person. Clients built before the request shape was
/// required show it as it is, so it says what to do rather than what the
/// protocol expects.
pub const SHAPE_MESSAGE: &str =
    "This version of the app or page is out of date. Reload the page or update the app.";

fn shape_required() -> ApiError {
    ApiError::new(415, SHAPE_CODE, SHAPE_MESSAGE)
}

/// Requests with methods that never change state need no particular shape.
pub fn is_state_changing(method: &axum::http::Method) -> bool {
    crate::auth::requires_origin(method)
}

/// Exactly one marker header, with exactly the expected value.
fn has_marker(headers: &HeaderMap) -> bool {
    let mut values = headers.get_all(REQUEST_HEADER).iter();
    matches!(
        (values.next(), values.next()),
        (Some(value), None) if value.as_bytes() == REQUEST_VALUE.as_bytes()
    )
}

/// Exactly one `Content-Type` header whose media type is `application/json`.
fn declares_json(headers: &HeaderMap) -> bool {
    let mut values = headers.get_all(header::CONTENT_TYPE).iter();
    let (Some(value), None) = (values.next(), values.next()) else {
        return false;
    };
    value.to_str().is_ok_and(|value| {
        value
            .split(';')
            .next()
            .unwrap_or_default()
            .trim()
            .eq_ignore_ascii_case("application/json")
    })
}

/// Let a request of an acceptable shape through, handing back a request whose
/// body is intact. The body is read here only for the JSON form, and with the
/// limit the JSON routes already have.
pub async fn enforce(request: Request, body_limit: usize) -> ApiResult<Request> {
    if !is_state_changing(request.method()) || has_marker(request.headers()) {
        return Ok(request);
    }
    if !declares_json(request.headers()) {
        return Err(shape_required());
    }
    let limit = body_limit.min(JSON_BODY_MAX_BYTES);
    let declared = request
        .headers()
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.trim().parse::<u64>().ok());
    if declared.is_some_and(|length| length > limit as u64) {
        return Err(ApiError::payload_too_large());
    }
    let (parts, body) = request.into_parts();
    let bytes = Limited::new(body, limit)
        .collect()
        .await
        .map_err(|error| {
            if error.is::<http_body_util::LengthLimitError>() {
                ApiError::payload_too_large()
            } else {
                ApiError::internal()
            }
        })?
        .to_bytes();
    // A declared-JSON body must really be JSON; it never falls back to raw.
    parse_json(&bytes).map_err(|_| shape_required())?;
    Ok(Request::from_parts(parts, AxumBody::from(bytes)))
}

#[cfg(test)]
mod operations;
#[cfg(test)]
pub(crate) mod tests;
