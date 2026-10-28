//! Who sent a browser-API request (`apps/gateway/src/daemon/auth.ts`).
//!
//! Every request must come through a trusted proxy (its address and, when
//! `PIRC_PROXY_SECRET` is set, the shared secret header) with an allowed
//! Host. The identity is either the proxy's forward-auth header or, for
//! native clients, a device bearer token; a request carrying both is refused
//! so a misrouted proxy fails closed.

use std::net::IpAddr;

use axum::http::{HeaderMap, Method};
use pirc_config::BrowserAuth;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

use crate::error::{ApiError, ApiResult};
use crate::management::ManagementGrantAuthorizer;

/// Header the reverse proxy sets to `PIRC_PROXY_SECRET` (and must strip from clients).
pub const PROXY_SECRET_HEADER: &str = "x-pirc-proxy-secret";
/// Short-lived, browser-approved native management credential.
pub const MANAGEMENT_GRANT_HEADER: &str = "x-pirc-management";

/// The authenticated caller of a request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    pub user: String,
    /// Set when the caller authenticated with a device token instead of forward auth.
    pub device_id: Option<String>,
    /// True only when a device bearer presented a valid scoped management grant.
    pub management_authorized: bool,
}

/// A live device token's device and owner.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Device {
    pub id: String,
    pub user: String,
}

/// Checks device tokens (`DeviceTokens.authenticate`); any failure is a 401
/// that reveals nothing.
pub trait DeviceAuthenticator: Send + Sync {
    fn authenticate(&self, token: &str) -> ApiResult<Device>;
}

/// Headers whose duplicates Node.js drops (keeping the first) rather than
/// joining with `, `; the TS gateway saw headers through that rule.
const SINGLE_VALUED: &[&str] = &[
    "age",
    "authorization",
    "content-length",
    "content-type",
    "etag",
    "expires",
    "from",
    "host",
    "if-modified-since",
    "if-unmodified-since",
    "last-modified",
    "location",
    "max-forwards",
    "proxy-authorization",
    "referer",
    "retry-after",
    "server",
    "user-agent",
];

/// A header as Node.js presents it: latin-1 text, duplicates joined with
/// `, ` (or the first kept for [`SINGLE_VALUED`] headers).
pub fn header(headers: &HeaderMap, name: &str) -> Option<String> {
    let mut values = headers.get_all(name).iter();
    let first = latin1(values.next()?.as_bytes());
    if SINGLE_VALUED.contains(&name) {
        return Some(first);
    }
    Some(values.fold(first, |mut joined, value| {
        joined.push_str(", ");
        joined.push_str(&latin1(value.as_bytes()));
        joined
    }))
}

fn latin1(bytes: &[u8]) -> String {
    bytes.iter().map(|&byte| char::from(byte)).collect()
}

/// The peer address as Node.js prints it (`::ffff:127.0.0.1` for an IPv4
/// peer of a dual-stack listener).
pub fn peer_address(ip: IpAddr) -> String {
    ip.to_string()
}

fn digest(value: &str) -> [u8; 32] {
    Sha256::digest(value.as_bytes()).into()
}

/// Constant-time comparison of the proxy's header with the configured
/// secret. Hashing gives equal-length inputs, so the length never leaks.
pub fn proxy_secret_matches(header: Option<&str>, secret: &str) -> bool {
    header.is_some_and(|value| bool::from(digest(value).ct_eq(&digest(secret))))
}

/// What follows a case-insensitive `bearer` scheme.
fn after_bearer(authorization: &str) -> Option<&str> {
    authorization
        .get(..6)
        .filter(|scheme| scheme.eq_ignore_ascii_case("bearer"))
        .map(|_| &authorization[6..])
}

/// `/^bearer\s+pirc_dev_/i`: anything that looks like a device token takes
/// the device path, never forward auth.
fn is_device_bearer(authorization: &str) -> bool {
    let Some(rest) = after_bearer(authorization) else {
        return false;
    };
    let token = rest.trim_start_matches(pirc_config::text::is_space);
    token.len() < rest.len()
        && token
            .get(..9)
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case("pirc_dev_"))
}

/// `/^bearer\s+(\S+)$/i`, else the empty string.
fn bearer_token(authorization: &str) -> &str {
    let Some(rest) = after_bearer(authorization) else {
        return "";
    };
    let token = rest.trim_start_matches(pirc_config::text::is_space);
    if token.len() == rest.len() || token.is_empty() || token.contains(pirc_config::text::is_space)
    {
        return "";
    }
    token
}

/// Routes a device token may not reach: device management and model backends/credentials.
fn device_denied(path: &str) -> bool {
    let decoded = percent_decode(path);
    [path, decoded.as_str()].iter().any(|path| {
        ["/api/devices", "/api/providers", "/api/provider-auth"]
            .iter()
            .any(|prefix| {
                path.strip_prefix(prefix)
                    .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
            })
    })
}

/// Lenient `%XX` decoding (invalid sequences stay as they are).
pub fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%'
            && let Some(byte) = bytes
                .get(index + 1..index + 3)
                .and_then(|hex| std::str::from_utf8(hex).ok())
                .and_then(|hex| u8::from_str_radix(hex, 16).ok())
        {
            out.push(byte);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// A request's parts that authentication looks at.
pub struct RequestInfo<'a> {
    pub peer: &'a str,
    pub headers: &'a HeaderMap,
    /// The path without the query.
    pub path: &'a str,
    pub method: &'a Method,
}

/// Identify the caller of a browser-API request (`validateRequest`).
pub fn validate_request(
    request: &RequestInfo<'_>,
    config: &BrowserAuth,
    devices: &dyn DeviceAuthenticator,
    require_origin: bool,
    management: &dyn ManagementGrantAuthorizer,
) -> ApiResult<Identity> {
    let untrusted = || {
        ApiError::new(
            401,
            "unauthenticated",
            "Request did not arrive from a trusted proxy",
        )
    };
    if !config.trusted_proxies.contains(request.peer) {
        return Err(untrusted());
    }
    // A local process connecting from the proxy's address is not the proxy.
    if let Some(secret) = &config.proxy_secret
        && !proxy_secret_matches(
            header(request.headers, PROXY_SECRET_HEADER).as_deref(),
            secret,
        )
    {
        return Err(untrusted());
    }
    let host = header(request.headers, "host");
    if !host.is_some_and(|host| config.allowed_hosts.contains(&host)) {
        return Err(ApiError::new(403, "invalid_host", "Host is not allowed"));
    }
    let origin = header(request.headers, "origin");
    let invalid_origin = || ApiError::new(403, "invalid_origin", "Origin is not allowed");
    let forbidden = || ApiError::new(403, "forbidden", "Identity is not allowed");
    if let Some(authorization) = header(request.headers, "authorization")
        && is_device_bearer(&authorization)
    {
        if request
            .headers
            .contains_key(config.identity_header.as_str())
        {
            return Err(ApiError::new(
                401,
                "unauthenticated",
                "A request cannot carry both a device token and a forward-auth identity",
            ));
        }
        // A bearer token is never sent ambiently, so there is no cross-site
        // request to guard against; an Origin that is sent must still be allowed.
        if origin
            .as_ref()
            .is_some_and(|origin| !config.allowed_origins.contains(origin))
        {
            return Err(invalid_origin());
        }
        let device = devices.authenticate(bearer_token(&authorization))?;
        if !config.allowed_users.contains(&device.user) {
            return Err(forbidden());
        }
        let management_authorized = if device_denied(request.path) {
            let grant = header(request.headers, MANAGEMENT_GRANT_HEADER);
            let authorized = grant.as_deref().is_some_and(|token| {
                management.authorize(
                    &device.user,
                    &device.id,
                    token,
                    request.method.as_str(),
                    request.path,
                )
            });
            if !authorized {
                return Err(ApiError::new(
                    403,
                    "forbidden",
                    "Device tokens cannot reach this route",
                ));
            }
            true
        } else {
            false
        };
        return Ok(Identity {
            user: device.user,
            device_id: Some(device.id),
            management_authorized,
        });
    }
    if (require_origin || origin.is_some())
        && !origin.is_some_and(|origin| config.allowed_origins.contains(&origin))
    {
        return Err(invalid_origin());
    }
    let identity = header(request.headers, &config.identity_header)
        .filter(|identity| !identity.is_empty())
        .ok_or_else(|| {
            ApiError::new(401, "unauthenticated", "Trusted identity header is missing")
        })?;
    if !config.allowed_users.contains(&identity) {
        return Err(forbidden());
    }
    Ok(Identity {
        user: identity,
        device_id: None,
        management_authorized: false,
    })
}

/// Mutations need an allowed Origin; reads only need one that is allowed when sent.
pub fn requires_origin(method: &Method) -> bool {
    !matches!(*method, Method::GET | Method::HEAD | Method::OPTIONS)
}

/// Revalidate native authorization after asynchronous work; caller owns DB snapshot.
pub(crate) fn require_current_device(
    app: &crate::app::AppState,
    db: &rusqlite::Connection,
    identity: &Identity,
) -> ApiResult<()> {
    use crate::util::now_ms;
    use rusqlite::params;
    if let Some(device) = &identity.device_id {
        let stamp = now_ms();
        let idle = i64::try_from(app.config.device_token_idle_ms).unwrap_or(i64::MAX);
        let live: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM device_tokens WHERE id=?1 AND owner_user=?2 AND expires_at>?3 AND last_used_at>?4)",params![device,identity.user,stamp,stamp.saturating_sub(idle)],|r|r.get(0))?;
        if !live {
            return Err(ApiError::new(
                401,
                "unauthorized",
                "The paired device is no longer authorized",
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use axum::http::HeaderValue;

    use super::*;

    struct Devices;
    impl DeviceAuthenticator for Devices {
        fn authenticate(&self, token: &str) -> ApiResult<Device> {
            match token {
                "pirc_dev_good" => Ok(Device {
                    id: "dev_1".into(),
                    user: "u@example.com".into(),
                }),
                "pirc_dev_stranger" => Ok(Device {
                    id: "dev_2".into(),
                    user: "x@example.com".into(),
                }),
                _ => Err(ApiError::new(
                    401,
                    "unauthenticated",
                    "Device token is invalid, expired or revoked",
                )),
            }
        }
    }

    struct NoManagement;
    impl ManagementGrantAuthorizer for NoManagement {
        fn authorize(&self, _: &str, _: &str, _: &str, _: &str, _: &str) -> bool {
            false
        }
    }

    struct ProviderManagement;
    impl ManagementGrantAuthorizer for ProviderManagement {
        fn authorize(
            &self,
            user: &str,
            device_id: &str,
            token: &str,
            method: &str,
            pathname: &str,
        ) -> bool {
            user == "u@example.com"
                && device_id == "dev_1"
                && token == "approved-grant"
                && method == "GET"
                && pathname == "/api/providers"
        }
    }

    fn config(secret: Option<&str>) -> BrowserAuth {
        let set = |items: &[&str]| {
            items
                .iter()
                .map(|item| item.to_string())
                .collect::<HashSet<_>>()
        };
        BrowserAuth {
            trusted_proxies: set(&["127.0.0.1"]),
            allowed_users: set(&["u@example.com"]),
            allowed_origins: ["https://a.example".to_owned()].into_iter().collect(),
            allowed_hosts: set(&["a.example"]),
            identity_header: "x-pirc-user".into(),
            proxy_secret: secret.map(str::to_owned),
        }
    }

    fn headers(pairs: &[(&'static str, &str)]) -> HeaderMap {
        let mut map = HeaderMap::new();
        for (name, value) in pairs {
            map.append(*name, HeaderValue::from_str(value).unwrap());
        }
        map
    }

    fn check(
        peer: &str,
        pairs: &[(&'static str, &str)],
        path: &str,
        secret: Option<&str>,
        require_origin: bool,
    ) -> Result<Identity, (&'static str, String)> {
        let headers = headers(pairs);
        validate_request(
            &RequestInfo {
                peer,
                headers: &headers,
                path,
                method: &Method::GET,
            },
            &config(secret),
            &Devices,
            require_origin,
            &NoManagement,
        )
        .map_err(|error| (error.code, error.message))
    }

    const BROWSER: &[(&str, &str)] = &[
        ("host", "a.example"),
        ("origin", "https://a.example"),
        ("x-pirc-user", "u@example.com"),
    ];

    #[test]
    fn forward_auth() {
        let ok = check("127.0.0.1", BROWSER, "/api/x", None, true).unwrap();
        assert_eq!(ok.user, "u@example.com");
        assert_eq!(
            check("10.0.0.1", BROWSER, "/api/x", None, false)
                .unwrap_err()
                .0,
            "unauthenticated"
        );
        let no_origin = &BROWSER[..1]
            .iter()
            .chain(&BROWSER[2..])
            .copied()
            .collect::<Vec<_>>();
        assert!(check("127.0.0.1", no_origin, "/api/x", None, false).is_ok());
        assert_eq!(
            check("127.0.0.1", no_origin, "/api/x", None, true)
                .unwrap_err()
                .0,
            "invalid_origin"
        );
        // A duplicated identity header is joined, as Node.js does, and so refused.
        let mut doubled = BROWSER.to_vec();
        doubled.push(("x-pirc-user", "u@example.com"));
        assert_eq!(
            check("127.0.0.1", &doubled, "/api/x", None, false)
                .unwrap_err()
                .0,
            "forbidden"
        );
    }

    #[test]
    fn proxy_secret() {
        let secret = "s".repeat(32);
        assert_eq!(
            check("127.0.0.1", BROWSER, "/", Some(&secret), false)
                .unwrap_err()
                .0,
            "unauthenticated"
        );
        let mut with = BROWSER.to_vec();
        with.push((PROXY_SECRET_HEADER, &secret));
        assert!(check("127.0.0.1", &with, "/", Some(&secret), false).is_ok());
        assert!(!proxy_secret_matches(Some("s"), &secret));
    }

    #[test]
    fn device_tokens() {
        let device = [
            ("host", "a.example"),
            ("authorization", "Bearer pirc_dev_good"),
        ];
        let ok = check("127.0.0.1", &device, "/api/sessions", None, true).unwrap();
        assert_eq!(ok.device_id.as_deref(), Some("dev_1"));
        let lower = [
            ("host", "a.example"),
            ("authorization", "bearer   pirc_dev_good"),
        ];
        assert!(check("127.0.0.1", &lower, "/api/sessions", None, true).is_ok());
        for path in [
            "/api/devices",
            "/api/devices/x",
            "/api/providers",
            "/api/%64evices",
        ] {
            assert_eq!(
                check("127.0.0.1", &device, path, None, false)
                    .unwrap_err()
                    .1,
                "Device tokens cannot reach this route"
            );
        }
        assert!(check("127.0.0.1", &device, "/api/devicesx", None, false).is_ok());
        let stranger = [
            ("host", "a.example"),
            ("authorization", "Bearer pirc_dev_stranger"),
        ];
        assert_eq!(
            check("127.0.0.1", &stranger, "/", None, false)
                .unwrap_err()
                .0,
            "forbidden"
        );
        let mut both = BROWSER.to_vec();
        both.push(("authorization", "Bearer pirc_dev_good"));
        assert_eq!(
            check("127.0.0.1", &both, "/", None, false).unwrap_err().1,
            "A request cannot carry both a device token and a forward-auth identity"
        );
        let foreign = [
            ("host", "a.example"),
            ("origin", "https://evil.example"),
            ("authorization", "Bearer pirc_dev_good"),
        ];
        assert_eq!(
            check("127.0.0.1", &foreign, "/", None, false)
                .unwrap_err()
                .0,
            "invalid_origin"
        );
        // Not a device token: forward auth decides.
        let other = [("host", "a.example"), ("authorization", "Bearer other")];
        assert_eq!(
            check("127.0.0.1", &other, "/", None, false).unwrap_err().1,
            "Trusted identity header is missing"
        );
    }

    #[test]
    fn device_management_requires_a_matching_scoped_grant() {
        let pairs = [
            ("host", "a.example"),
            ("authorization", "Bearer pirc_dev_good"),
            (MANAGEMENT_GRANT_HEADER, "approved-grant"),
        ];
        let headers = headers(&pairs);
        let request = RequestInfo {
            peer: "127.0.0.1",
            headers: &headers,
            path: "/api/providers",
            method: &Method::GET,
        };
        let identity = validate_request(
            &request,
            &config(None),
            &Devices,
            false,
            &ProviderManagement,
        )
        .unwrap();
        assert!(identity.management_authorized);
        assert_eq!(identity.device_id.as_deref(), Some("dev_1"));

        let wrong_path = RequestInfo {
            path: "/api/devices",
            ..request
        };
        assert_eq!(
            validate_request(
                &wrong_path,
                &config(None),
                &Devices,
                false,
                &ProviderManagement,
            )
            .unwrap_err()
            .code,
            "forbidden"
        );
    }

    #[test]
    fn bearer_parsing() {
        assert!(is_device_bearer("Bearer pirc_dev_x"));
        assert!(is_device_bearer("BEARER\tpirc_dev_x"));
        assert!(!is_device_bearer("Bearerpirc_dev_x"));
        assert!(!is_device_bearer("Basic pirc_dev_x"));
        assert_eq!(bearer_token("Bearer abc"), "abc");
        assert_eq!(bearer_token("Bearer abc def"), "");
        assert_eq!(bearer_token("Bearerabc"), "");
    }
}
