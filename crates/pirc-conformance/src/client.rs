//! HTTP and WebSocket clients that send exactly the headers a test gives,
//! including `Host`, as a reverse proxy would.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::{self, Message};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

/// The header the Gateway requires on every state-changing request.
pub const REQUEST_HEADER: &str = "x-pirc-request";

/// How long a test waits for any single response, frame or close.
pub const TIMEOUT: Duration = Duration::from_secs(20);

/// A reply: its status, its contract headers and its body as JSON (`null`
/// when empty, a string when not JSON). The contract headers are
/// `cache-control` and the media type of `content-type`; its parameters
/// (`charset`) are framework details.
#[derive(Clone, Debug)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Value,
}

impl Response {
    fn new(status: u16, headers: &tungstenite::http::HeaderMap, bytes: &[u8]) -> Self {
        let header = |name: &str| headers.get(name).and_then(|value| value.to_str().ok());
        let mut recorded = Vec::new();
        if let Some(value) = header("cache-control") {
            recorded.push(("cache-control".to_owned(), value.to_owned()));
        }
        if let Some(value) = header("content-type") {
            let media_type = value.split(';').next().unwrap_or_default().trim();
            recorded.push(("content-type".to_owned(), media_type.to_owned()));
        }
        let headers = recorded;
        let body = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(bytes)
                .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(bytes).into_owned()))
        };
        Self {
            status,
            headers,
            body,
        }
    }
}

#[derive(Clone)]
pub struct Api {
    base: String,
    http: reqwest::Client,
}

impl Api {
    pub fn new(base: String) -> Self {
        let http = reqwest::Client::builder()
            .no_proxy()
            .timeout(TIMEOUT)
            .build()
            .expect("HTTP client");
        Self { base, http }
    }

    /// Send a request; panics on a transport error.
    pub async fn send(
        &self,
        method: &str,
        path: &str,
        headers: &[(&str, String)],
        body: Option<Value>,
    ) -> Response {
        self.try_send(method, path, headers, body)
            .await
            .unwrap_or_else(|error| panic!("{method} {path}: {error}"))
    }

    pub async fn try_send(
        &self,
        method: &str,
        path: &str,
        headers: &[(&str, String)],
        body: Option<Value>,
    ) -> Result<Response, reqwest::Error> {
        let body = body.map(|body| (Some("application/json"), body.to_string().into_bytes()));
        self.try_send_bytes(method, path, headers, body).await
    }

    /// Send raw bytes with the given `content-type` (none when `None`).
    pub async fn send_bytes(
        &self,
        method: &str,
        path: &str,
        headers: &[(&str, String)],
        content_type: Option<&str>,
        body: Vec<u8>,
    ) -> Response {
        self.try_send_bytes(method, path, headers, Some((content_type, body)))
            .await
            .unwrap_or_else(|error| panic!("{method} {path}: {error}"))
    }

    async fn try_send_bytes(
        &self,
        method: &str,
        path: &str,
        headers: &[(&str, String)],
        body: Option<(Option<&str>, Vec<u8>)>,
    ) -> Result<Response, reqwest::Error> {
        let method = reqwest::Method::from_bytes(method.as_bytes()).expect("HTTP method");
        let mut request = self
            .http
            .request(method.clone(), format!("{}{path}", self.base));
        for (name, value) in headers {
            request = request.header(*name, value);
        }
        // State-changing requests carry the request header the Gateway requires
        // of API clients, unless the test sets it itself.
        if !matches!(
            method,
            reqwest::Method::GET | reqwest::Method::HEAD | reqwest::Method::OPTIONS
        ) && !headers
            .iter()
            .any(|(name, _)| name.eq_ignore_ascii_case(REQUEST_HEADER))
        {
            request = request.header(REQUEST_HEADER, "1");
        }
        if let Some((content_type, body)) = body {
            if let Some(content_type) = content_type {
                request = request.header("content-type", content_type);
            }
            request = request.body(body);
        }
        let response = request.send().await?;
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let bytes = response.bytes().await?;
        Ok(Response::new(status, &headers, &bytes))
    }

    /// Open a WebSocket at `path` (relative to the base URL).
    pub async fn connect(&self, path: &str, headers: &[(&str, String)]) -> Connection {
        let url = format!("{}{path}", self.base.replacen("http", "ws", 1));
        let mut request = url.into_client_request().expect("WebSocket request");
        for (name, value) in headers {
            request.headers_mut().insert(
                tungstenite::http::HeaderName::from_bytes(name.as_bytes()).unwrap(),
                HeaderValue::from_str(value).unwrap(),
            );
        }
        match tokio::time::timeout(TIMEOUT, tokio_tungstenite::connect_async(request)).await {
            Err(_) => panic!("WebSocket {path}: handshake timed out"),
            Ok(Ok((stream, _))) => Connection::Open(Box::new(WebSocket { stream })),
            Ok(Err(tungstenite::Error::Http(response))) => {
                let status = response.status().as_u16();
                let headers = response.headers().clone();
                let body = response.into_body().unwrap_or_default();
                Connection::Refused(Response::new(status, &headers, &body))
            }
            Ok(Err(error)) => panic!("WebSocket {path}: {error}"),
        }
    }
}

/// The outcome of a WebSocket handshake.
pub enum Connection {
    Open(Box<WebSocket>),
    /// The upgrade was answered with an HTTP error.
    Refused(Response),
}

impl Connection {
    pub fn open(self) -> WebSocket {
        match self {
            Self::Open(socket) => *socket,
            Self::Refused(response) => panic!(
                "WebSocket refused with {}: {}",
                response.status, response.body
            ),
        }
    }
}

pub struct WebSocket {
    stream: WebSocketStream<MaybeTlsStream<TcpStream>>,
}

impl WebSocket {
    pub async fn send_json(&mut self, value: &Value) {
        self.stream
            .send(Message::text(value.to_string()))
            .await
            .expect("WebSocket send");
    }

    /// Wait for the server to enter its receive loop. Return preceding JSON
    /// frames so callers can preserve them when their scenario needs them.
    pub async fn ping(&mut self) -> Vec<Value> {
        self.stream
            .send(Message::Ping(Vec::new().into()))
            .await
            .unwrap();
        let mut frames = Vec::new();
        tokio::time::timeout(TIMEOUT, async {
            loop {
                match self.stream.next().await {
                    Some(Ok(Message::Pong(_))) => return frames,
                    Some(Ok(Message::Text(text))) => {
                        frames.push(serde_json::from_str(&text).expect("JSON frame"));
                    }
                    Some(Ok(Message::Ping(_))) => {}
                    other => panic!("socket ended before pong: {other:?}"),
                }
            }
        })
        .await
        .expect("timed out waiting for a WebSocket pong")
    }

    /// The next JSON text frame, or `Err` with the close frame (code, reason)
    /// once the peer closes.
    pub async fn next_json(&mut self) -> Result<Value, (u16, String)> {
        loop {
            let message = tokio::time::timeout(TIMEOUT, self.stream.next())
                .await
                .expect("timed out waiting for a WebSocket frame");
            match message {
                Some(Ok(Message::Text(text))) => {
                    return Ok(serde_json::from_str(&text).expect("JSON frame"));
                }
                Some(Ok(Message::Close(frame))) => return Err(close_of(frame)),
                Some(Ok(_)) => continue,
                Some(Err(error)) => panic!("WebSocket error: {error}"),
                None => return Err((1006, String::new())),
            }
        }
    }

    /// Read frames until one satisfies `done`; returns all of them, in order.
    pub async fn until(&mut self, mut done: impl FnMut(&Value) -> bool) -> Vec<Value> {
        let mut frames = Vec::new();
        loop {
            match self.next_json().await {
                Ok(frame) => {
                    let stop = done(&frame);
                    frames.push(frame);
                    if stop {
                        return frames;
                    }
                }
                Err(close) => panic!("socket closed early with {close:?} after {frames:?}"),
            }
        }
    }

    /// Skip frames until the peer closes; returns the close code and reason.
    pub async fn closed(&mut self) -> (u16, String) {
        loop {
            if let Err(close) = self.next_json().await {
                return close;
            }
        }
    }

    pub async fn close(mut self) {
        let _ = self.stream.close(None).await;
    }
}

fn close_of(frame: Option<CloseFrame>) -> (u16, String) {
    frame.map_or((1005, String::new()), |frame| {
        (u16::from(frame.code), frame.reason.to_string())
    })
}
