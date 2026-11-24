use super::*;
use axum::http::HeaderValue;

fn headers(values: &[&str]) -> HeaderMap {
    let mut map = HeaderMap::new();
    for value in values {
        map.append(HEADER, HeaderValue::from_str(value).unwrap());
    }
    map
}

fn uri(text: &str) -> Uri {
    text.parse().unwrap()
}

#[test]
fn only_the_current_api_version_is_served() {
    let path = uri("/api/sessions");
    assert!(require(&headers(&["app/2"]), &path, false).is_ok());
    assert!(require(&headers(&["web-1.0_x/2"]), &path, false).is_ok());
    for bad in [
        vec![],
        vec!["app/1"],
        vec!["app/3"],
        vec!["app/02"],
        vec!["app"],
        vec!["/2"],
        vec!["app/2", "app/2"],
        vec!["app/two"],
        vec!["a p p/2"],
    ] {
        let error = require(&headers(&bad), &path, false).unwrap_err();
        assert_eq!(
            (error.status, error.code),
            (426, "client_upgrade_required"),
            "{bad:?}"
        );
    }
}

#[test]
fn health_capabilities_and_non_api_paths_are_exempt() {
    for path in ["/api/health", "/api/capabilities", "/node/connect", "/"] {
        assert!(
            require(&HeaderMap::new(), &uri(path), false).is_ok(),
            "{path}"
        );
    }
    assert!(require(&HeaderMap::new(), &uri("/api/capabilities/x"), false).is_err());
}

#[test]
fn websocket_upgrades_may_name_the_client_in_the_query() {
    let path = uri("/api/events?sessionId=s&client=web%2F2");
    assert!(require(&HeaderMap::new(), &path, true).is_ok());
    assert!(require(&HeaderMap::new(), &uri("/api/events?client=web/2"), true).is_ok());
    // Only upgrades: an ordinary request must use the header.
    assert!(require(&HeaderMap::new(), &path, false).is_err());
    assert!(require(&HeaderMap::new(), &uri("/api/events?client=web/1"), true).is_err());
    // A header, when present, wins and must itself be valid.
    assert!(require(&headers(&["web/1"]), &path, true).is_err());
}
