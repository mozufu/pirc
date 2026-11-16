//! Request bodies and replies around the routes, reproducing what Fastify
//! did for the TS gateway (`apps/gateway/src/http.ts`): which bodies are
//! parsed as JSON, the body limit, and the shape of an unknown route.

use axum::body::{Body as AxumBody, Bytes};
use axum::extract::Request;
use axum::http::{Method, StatusCode, header};
use axum::response::{IntoResponse, Response};
use http_body_util::{BodyExt, Limited};
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::error::{ApiError, ApiResult, json_response};

/// The largest JSON body. Uploads are raw bytes and keep the configured
/// upload limit; JSON carries prompts (at most 1,000,000 UTF-16 units, so
/// about 3 MB of CJK text), answers and settings (security audit L8).
pub const JSON_BODY_MAX_BYTES: usize = 4 * 1024 * 1024;

/// A request body as the route sees it.
#[derive(Clone, Debug, Default)]
pub enum Body {
    /// No body (or a method whose body is ignored).
    #[default]
    None,
    /// `application/json`, parsed.
    Json(Value),
    /// Any other content type (or none), as raw bytes: uploads.
    Raw {
        bytes: Bytes,
        content_type: Option<String>,
    },
}

impl Body {
    /// The JSON body as `T`; anything else is `invalid_input`, as a failed
    /// zod schema was.
    pub fn parse<T: DeserializeOwned>(&self) -> ApiResult<T> {
        match self {
            Self::Json(value) => {
                serde_json::from_value(value.clone()).map_err(|_| ApiError::invalid_input())
            }
            _ => Err(ApiError::invalid_input()),
        }
    }

    /// The parsed JSON, if the body was JSON.
    pub fn json(&self) -> Option<&Value> {
        match self {
            Self::Json(value) => Some(value),
            _ => None,
        }
    }
}

/// The media type of a `content-type` value, lowercased, without parameters.
pub fn media_type(value: &str) -> String {
    value
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase()
}

/// `token` characters of RFC 9110.
fn is_token(text: &str) -> bool {
    !text.is_empty()
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
}

/// `type/subtype` (parameters aside), as Fastify requires before parsing.
fn valid_content_type(value: &str) -> bool {
    let media = value.split(';').next().unwrap_or_default().trim();
    media
        .split_once('/')
        .is_some_and(|(kind, subtype)| is_token(kind) && is_token(subtype))
}

/// `secure-json-parse` with Fastify's settings refuses prototype pollution:
/// a `__proto__` key, or a `constructor` key whose value has `prototype`.
fn polluting(value: &Value) -> bool {
    match value {
        Value::Array(items) => items.iter().any(polluting),
        Value::Object(object) => object.iter().any(|(key, item)| {
            key == "__proto__"
                || (key == "constructor" && item.get("prototype").is_some())
                || polluting(item)
        }),
        _ => false,
    }
}

/// Parse a JSON body like Fastify: a leading BOM is dropped; nothing, bad
/// JSON or prototype keys are an internal error, as they were.
pub(crate) fn parse_json(bytes: &[u8]) -> ApiResult<Value> {
    let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(bytes);
    if bytes.is_empty() {
        return Err(ApiError::internal());
    }
    let text = String::from_utf8_lossy(bytes);
    let value: Value = serde_json::from_str(&text).map_err(|_| ApiError::internal())?;
    if polluting(&value) {
        return Err(ApiError::internal());
    }
    Ok(value)
}

/// Read and parse a request body like Fastify 5: GET, HEAD and TRACE bodies
/// are ignored; without a content type, a body only counts when a length or
/// transfer encoding announces one; an invalid content type, or JSON that
/// does not parse (or is empty), is an internal error, as it was; more than
/// `limit` bytes (for JSON, [`JSON_BODY_MAX_BYTES`] if lower) is
/// `payload_too_large`.
pub async fn read_body(request: Request, limit: usize) -> ApiResult<Body> {
    let (parts, body) = request.into_parts();
    let headers = &parts.headers;
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .map(|value| String::from_utf8_lossy(value.as_bytes()).into_owned());
    let declared = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .map(str::trim);
    if matches!(parts.method, Method::GET | Method::HEAD | Method::TRACE) {
        return Ok(Body::None);
    }
    if content_type.is_none()
        && !headers.contains_key(header::TRANSFER_ENCODING)
        && matches!(declared, None | Some("0"))
    {
        return Ok(Body::None);
    }
    if content_type
        .as_deref()
        .is_some_and(|value| !valid_content_type(value))
    {
        return Err(ApiError::internal());
    }
    let json = content_type
        .as_deref()
        .is_some_and(|value| media_type(value) == "application/json");
    let limit = if json {
        limit.min(JSON_BODY_MAX_BYTES)
    } else {
        limit
    };
    if declared
        .and_then(|length| length.parse::<u64>().ok())
        .is_some_and(|length| length > limit as u64)
    {
        return Err(ApiError::payload_too_large());
    }
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
    if json {
        return parse_json(&bytes).map(Body::Json);
    }
    Ok(Body::Raw {
        bytes,
        content_type,
    })
}

/// Fastify's reply to a route it does not know (any method).
pub fn route_not_found(method: &Method, uri: &str) -> Response {
    json_response(
        404,
        &json!({
            "message": format!("Route {method}:{uri} not found"),
            "error": "Not Found",
            "statusCode": 404,
        }),
    )
}

/// A WebSocket route asked without an upgrade: an empty 404, as
/// `@fastify/websocket` answered.
pub fn websocket_required() -> Response {
    let mut response = AxumBody::empty().into_response();
    *response.status_mut() = StatusCode::NOT_FOUND;
    response
}

/// `204 No Content`.
pub fn no_content() -> Response {
    StatusCode::NO_CONTENT.into_response()
}

/// A JSON reply with status 200.
pub fn ok(body: Value) -> Response {
    json_response(200, &body)
}

#[cfg(test)]
mod tests {
    use axum::body::Body as AxumBody;
    use serde_json::json;

    use super::*;

    async fn read(
        method: &str,
        content_type: Option<&str>,
        body: &'static [u8],
        length: bool,
    ) -> ApiResult<Body> {
        let mut builder = axum::http::Request::builder().method(method).uri("/x");
        if let Some(content_type) = content_type {
            builder = builder.header("content-type", content_type);
        }
        if length {
            builder = builder.header("content-length", body.len().to_string());
        }
        read_body(builder.body(AxumBody::from(body)).unwrap(), 32).await
    }

    fn code(result: ApiResult<Body>) -> &'static str {
        result.err().map_or("ok", |error| error.code)
    }

    #[tokio::test]
    async fn json_bodies_have_a_lower_limit() {
        let big = |content_type: &str| {
            let mut body = b"\"".to_vec();
            body.resize(JSON_BODY_MAX_BYTES + 1, b'a');
            body.push(b'"');
            axum::http::Request::builder()
                .method("POST")
                .uri("/x")
                .header("content-type", content_type)
                .body(AxumBody::from(body))
                .unwrap()
        };
        let limit = 10 * 1024 * 1024;
        let result = read_body(big("application/json"), limit).await;
        assert_eq!(code(result), "payload_too_large");
        let result = read_body(big("application/octet-stream"), limit).await;
        assert!(matches!(result.unwrap(), Body::Raw { .. }));
    }

    #[tokio::test]
    async fn bodies() {
        let json = Some("application/json; charset=utf-8");
        assert_eq!(
            read("POST", json, br#"{"a":1}"#, true)
                .await
                .unwrap()
                .json(),
            Some(&json!({ "a": 1 }))
        );
        assert_eq!(
            read("POST", json, b"\xEF\xBB\xBF[]", true)
                .await
                .unwrap()
                .json(),
            Some(&json!([]))
        );
        assert_eq!(code(read("POST", json, b"{", true).await), "internal_error");
        assert_eq!(code(read("POST", json, b"", true).await), "internal_error");
        assert_eq!(
            code(read("POST", json, br#"{"__proto__":{}}"#, true).await),
            "internal_error"
        );
        assert_eq!(
            code(read("POST", json, br#"{"constructor":{"prototype":1}}"#, true).await),
            "internal_error"
        );
        assert_eq!(
            code(
                read(
                    "POST",
                    json,
                    br#"{"a":"0123456789abcdef0123456789abcdef"}"#,
                    true
                )
                .await
            ),
            "payload_too_large"
        );
        assert_eq!(
            code(
                read(
                    "POST",
                    json,
                    br#"{"a":"0123456789abcdef0123456789abcdef"}"#,
                    false
                )
                .await
            ),
            "payload_too_large"
        );
        assert_eq!(
            code(read("POST", Some("garbage"), b"", true).await),
            "internal_error"
        );
        assert_eq!(
            code(read("POST", Some(""), b"", false).await),
            "internal_error"
        );
        assert!(matches!(
            read("POST", Some("text/plain"), b"{}", true).await.unwrap(),
            Body::Raw { .. }
        ));
        assert!(matches!(
            read("POST", None, b"{}", true).await.unwrap(),
            Body::Raw {
                content_type: None,
                ..
            }
        ));
        assert!(matches!(
            read("POST", None, b"", true).await.unwrap(),
            Body::None
        ));
        assert!(matches!(
            read("GET", json, b"{", true).await.unwrap(),
            Body::None
        ));
        // Fastify 5 parses DELETE and OPTIONS bodies like POST ones.
        assert_eq!(
            code(read("DELETE", json, b"", false).await),
            "internal_error"
        );
        assert!(matches!(
            read("OPTIONS", None, b"xy", true).await.unwrap(),
            Body::Raw { .. }
        ));
    }
}
