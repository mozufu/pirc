//! What the gateway may answer with.
//!
//! Every reply is data for the app's own client: JSON, plain text (a node's
//! string body relayed as text) or a recording (`video/webm`). A reply is never
//! a document a browser would render or run. This layer is the single choke
//! point: it adds `X-Content-Type-Options: nosniff` (which browsers honour) and
//! replaces any reply declaring another content type with an internal error.

use axum::extract::Request;
use axum::http::{HeaderValue, header};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};

use crate::error::ApiError;

/// The media types the gateway answers with.
pub const ALLOWED_RESPONSE_TYPES: &[&str] = &["application/json", "text/plain", "video/webm"];

fn media_type(value: &HeaderValue) -> String {
    String::from_utf8_lossy(value.as_bytes())
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase()
}

fn allowed(response: &Response) -> bool {
    response
        .headers()
        .get_all(header::CONTENT_TYPE)
        .iter()
        .all(|value| ALLOWED_RESPONSE_TYPES.contains(&media_type(value).as_str()))
}

/// Outermost layer of the router.
pub async fn guard(request: Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    if !allowed(&response) {
        crate::log::error("a reply declared a content type outside the allowed list; replaced");
        response = ApiError::internal().into_response();
    }
    response.headers_mut().insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    response
}

#[cfg(test)]
mod tests;
