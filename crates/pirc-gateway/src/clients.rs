//! Client names (plans/roadmap.md M4 step 12): the clients of an account that
//! took control of a session, so other clients can say who holds it
//! ("Controlled by Pixel 9", "Controlled by Chrome on macOS").
//!
//! A client is known by the `clientId` it sends with the control lease. A
//! paired device is named by its device record (renamed with
//! `PATCH /api/device`); a browser by the `clientName` it sends, else by a name
//! read from its user agent, and renamed with `PUT /api/clients/{clientId}`.

use axum::Router;
use axum::extract::{Extension, Path, State};
use axum::http::HeaderMap;
use axum::routing::get;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::app::{AppState, ReqBody};
use crate::auth::Identity;
use crate::error::{ApiError, ApiResult};
use crate::util::now_ms;

pub const MAX_NAME: usize = 60;
const LISTED: i64 = 100;

fn invalid(message: &str) -> ApiError {
    ApiError::new(400, "invalid_input", message)
}

/// A name a person typed: trimmed, 1 to 60 characters, no control characters.
pub fn checked_name(name: &str) -> ApiResult<String> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > MAX_NAME || name.chars().any(char::is_control) {
        return Err(invalid("A name is 1 to 60 characters"));
    }
    Ok(name.to_owned())
}

/// "Chrome on macOS" from a user agent; `None` when it says nothing useful.
pub fn browser_name(user_agent: &str) -> Option<String> {
    let ua = user_agent;
    let browser = if ua.contains("Edg/") {
        "Edge"
    } else if ua.contains("OPR/") || ua.contains("Opera") {
        "Opera"
    } else if ua.contains("Firefox/") || ua.contains("FxiOS/") {
        "Firefox"
    } else if ua.contains("Chrome/") || ua.contains("CriOS/") {
        "Chrome"
    } else if ua.contains("Safari/") {
        "Safari"
    } else {
        return None;
    };
    let system = if ua.contains("iPhone") || ua.contains("iPad") || ua.contains("iPod") {
        Some("iOS")
    } else if ua.contains("Android") {
        Some("Android")
    } else if ua.contains("Windows") {
        Some("Windows")
    } else if ua.contains("Mac OS X") || ua.contains("Macintosh") {
        Some("macOS")
    } else if ua.contains("CrOS") {
        Some("ChromeOS")
    } else if ua.contains("Linux") {
        Some("Linux")
    } else {
        None
    };
    Some(match system {
        Some(system) => format!("{browser} on {system}"),
        None => browser.to_owned(),
    })
}

/// Remember a client that acquired or kept control. A browser's name is the
/// one it sent, else the one it had, else one from its user agent.
pub fn record(
    conn: &Connection,
    identity: &Identity,
    client_id: &str,
    client_name: Option<&str>,
    headers: &HeaderMap,
) -> ApiResult<()> {
    let user_agent = headers
        .get(axum::http::header::USER_AGENT)
        .and_then(|value| value.to_str().ok())
        .map(|ua| ua.chars().take(300).collect::<String>());
    let sent = client_name.map(checked_name).transpose()?;
    conn.execute(
        "INSERT INTO clients(owner_user,client_id,device_id,name,user_agent,last_seen_at)
         VALUES(?1,?2,?3,?4,?5,?6)
         ON CONFLICT(owner_user,client_id) DO UPDATE SET device_id=excluded.device_id,
           name=COALESCE(excluded.name, clients.name), user_agent=excluded.user_agent,
           last_seen_at=excluded.last_seen_at",
        params![
            identity.user,
            client_id,
            identity.device_id,
            sent,
            user_agent,
            now_ms()
        ],
    )?;
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Client {
    pub client_id: String,
    pub name: String,
    /// `device` (a paired app) or `browser`.
    pub kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    pub last_seen_at: i64,
}

type ClientRow = (
    String,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    i64,
);

const SELECT: &str = "SELECT c.client_id, c.device_id, d.name, c.name, c.user_agent, c.last_seen_at
  FROM clients c LEFT JOIN device_tokens d ON d.id=c.device_id AND d.owner_user=c.owner_user";

fn client(row: ClientRow) -> Client {
    let (client_id, device_id, device_name, name, user_agent, last_seen_at) = row;
    let (kind, name) = match (&device_id, device_name) {
        (Some(_), Some(device)) => ("device", device),
        (Some(_), None) => ("device", "A removed device".to_owned()),
        (None, _) => (
            "browser",
            name.or_else(|| user_agent.as_deref().and_then(browser_name))
                .unwrap_or_else(|| "A browser".to_owned()),
        ),
    };
    Client {
        client_id,
        name,
        kind,
        device_id,
        last_seen_at,
    }
}

fn client_row(r: &rusqlite::Row) -> rusqlite::Result<ClientRow> {
    Ok((
        r.get(0)?,
        r.get(1)?,
        r.get(2)?,
        r.get(3)?,
        r.get(4)?,
        r.get(5)?,
    ))
}

/// One of the owner's clients by its `clientId`.
pub fn find(conn: &Connection, owner: &str, client_id: &str) -> ApiResult<Option<Client>> {
    Ok(conn
        .query_row(
            &format!("{SELECT} WHERE c.owner_user=?1 AND c.client_id=?2"),
            params![owner, client_id],
            client_row,
        )
        .optional()?
        .map(client))
}

/// The owner's clients, most recently seen first.
pub fn list(conn: &Connection, owner: &str) -> ApiResult<Vec<Client>> {
    let rows: Vec<ClientRow> = conn
        .prepare(&format!(
            "{SELECT} WHERE c.owner_user=?1 ORDER BY c.last_seen_at DESC LIMIT ?2"
        ))?
        .query_map(params![owner, LISTED], client_row)?
        .collect::<Result<_, _>>()?;
    Ok(rows.into_iter().map(client).collect())
}

/// A client sent a command or an answer in a session: what "the holder acted
/// recently" means when another device is about to send.
pub fn note_action(conn: &Connection, session_id: &str, client_id: &str) -> ApiResult<()> {
    conn.execute(
        "INSERT INTO session_actions(session_id,client_id,at) VALUES(?1,?2,?3)
         ON CONFLICT(session_id,client_id) DO UPDATE SET at=excluded.at",
        params![session_id, client_id, now_ms()],
    )?;
    Ok(())
}

/// The lease's holder, for `GET …/control`: its name, kind and when it last
/// sent something in this session.
pub fn holder(conn: &Connection, owner: &str, session_id: &str, lease: &Value) -> ApiResult<Value> {
    let Some(client_id) = lease["clientId"].as_str() else {
        return Ok(Value::Null);
    };
    let last_action: Option<i64> = conn
        .query_row(
            "SELECT at FROM session_actions WHERE session_id=?1 AND client_id=?2",
            params![session_id, client_id],
            |r| r.get(0),
        )
        .optional()?;
    Ok(match find(conn, owner, client_id)? {
        Some(client) => {
            json!({ "name": client.name, "kind": client.kind, "lastActionAt": last_action })
        }
        None if last_action.is_some() => json!({ "lastActionAt": last_action }),
        None => Value::Null,
    })
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/clients", get(list_clients))
        .route("/api/clients/{id}", axum::routing::put(rename_client))
        .route("/api/device", get(read_device).patch(rename_device))
        .route("/api/device/rotate", axum::routing::post(rotate_device))
}

async fn list_clients(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> ApiResult<axum::Json<Value>> {
    let clients = list(&app.db.lock(), &identity.user)?;
    Ok(axum::Json(json!({ "clients": clients })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NewName {
    name: String,
}

/// Rename a browser client. A paired device is renamed as a device.
async fn rename_client(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    let NewName { name } = body.parse()?;
    let name = checked_name(&name)?;
    let conn = app.db.lock();
    let found =
        find(&conn, &identity.user, &id)?.ok_or_else(|| ApiError::not_found("Client not found"))?;
    if found.kind == "device" {
        return Err(invalid("A paired device is renamed with PATCH /api/device"));
    }
    conn.execute(
        "UPDATE clients SET name=?3 WHERE owner_user=?1 AND client_id=?2",
        params![identity.user, id, name],
    )?;
    let client =
        find(&conn, &identity.user, &id)?.ok_or_else(|| ApiError::not_found("Client not found"))?;
    Ok(axum::Json(json!({ "client": client })))
}

fn this_device(identity: &Identity) -> ApiResult<&str> {
    identity
        .device_id
        .as_deref()
        .ok_or_else(|| invalid("Only a paired device has a device record"))
}

/// The device record; `expiresAt` is the maximum window and `idleExpiresAt`
/// when the token dies if it is not used again (the earlier of the two wins).
pub(crate) fn device_json(
    conn: &Connection,
    owner: &str,
    id: &str,
    windows: &crate::devices::DeviceTokens,
) -> ApiResult<Value> {
    conn.query_row(
        "SELECT id,name,created_at,expires_at,last_used_at FROM device_tokens WHERE id=?1 AND owner_user=?2",
        params![id, owner],
        |r| {
            let last_used_at = r.get::<_, i64>(4)?;
            Ok(json!({
                "id": r.get::<_, String>(0)?, "name": r.get::<_, String>(1)?,
                "createdAt": r.get::<_, i64>(2)?, "expiresAt": r.get::<_, i64>(3)?,
                "lastUsedAt": last_used_at,
                "idleExpiresAt": last_used_at.saturating_add(windows.idle_ms()),
                // The length of the maximum window, so the app knows when to
                // rotate whatever the Gateway's PIRC_DEVICE_TOKEN_MAX_DAYS.
                "maxAgeMs": windows.max_age_ms(),
            }))
        },
    )
    .optional()?
    .ok_or_else(|| ApiError::not_found("Device not found"))
}

/// The calling paired device's own record.
async fn read_device(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> ApiResult<axum::Json<Value>> {
    let id = this_device(&identity)?;
    Ok(axum::Json(
        json!({ "device": device_json(&app.db.lock(), &identity.user, id, &app.devices)? }),
    ))
}

/// A paired device swaps its token for a new one with new idle and maximum
/// windows (plans/roadmap.md M8 default B). Only a device token may ask; a
/// management grant is neither added nor extended.
async fn rotate_device(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    headers: HeaderMap,
    ReqBody(_): ReqBody,
) -> ApiResult<axum::response::Response> {
    let Some(id) = identity.device_id.as_deref() else {
        return Err(ApiError::new(
            403,
            "forbidden",
            "Only a paired device can rotate its token",
        ));
    };
    let presented = crate::auth::device_token(&headers).ok_or_else(|| {
        ApiError::new(401, "unauthenticated", "Device authentication is required")
    })?;
    let (_, token) = app.devices.rotate(&identity.user, id, &presented)?;
    let device = device_json(&app.db.lock(), &identity.user, id, &app.devices)?;
    Ok(crate::error::json_response(
        200,
        &json!({ "device": device, "token": token }),
    ))
}

/// A paired device renames itself; its name shows in the devices list and
/// wherever it holds control.
async fn rename_device(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    let id = this_device(&identity)?;
    let NewName { name } = body.parse()?;
    let name = checked_name(&name)?;
    let conn = app.db.lock();
    conn.execute(
        "UPDATE device_tokens SET name=?3 WHERE id=?1 AND owner_user=?2",
        params![id, identity.user, name],
    )?;
    Ok(axum::Json(
        json!({ "device": device_json(&conn, &identity.user, id, &app.devices)? }),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{app_with_models, call};

    fn browser(user: &str) -> Identity {
        Identity {
            user: user.into(),
            device_id: None,
            management_authorized: false,
        }
    }

    fn agent(ua: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(axum::http::header::USER_AGENT, ua.parse().unwrap());
        headers
    }

    const MAC_CHROME: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";

    #[test]
    fn a_user_agent_names_the_browser_and_system() {
        assert_eq!(browser_name(MAC_CHROME).as_deref(), Some("Chrome on macOS"));
        let iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
        assert_eq!(browser_name(iphone).as_deref(), Some("Safari on iOS"));
        let edge = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0";
        assert_eq!(browser_name(edge).as_deref(), Some("Edge on Windows"));
        let firefox = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0";
        assert_eq!(browser_name(firefox).as_deref(), Some("Firefox on Linux"));
        assert_eq!(browser_name("curl/8.0"), None);
    }

    #[tokio::test]
    async fn holders_are_named_by_device_record_sent_name_or_user_agent() {
        let (app, _dir) = app_with_models(json!({}));
        let (device, token) = app.devices.create("alice", "Pixel 9").unwrap();
        {
            let conn = app.db.lock();
            // A browser that sent nothing is named from its user agent.
            record(&conn, &browser("alice"), "web-1", None, &agent(MAC_CHROME)).unwrap();
            let lease = json!({ "clientId": "web-1" });
            assert_eq!(
                holder(&conn, "alice", "s", &lease).unwrap(),
                json!({ "name": "Chrome on macOS", "kind": "browser", "lastActionAt": null })
            );
            // The name it sends wins, and stays when a later call sends none.
            record(
                &conn,
                &browser("alice"),
                "web-1",
                Some(" Office iMac "),
                &agent(MAC_CHROME),
            )
            .unwrap();
            record(&conn, &browser("alice"), "web-1", None, &agent(MAC_CHROME)).unwrap();
            assert_eq!(
                holder(&conn, "alice", "s", &lease).unwrap()["name"],
                "Office iMac"
            );
            assert!(
                record(
                    &conn,
                    &browser("alice"),
                    "web-1",
                    Some("   "),
                    &HeaderMap::new()
                )
                .is_err()
            );
            // A paired device is named by its record.
            let phone = Identity {
                user: "alice".into(),
                device_id: Some(device.id.clone()),
                management_authorized: false,
            };
            record(
                &conn,
                &phone,
                "app-1",
                Some("ignored for devices"),
                &HeaderMap::new(),
            )
            .unwrap();
            assert_eq!(
                holder(&conn, "alice", "s", &json!({ "clientId": "app-1" })).unwrap(),
                json!({ "name": "Pixel 9", "kind": "device", "lastActionAt": null })
            );
            // Another owner knows neither.
            assert_eq!(holder(&conn, "bob", "s", &lease).unwrap(), Value::Null);
        }
        // The device renames itself; the holder name follows.
        let (status, renamed) = call(
            &app,
            "PATCH",
            "/api/device",
            None,
            Some(&token),
            Some(json!({ "name": "Brian's phone" })),
        )
        .await;
        assert_eq!(status, 200, "{renamed}");
        assert_eq!(renamed["device"]["name"], "Brian's phone");
        let (_, read) = call(&app, "GET", "/api/device", None, Some(&token), None).await;
        assert_eq!(read["device"]["id"], device.id.as_str());
        assert_eq!(
            read["device"]["maxAgeMs"],
            30 * 86_400_000_i64,
            "the default window"
        );
        let (_, listed) = call(&app, "GET", "/api/clients", None, Some(&token), None).await;
        let names: Vec<&str> = listed["clients"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["name"].as_str().unwrap())
            .collect();
        assert!(
            names.contains(&"Brian's phone") && names.contains(&"Office iMac"),
            "{listed}"
        );
        // A browser has no device record; a device is not renamed as a client.
        assert_eq!(
            call(&app, "GET", "/api/device", Some("alice"), None, None)
                .await
                .0,
            400
        );
        assert_eq!(
            call(
                &app,
                "PUT",
                "/api/clients/app-1",
                Some("alice"),
                None,
                Some(json!({ "name": "x" }))
            )
            .await
            .0,
            400
        );
        let (status, web) = call(
            &app,
            "PUT",
            "/api/clients/web-1",
            Some("alice"),
            None,
            Some(json!({ "name": "Kitchen laptop" })),
        )
        .await;
        assert_eq!(
            (status, web["client"]["name"].as_str()),
            (200, Some("Kitchen laptop"))
        );
        assert_eq!(
            call(
                &app,
                "PUT",
                "/api/clients/web-1",
                Some("bob"),
                None,
                Some(json!({ "name": "x" }))
            )
            .await
            .0,
            404
        );
    }
}

#[cfg(test)]
mod rotation_tests {
    use super::*;
    use crate::test_support::{app_with_models, call};

    #[tokio::test]
    async fn a_device_rotates_its_own_token_and_gains_no_management_access() {
        let (app, _dir) = app_with_models(json!({}));
        let (device, old) = app.devices.create("alice", "Pixel 9").unwrap();
        // A management grant and a push target from before the rotation.
        let verifier = "v".repeat(43);
        let grant = app
            .management
            .create(
                "alice",
                &device.id,
                &crate::util::sha256_hex(&verifier),
                vec![crate::management::ManagementCapability::DevicesRead],
                false,
            )
            .unwrap();
        app.management
            .decide("alice", None, &grant.request.id, true)
            .unwrap();
        let granted = app
            .management
            .claim("alice", &device.id, &grant.request.id, &verifier)
            .unwrap();
        app.db
            .lock()
            .execute(
                "INSERT INTO push_subscriptions (id,owner_user,endpoint,p256dh,auth,kind,device_id,created_at)
                 VALUES ('push_1','alice','https://p.example/x','k','a','unifiedpush',?1,0)",
                [&device.id],
            )
            .unwrap();
        let (status, read) = call(&app, "GET", "/api/device", None, Some(&old), None).await;
        assert_eq!(status, 200);
        assert_eq!(
            read["device"]["idleExpiresAt"].as_i64().unwrap()
                - read["device"]["lastUsedAt"].as_i64().unwrap(),
            app.devices.idle_ms()
        );
        let (status, _) = call(
            &app,
            "POST",
            "/api/device/rotate",
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!(status, 403, "a browser has no device token");

        use tower::ServiceExt;
        let request = axum::http::Request::builder()
            .method("POST")
            .uri("/api/device/rotate")
            .header("host", "a.example")
            .header(crate::capabilities::HEADER, "test/2")
            .header(
                crate::request_shape::REQUEST_HEADER,
                crate::request_shape::REQUEST_VALUE,
            )
            .header("authorization", format!("Bearer {old}"))
            .extension(axum::extract::ConnectInfo(
                "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
            ))
            .body(axum::body::Body::empty())
            .unwrap();
        let response = crate::app::router(app.clone())
            .oneshot(request)
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        assert_eq!(response.headers()["cache-control"], "no-store");
        let body: Value = serde_json::from_slice(
            &axum::body::to_bytes(response.into_body(), 1 << 20)
                .await
                .unwrap(),
        )
        .unwrap();
        let new = body["token"].as_str().unwrap().to_owned();
        assert_eq!(body["device"]["id"], device.id.as_str());
        assert_eq!(body["device"]["name"], "Pixel 9");

        // The old token works until the new one is used, then never again.
        assert_eq!(
            call(&app, "GET", "/api/device", None, Some(&old), None)
                .await
                .0,
            200
        );
        assert_eq!(
            call(&app, "GET", "/api/device", None, Some(&new), None)
                .await
                .0,
            200
        );
        assert_eq!(
            call(&app, "GET", "/api/device", None, Some(&old), None)
                .await
                .0,
            401
        );
        // Still a device token: device management stays closed without a grant.
        assert_eq!(
            call(&app, "GET", "/api/devices", None, Some(&new), None)
                .await
                .0,
            403
        );
        // The grant from before is neither extended nor widened.
        let view = app
            .management
            .view("alice", None, &grant.request.id)
            .unwrap();
        assert_eq!(view.expires_at, granted.expires_at);
        assert_eq!(
            view.capabilities,
            vec![crate::management::ManagementCapability::DevicesRead]
        );
        // The push target stays with the device.
        let targets: Vec<String> = app
            .db
            .lock()
            .prepare("SELECT id FROM push_subscriptions WHERE device_id=?1")
            .unwrap()
            .query_map([&device.id], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(targets, ["push_1"]);
    }
}

#[cfg(test)]
mod control_tests {
    use super::*;
    use crate::db::Store;
    use crate::test_support::{app_with_models, call};

    #[tokio::test]
    async fn the_control_read_names_the_holder() {
        let (app, _dir) = app_with_models(json!({}));
        let session = {
            let conn = app.db.lock();
            conn.sync_remote_workspaces(
                "node",
                &[(
                    "repo".into(),
                    "Repo".into(),
                    pirc_protocol::ModeId::new("directory").unwrap(),
                )],
            )
            .unwrap();
            let session = conn
                .create_session("node:repo", "node://node/r1", "node", "r1", "alice")
                .unwrap()
                .id;
            conn.execute(
                "INSERT INTO leases(session_id,client_id,generation,expires_at,updated_at,owner_user)
                 VALUES(?1,'web-1',1,?2,0,'alice')",
                params![session, now_ms() + 60_000],
            )
            .unwrap();
            let me = Identity {
                user: "alice".into(),
                device_id: None,
                management_authorized: false,
            };
            record(&conn, &me, "web-1", Some("Office iMac"), &HeaderMap::new()).unwrap();
            session
        };
        let (status, control) = call(
            &app,
            "GET",
            &format!("/api/sessions/{session}/control"),
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!(status, 200, "{control}");
        assert_eq!(
            control["lease"]["holder"],
            json!({ "name": "Office iMac", "kind": "browser", "lastActionAt": null })
        );
        // Once it sends something, the read says when.
        note_action(&app.db.lock(), &session, "web-1").unwrap();
        let (_, control) = call(
            &app,
            "GET",
            &format!("/api/sessions/{session}/control"),
            Some("alice"),
            None,
            None,
        )
        .await;
        assert!(control["lease"]["holder"]["lastActionAt"].as_i64().unwrap() > now_ms() - 5_000);
    }

    #[tokio::test]
    async fn taking_control_tells_every_device_who_holds_it() {
        let (app, _dir) = app_with_models(json!({}));
        let session = {
            let conn = app.db.lock();
            conn.sync_remote_workspaces(
                "node",
                &[(
                    "repo".into(),
                    "Repo".into(),
                    pirc_protocol::ModeId::new("directory").unwrap(),
                )],
            )
            .unwrap();
            conn.create_session("node:repo", "node://node/r1", "node", "r1", "alice")
                .unwrap()
                .id
        };
        let node = crate::nodes::ConnectedNode {
            id: "node".into(),
            role: pirc_protocol::NodeRole::Node,
            modes: vec![pirc_protocol::ModeId::new("directory").unwrap()],
            workspaces: vec![pirc_protocol::RegisteredWorkspace {
                checkpoint_private: false,
                id: "repo".into(),
                display_name: "Repo".into(),
                mode: pirc_protocol::ModeId::new("directory").unwrap(),
                roles: None,
                repo: None,
            }],
            connected_at: now_ms(),
            last_seen_at: now_ms(),
            added: Default::default(),
        };
        app.nodes.set_test_node(node, |request| {
            let body = match request.url.as_str() {
                url if url.ends_with("/control/acquire") => json!({ "lease": {
                        "clientId": request.payload.as_ref().unwrap()["clientId"],
                        "generation": 1, "expiresAt": now_ms() + 60_000 } }),
                _ => json!({}),
            };
            Ok(pirc_protocol::NodeHttpResponse {
                status: 200,
                body: Some(body),
            })
        });
        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = seen.clone();
        let _listening = app.events.subscribe_all(std::sync::Arc::new(move |event| {
            if event.kind == "control_changed" {
                sink.lock().unwrap().push(event.data.clone().unwrap());
            }
        }));
        let (status, acquired) = call(
            &app,
            "POST",
            &format!("/api/sessions/{session}/control/acquire"),
            Some("alice"),
            None,
            Some(json!({ "clientId": "web-1", "clientName": "Office iMac" })),
        )
        .await;
        assert_eq!(status, 200, "{acquired}");
        assert_eq!(
            acquired["lease"].get("clientName"),
            None,
            "the name stays in the Gateway"
        );
        let events = seen.lock().unwrap().clone();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["clientId"], "web-1");
        assert_eq!(events[0]["holder"]["name"], "Office iMac");
    }
}
