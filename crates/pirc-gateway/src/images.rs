//! Pictures the user uploads for avatars (pots, groups, the user), kept by the
//! Gateway so every device shows them (plans/roadmap.md M7 step 0).
//!
//! `POST /api/images` takes the raw bytes of a PNG, JPEG or WebP picture of at
//! most 1 MiB (the app crops and scales it to 512 × 512 first) and returns its
//! `imageId`; `GET /api/images/{id}` serves it to its owner. A picture nobody
//! refers to any more is deleted by whoever replaced or removed it.

use axum::Router;
use axum::extract::{Extension, Path, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::json;

use crate::app::{AppState, ReqBody};
use crate::auth::Identity;
use crate::error::{ApiError, ApiResult};
use crate::http::Body;
use crate::util::{new_id, now_ms};

pub const MAX_BYTES: usize = 1024 * 1024;

/// The picture's type by its signature, never by what the client claims.
pub fn sniff(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]) {
        Some("image/png")
    } else if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some("image/jpeg")
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

pub fn store(conn: &Connection, owner: &str, bytes: &[u8]) -> ApiResult<String> {
    if bytes.is_empty() || bytes.len() > MAX_BYTES {
        return Err(ApiError::new(
            413,
            "payload_too_large",
            "A picture is at most 1 MiB",
        ));
    }
    let mime = sniff(bytes).ok_or_else(|| {
        ApiError::new(
            400,
            "invalid_input",
            "A picture is a PNG, JPEG or WebP image",
        )
    })?;
    let id = new_id("img");
    conn.execute(
        "INSERT INTO images(id,owner_user,mime_type,bytes,created_at) VALUES(?1,?2,?3,?4,?5)",
        params![id, owner, mime, bytes, now_ms()],
    )?;
    Ok(id)
}

/// An `avatarImage` a request names must be one of the owner's pictures.
pub fn require_owned(conn: &Connection, owner: &str, id: &str) -> ApiResult<()> {
    let found: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM images WHERE id=?1 AND owner_user=?2)",
        params![id, owner],
        |r| r.get(0),
    )?;
    if found {
        Ok(())
    } else {
        Err(ApiError::new(
            400,
            "invalid_input",
            "Upload the picture first",
        ))
    }
}

/// Delete a picture once nothing refers to it any more (a pot, a group or the
/// user); call it after the reference changed, in the same transaction.
pub fn release(conn: &Connection, id: Option<&str>) -> ApiResult<()> {
    let Some(id) = id else {
        return Ok(());
    };
    conn.execute(
        "DELETE FROM images WHERE id=?1
           AND NOT EXISTS(SELECT 1 FROM pots WHERE avatar_upload=?1)
           AND NOT EXISTS(SELECT 1 FROM threads WHERE avatar_image=?1)
           AND NOT EXISTS(SELECT 1 FROM user_profiles WHERE avatar_image=?1)",
        [id],
    )?;
    Ok(())
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/images", post(upload))
        .route("/api/images/{id}", get(download))
}

async fn upload(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> ApiResult<(StatusCode, axum::Json<serde_json::Value>)> {
    let Body::Raw { bytes, .. } = body else {
        return Err(ApiError::new(
            400,
            "invalid_input",
            "Send the picture's bytes",
        ));
    };
    let id = store(&app.db.lock(), &identity.user, &bytes)?;
    Ok((StatusCode::CREATED, axum::Json(json!({ "imageId": id }))))
}

async fn download(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let found: Option<(String, Vec<u8>)> = app
        .db
        .lock()
        .query_row(
            "SELECT mime_type, bytes FROM images WHERE id=?1 AND owner_user=?2",
            params![id, identity.user],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    let (mime, bytes) = found.ok_or_else(|| ApiError::not_found("Picture not found"))?;
    // An id never changes its bytes: a new picture gets a new id.
    Ok((
        [
            (header::CONTENT_TYPE, mime),
            (
                header::CACHE_CONTROL,
                "private, max-age=31536000, immutable".to_owned(),
            ),
        ],
        bytes,
    )
        .into_response())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{app_with_models, call};

    const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3];

    #[test]
    fn the_type_comes_from_the_bytes() {
        assert_eq!(sniff(PNG), Some("image/png"));
        assert_eq!(sniff(&[0xff, 0xd8, 0xff, 9]), Some("image/jpeg"));
        assert_eq!(sniff(b"RIFF\0\0\0\0WEBPVP8 "), Some("image/webp"));
        assert_eq!(sniff(b"GIF89a"), None);
    }

    #[tokio::test]
    async fn pictures_are_the_owners_and_never_change_under_an_id() {
        let (app, _dir) = app_with_models(json!({}));
        let (status, uploaded) = call(
            &app,
            "POST",
            "/api/images",
            Some("alice"),
            None,
            Some(json!({ "bytes": true })),
        )
        .await;
        // JSON bodies are not pictures.
        assert_eq!(status, 400, "{uploaded}");
        let id = {
            let conn = app.db.lock();
            store(&conn, "alice", PNG).unwrap()
        };
        assert_eq!(
            store(&app.db.lock(), "alice", b"GIF89a")
                .unwrap_err()
                .status,
            400
        );
        assert_eq!(
            store(&app.db.lock(), "alice", &vec![0u8; MAX_BYTES + 1])
                .unwrap_err()
                .status,
            413
        );
        // Another owner cannot use or read it.
        assert_eq!(
            require_owned(&app.db.lock(), "bob", &id)
                .unwrap_err()
                .status,
            400
        );
        let (status, body) = call(
            &app,
            "GET",
            &format!("/api/images/{id}"),
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!(status, 200);
        assert_eq!(body["error"], json!(null), "served as bytes, not JSON");
        assert_eq!(
            call(
                &app,
                "GET",
                &format!("/api/images/{id}"),
                Some("bob"),
                None,
                None
            )
            .await
            .0,
            404
        );
        // A picture only its owner still refers to stays; a released one goes.
        app.db
            .lock()
            .execute(
                "INSERT INTO user_profiles(owner_user,display_name,avatar_image,updated_at) VALUES('alice','A',?1,0)",
                [&id],
            )
            .unwrap();
        release(&app.db.lock(), Some(&id)).unwrap();
        assert!(require_owned(&app.db.lock(), "alice", &id).is_ok());
        app.db
            .lock()
            .execute("DELETE FROM user_profiles", [])
            .unwrap();
        release(&app.db.lock(), Some(&id)).unwrap();
        assert!(require_owned(&app.db.lock(), "alice", &id).is_err());
    }
}
