//! The error shape every client reads, `{error:{code,message,details?}}`
//! (`apps/gateway/src/errors.ts`, `http.ts`).

use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde_json::{Value, json};

/// `content-type` of every JSON reply, as Fastify sends it.
pub const JSON_CONTENT_TYPE: &str = "application/json; charset=utf-8";

/// An error with its HTTP status and machine-readable code. The message is
/// shown to users: it never carries secrets or upstream bodies.
#[derive(Clone, Debug, PartialEq)]
pub struct ApiError {
    pub status: u16,
    pub code: &'static str,
    pub message: String,
    pub details: Option<Value>,
    /// Set only by the Node link layer, and only when the relayed request
    /// provably never entered the link's send queue (see [`ApiError::unsent`]).
    /// Never serialized; never inferred from `code`, which several unrelated
    /// failures share.
    not_sent: bool,
}

impl ApiError {
    pub fn new(status: u16, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
            details: None,
            not_sent: false,
        }
    }

    /// Mark a Node-link failure that happened before the request was queued
    /// on the link, so no copy of it can ever reach the Node.
    pub(crate) fn unsent(mut self) -> Self {
        self.not_sent = true;
        self
    }

    /// True only for a failure marked with [`ApiError::unsent`].
    pub(crate) fn is_not_sent(&self) -> bool {
        self.not_sent
    }

    pub fn with_details(mut self, details: Value) -> Self {
        self.details = Some(details);
        self
    }

    /// Request input that does not match its schema.
    pub fn invalid_input() -> Self {
        Self::new(400, "invalid_input", "Invalid request")
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(404, "not_found", message)
    }

    pub fn payload_too_large() -> Self {
        Self::new(
            413,
            "payload_too_large",
            "Request body exceeds configured limit",
        )
    }

    /// Anything unexpected: logged by the caller, never shown.
    pub fn internal() -> Self {
        Self::new(500, "internal_error", "Internal server error")
    }

    pub fn body(&self) -> Value {
        let mut error = json!({ "code": self.code, "message": self.message });
        if let Some(details) = &self.details {
            error["details"] = details.clone();
        }
        json!({ "error": error })
    }
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} {}: {}", self.status, self.code, self.message)
    }
}

impl std::error::Error for ApiError {}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        json_response(self.status, &self.body())
    }
}

/// A JSON reply with Fastify's `content-type`.
pub fn json_response(status: u16, body: &Value) -> Response {
    let mut response = body.to_string().into_response();
    *response.status_mut() = StatusCode::from_u16(status).unwrap_or(StatusCode::OK);
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(JSON_CONTENT_TYPE),
    );
    response
}

pub type ApiResult<T> = Result<T, ApiError>;
