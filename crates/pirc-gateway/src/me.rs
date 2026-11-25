//! The user's own profile (`GET|PATCH /api/me`): the name pots call them by
//! and their avatar (plans/roadmap.md M7 step 0). A user without a profile
//! has the signed-in name and colour 1.

use axum::Router;
use axum::extract::{Extension, State};
use axum::routing::get;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::app::{AppState, ReqBody};
use crate::auth::Identity;
use crate::error::{ApiError, ApiResult};
use crate::images;
use crate::util::now_ms;

pub const MAX_NAME: usize = 60;

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub display_name: String,
    pub avatar_color: u8,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avatar_image: Option<String>,
    pub revision: i64,
}

/// The user's profile, saved or the default one.
pub fn read(conn: &Connection, user: &str) -> ApiResult<Profile> {
    let saved: Option<(String, u8, Option<String>, i64)> = conn
        .query_row(
            "SELECT display_name, avatar_color, avatar_image, revision FROM user_profiles WHERE owner_user=?1",
            [user],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()?;
    Ok(match saved {
        Some((display_name, avatar_color, avatar_image, revision)) => Profile {
            display_name,
            avatar_color,
            avatar_image,
            revision,
        },
        None => Profile {
            display_name: user.to_owned(),
            avatar_color: 1,
            avatar_image: None,
            revision: 0,
        },
    })
}

/// What the profile shows to the pots: the name only.
pub fn display_name(conn: &Connection, user: &str) -> ApiResult<String> {
    Ok(read(conn, user)?.display_name)
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Patch {
    pub revision: i64,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub avatar_color: Option<u8>,
    /// An uploaded picture, or `null` to remove it. Absent leaves it.
    #[serde(default, deserialize_with = "present")]
    pub avatar_image: Option<Option<String>>,
}

/// `Option<Option<T>>` that tells an absent field from `null`.
pub(crate) fn present<'de, D>(deserializer: D) -> Result<Option<Option<String>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer).map(Some)
}

/// The same for a small number.
pub(crate) fn present_u8<'de, D>(deserializer: D) -> Result<Option<Option<u8>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<u8>::deserialize(deserializer).map(Some)
}

pub fn update(conn: &Connection, user: &str, patch: Patch) -> ApiResult<Profile> {
    let current = read(conn, user)?;
    if patch.revision != current.revision {
        return Err(ApiError::new(
            409,
            "revision_conflict",
            "Your profile changed; read it again",
        ));
    }
    let display_name = match patch.display_name.as_deref().map(str::trim) {
        None => current.display_name.clone(),
        Some(name)
            if name.is_empty()
                || name.chars().count() > MAX_NAME
                || name.chars().any(char::is_control) =>
        {
            return Err(ApiError::new(
                400,
                "invalid_input",
                "A name is 1 to 60 characters",
            ));
        }
        Some(name) => name.to_owned(),
    };
    let avatar_color = patch.avatar_color.unwrap_or(current.avatar_color);
    if !(1..=5).contains(&avatar_color) {
        return Err(ApiError::new(
            400,
            "invalid_input",
            "avatarColor must be 1 to 5",
        ));
    }
    let avatar_image = match patch.avatar_image {
        None => current.avatar_image.clone(),
        Some(Some(id)) => {
            images::require_owned(conn, user, &id)?;
            Some(id)
        }
        Some(None) => None,
    };
    let tx = conn.unchecked_transaction()?;
    tx.execute(
        "INSERT INTO user_profiles(owner_user,display_name,avatar_color,avatar_image,revision,updated_at)
         VALUES(?1,?2,?3,?4,?5,?6)
         ON CONFLICT(owner_user) DO UPDATE SET display_name=excluded.display_name,
           avatar_color=excluded.avatar_color, avatar_image=excluded.avatar_image,
           revision=excluded.revision, updated_at=excluded.updated_at",
        params![user, display_name, avatar_color, avatar_image, current.revision + 1, now_ms()],
    )?;
    if current.avatar_image != avatar_image {
        images::release(&tx, current.avatar_image.as_deref())?;
    }
    tx.commit()?;
    read(conn, user)
}

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/me", get(read_me).patch(update_me))
}

async fn read_me(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> ApiResult<axum::Json<serde_json::Value>> {
    Ok(axum::Json(
        json!({ "profile": read(&app.db.lock(), &identity.user)? }),
    ))
}

async fn update_me(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<serde_json::Value>> {
    let patch: Patch = body.parse()?;
    let profile = update(&app.db.lock(), &identity.user, patch)?;
    Ok(axum::Json(json!({ "profile": profile })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{app_with_models, call};

    #[tokio::test]
    async fn the_profile_starts_as_the_signed_in_user_and_keeps_its_revision() {
        let (app, _dir) = app_with_models(json!({}));
        let (_, me) = call(&app, "GET", "/api/me", Some("alice"), None, None).await;
        assert_eq!(me["profile"]["displayName"], "alice");
        assert_eq!(
            (
                me["profile"]["avatarColor"].as_u64(),
                me["profile"]["revision"].as_u64()
            ),
            (Some(1), Some(0))
        );
        let (status, updated) = call(
            &app,
            "PATCH",
            "/api/me",
            Some("alice"),
            None,
            Some(json!({ "revision": 0, "displayName": "  Ice Bear ", "avatarColor": 3 })),
        )
        .await;
        assert_eq!(status, 200, "{updated}");
        assert_eq!(updated["profile"]["displayName"], "Ice Bear");
        assert_eq!(updated["profile"]["revision"], 1);
        // A stale revision is refused; another owner is unaffected.
        assert_eq!(
            call(
                &app,
                "PATCH",
                "/api/me",
                Some("alice"),
                None,
                Some(json!({ "revision": 0, "avatarColor": 2 }))
            )
            .await
            .0,
            409
        );
        assert_eq!(
            call(
                &app,
                "PATCH",
                "/api/me",
                Some("alice"),
                None,
                Some(json!({ "revision": 1, "displayName": "  " }))
            )
            .await
            .0,
            400
        );
        assert_eq!(
            call(
                &app,
                "PATCH",
                "/api/me",
                Some("alice"),
                None,
                Some(json!({ "revision": 1, "avatarColor": 9 }))
            )
            .await
            .0,
            400
        );
        assert_eq!(
            call(
                &app,
                "PATCH",
                "/api/me",
                Some("alice"),
                None,
                Some(json!({ "revision": 1, "avatarImage": "img_unknown" }))
            )
            .await
            .0,
            400
        );
        let (_, bob) = call(&app, "GET", "/api/me", Some("bob"), None, None).await;
        assert_eq!(bob["profile"]["displayName"], "bob");
        // Pots call the user by the new name.
        assert_eq!(display_name(&app.db.lock(), "alice").unwrap(), "Ice Bear");
    }
}
