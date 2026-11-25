//! At-most-once delivery into a Node session for pots: a request that never
//! left the Gateway, or that the Node answered with an error, did not run; one
//! lost after it left (timeout, link loss) may have run, so it is uncertain and
//! never sent again.

use pirc_protocol::{HttpMethod, NodeHttpRequest};
use serde_json::Value;

use crate::app::App;
use crate::db::Session;
use crate::routes::urlencoding_component;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Sent {
    Delivered,
    /// It did not run: the reason.
    Refused(String),
    /// It may have run: the reason it is unknown.
    Uncertain(String),
}

pub async fn send(app: &App, session: &Session, user: &str, message: Value) -> Sent {
    if let Err(error) = app.require_writable(session) {
        return Sent::Refused(error.message);
    }
    let (Some(node_id), Some(remote)) = (&session.node_id, &session.pi_session_id) else {
        return Sent::Refused("The session has no node".into());
    };
    let request = NodeHttpRequest {
        method: HttpMethod::Post,
        url: format!("/api/sessions/{}/deliver", urlencoding_component(remote)),
        user: user.to_owned(),
        payload: Some(message),
        body_base64: None,
        content_type: None,
    };
    match app.nodes.request(node_id, request).await {
        Ok(response) if response.status < 400 => Sent::Delivered,
        Ok(response) => Sent::Refused(
            response
                .body
                .as_ref()
                .and_then(|body| body["error"]["message"].as_str())
                .map(str::to_owned)
                .unwrap_or_else(|| format!("{node_id} answered {}", response.status)),
        ),
        Err(error) if error.is_not_sent() => Sent::Refused(error.message),
        Err(error) => Sent::Uncertain(error.message),
    }
}
