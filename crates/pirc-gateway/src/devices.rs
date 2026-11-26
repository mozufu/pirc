//! Device tokens (`apps/gateway/src/daemon/devices.ts`): per-device bearer
//! credentials for native clients (the Android app) that cannot complete the
//! forward-auth login. A browser holding forward auth pairs a device and sees
//! its token exactly once; the gateway stores only the token's SHA-256 hash.
//!
//! Tokens die aggressively: after `idle_ms` without use, `max_age_ms` after
//! pairing, or on revocation. Open WebSockets of a dead token are closed.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rusqlite::{OptionalExtension, Row, params};
use serde::Serialize;
use subtle::ConstantTimeEq;

use crate::auth::{Device, DeviceAuthenticator};
use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms, random_bytes, sha256_hex};

pub const DEVICE_TOKEN_PREFIX: &str = "pirc_dev_";
const MAX_DEVICES_PER_USER: usize = 10;
/// `last_used_at` is written at most this often per token.
const TOUCH_INTERVAL_MS: i64 = 60_000;
/// After a rotation the replaced token works this long, unless the new one
/// is used first: a phone that lost the response can still ask again.
pub const ROTATION_GRACE_MS: i64 = 5 * 60_000;
const SWEEP_INTERVAL: Duration = Duration::from_secs(60);

/// What a device's owner sees of it.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceSummary {
    pub id: String,
    pub name: String,
    pub created_at: i64,
    pub last_used_at: i64,
    /// When the token dies if it is not used again: the earlier of the idle
    /// and the maximum window.
    pub expires_at: i64,
    /// When the idle window ends without use.
    pub idle_expires_at: i64,
}

struct DeviceRow {
    id: String,
    owner_user: String,
    name: String,
    created_at: i64,
    expires_at: i64,
    last_used_at: i64,
    token_hash: String,
    previous_token_hash: Option<String>,
    previous_expires_at: Option<i64>,
}

impl DeviceRow {
    fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get("id")?,
            owner_user: row.get("owner_user")?,
            name: row.get("name")?,
            created_at: row.get("created_at")?,
            expires_at: row.get("expires_at")?,
            last_used_at: row.get("last_used_at")?,
            token_hash: row.get("token_hash")?,
            previous_token_hash: row.get("previous_token_hash")?,
            previous_expires_at: row.get("previous_expires_at")?,
        })
    }
}

fn new_token() -> String {
    format!(
        "{DEVICE_TOKEN_PREFIX}{}",
        URL_SAFE_NO_PAD.encode(random_bytes::<32>())
    )
}

type Closer = Box<dyn Fn() + Send + Sync>;

pub struct DeviceTokens {
    db: Arc<Db>,
    idle_ms: i64,
    max_age_ms: i64,
    /// Device ID → close callbacks of its open WebSockets.
    sockets: Mutex<HashMap<String, HashMap<u64, Closer>>>,
    next_socket: AtomicU64,
}

/// `^pirc_dev_[A-Za-z0-9_-]{43}$`
fn well_formed(token: &str) -> bool {
    token.strip_prefix(DEVICE_TOKEN_PREFIX).is_some_and(|rest| {
        rest.len() == 43
            && rest
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    })
}

fn invalid() -> ApiError {
    ApiError::new(
        401,
        "unauthenticated",
        "Device token is invalid, expired or revoked",
    )
}

impl DeviceTokens {
    /// How long a newly paired device lives, for approval screens.
    pub fn pairing_terms(&self) -> crate::management::PairingTerms {
        crate::management::PairingTerms {
            idle_days: self.idle_ms / 86_400_000,
            max_days: self.max_age_ms / 86_400_000,
        }
    }

    /// How long a token lives without use.
    pub fn idle_ms(&self) -> i64 {
        self.idle_ms
    }

    pub fn new(db: Arc<Db>, idle_ms: u64, max_age_ms: u64) -> Arc<Self> {
        Arc::new(Self {
            db,
            idle_ms: i64::try_from(idle_ms).unwrap_or(i64::MAX),
            max_age_ms: i64::try_from(max_age_ms).unwrap_or(i64::MAX),
            sockets: Mutex::new(HashMap::new()),
            next_socket: AtomicU64::new(0),
        })
    }

    /// Sweep dead tokens every minute while the service lives.
    pub fn start_sweeper(self: &Arc<Self>) {
        let weak: Weak<Self> = Arc::downgrade(self);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(SWEEP_INTERVAL);
            interval.tick().await;
            loop {
                interval.tick().await;
                let Some(devices) = weak.upgrade() else {
                    return;
                };
                if let Err(error) = devices.sweep() {
                    crate::log::warn(&format!("device sweep failed: {error}"));
                }
            }
        });
    }

    fn deadline(&self, row: &DeviceRow) -> i64 {
        row.expires_at
            .min(row.last_used_at.saturating_add(self.idle_ms))
    }

    fn summary(&self, row: &DeviceRow) -> DeviceSummary {
        DeviceSummary {
            id: row.id.clone(),
            name: row.name.clone(),
            created_at: row.created_at,
            last_used_at: row.last_used_at,
            expires_at: self.deadline(row),
            idle_expires_at: row.last_used_at.saturating_add(self.idle_ms),
        }
    }

    fn rows(&self, user: &str) -> ApiResult<Vec<DeviceRow>> {
        let conn = self.db.lock();
        let mut statement = conn
            .prepare("SELECT * FROM device_tokens WHERE owner_user=? ORDER BY created_at DESC")?;
        let rows = statement.query_map([user], DeviceRow::from_row)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    fn sockets(&self) -> std::sync::MutexGuard<'_, HashMap<String, HashMap<u64, Closer>>> {
        self.sockets
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Close every open socket of the device (outside the lock: closing may
    /// call back into [`Tracked::drop`]).
    fn disconnect(&self, device_id: &str) {
        let closers = self.sockets().remove(device_id);
        for close in closers.into_iter().flat_map(HashMap::into_values) {
            close();
        }
    }

    /// Delete dead tokens and close their sockets.
    pub fn sweep(&self) -> ApiResult<()> {
        let stamp = now_ms();
        let (dead, tracked_live) = {
            let conn = self.db.lock();
            let dead: Vec<String> = {
                let mut statement = conn.prepare(
                    "SELECT id FROM device_tokens WHERE expires_at<=? OR last_used_at<=?-?",
                )?;
                let rows =
                    statement.query_map(params![stamp, stamp, self.idle_ms], |row| row.get(0))?;
                rows.collect::<Result<_, _>>()?
            };
            for device_id in &dead {
                conn.execute("DELETE FROM device_tokens WHERE id=?", [device_id])?;
            }
            // A replaced token that ran out: the sockets it opened close too.
            let replaced: Vec<String> = {
                let mut statement =
                    conn.prepare("SELECT id FROM device_tokens WHERE previous_expires_at<=?")?;
                let rows = statement.query_map([stamp], |row| row.get(0))?;
                rows.collect::<Result<_, _>>()?
            };
            conn.execute(
                "UPDATE device_tokens SET previous_token_hash=NULL, previous_expires_at=NULL
                 WHERE previous_expires_at<=?",
                [stamp],
            )?;
            let tracked: Vec<String> = self.sockets().keys().cloned().collect();
            let mut gone = Vec::new();
            for device_id in tracked {
                let exists = conn
                    .query_row(
                        "SELECT 1 FROM device_tokens WHERE id=?",
                        [&device_id],
                        |_| Ok(()),
                    )
                    .optional()?
                    .is_some();
                if !exists {
                    gone.push(device_id);
                }
            }
            gone.extend(replaced);
            (dead, gone)
        };
        for device_id in dead.iter().chain(&tracked_live) {
            self.disconnect(device_id);
        }
        Ok(())
    }

    /// Look up one live device without exposing its credential or token hash.
    pub fn get(&self, user: &str, device_id: &str) -> ApiResult<Option<DeviceSummary>> {
        self.sweep()?;
        let row = {
            let conn = self.db.lock();
            conn.query_row(
                "SELECT * FROM device_tokens WHERE id=? AND owner_user=?",
                [device_id, user],
                DeviceRow::from_row,
            )
            .optional()?
        };
        let Some(row) = row else {
            return Ok(None);
        };
        if now_ms() >= self.deadline(&row) {
            self.db
                .lock()
                .execute("DELETE FROM device_tokens WHERE id=?", [&row.id])?;
            self.disconnect(&row.id);
            return Ok(None);
        }
        Ok(Some(self.summary(&row)))
    }

    pub fn list(&self, user: &str) -> ApiResult<Vec<DeviceSummary>> {
        self.sweep()?;
        Ok(self
            .rows(user)?
            .iter()
            .map(|row| self.summary(row))
            .collect())
    }

    /// Pair a device; the token is returned this once and never again.
    pub fn create(&self, user: &str, name: &str) -> ApiResult<(DeviceSummary, String)> {
        self.sweep()?;
        let token = new_token();
        let stamp = now_ms();
        let row = DeviceRow {
            id: new_id("dev"),
            owner_user: user.to_owned(),
            name: name.to_owned(),
            created_at: stamp,
            expires_at: stamp.saturating_add(self.max_age_ms),
            last_used_at: stamp,
            token_hash: sha256_hex(&token),
            previous_token_hash: None,
            previous_expires_at: None,
        };
        // Count and insert under one lock: concurrent pairings stay within the limit.
        let conn = self.db.lock();
        let paired: i64 = conn.query_row(
            "SELECT count(*) FROM device_tokens WHERE owner_user=?",
            [user],
            |row| row.get(0),
        )?;
        if paired >= MAX_DEVICES_PER_USER as i64 {
            return Err(ApiError::new(
                409,
                "conflict",
                format!("At most {MAX_DEVICES_PER_USER} devices can be paired; revoke one first"),
            ));
        }
        conn.execute(
            "INSERT INTO device_tokens (id, owner_user, name, token_hash, created_at, expires_at, last_used_at) VALUES (?,?,?,?,?,?,?)",
            params![
                row.id,
                row.owner_user,
                row.name,
                row.token_hash,
                row.created_at,
                row.expires_at,
                row.last_used_at
            ],
        )?;
        Ok((self.summary(&row), token))
    }

    /// Give the device that sent `presented` a new token for the same record
    /// (ID, name, push targets) and new idle and maximum windows. The token
    /// that asked keeps working until the new one is first used or
    /// [`ROTATION_GRACE_MS`] pass; a retry with it (the first response was
    /// lost) replaces the token that was never received and does not extend
    /// that time. Management grants live elsewhere and are not touched.
    pub fn rotate(
        &self,
        user: &str,
        device_id: &str,
        presented: &str,
    ) -> ApiResult<(DeviceSummary, String)> {
        if !well_formed(presented) {
            return Err(invalid());
        }
        let presented_hash = sha256_hex(presented);
        let token = new_token();
        let stamp = now_ms();
        let conn = self.db.lock();
        let row = conn
            .query_row(
                "SELECT * FROM device_tokens WHERE id=? AND owner_user=?",
                [device_id, user],
                DeviceRow::from_row,
            )
            .optional()?
            .ok_or_else(invalid)?;
        if stamp >= self.deadline(&row) {
            return Err(invalid());
        }
        let current = bool::from(presented_hash.as_bytes().ct_eq(row.token_hash.as_bytes()));
        let previous = row.previous_token_hash.as_ref().is_some_and(|hash| {
            bool::from(presented_hash.as_bytes().ct_eq(hash.as_bytes()))
                && row
                    .previous_expires_at
                    .is_some_and(|deadline| stamp < deadline)
        });
        let previous_expires_at = if current {
            stamp.saturating_add(ROTATION_GRACE_MS)
        } else if previous {
            row.previous_expires_at.unwrap_or(stamp)
        } else {
            return Err(invalid());
        };
        let rotated = DeviceRow {
            expires_at: stamp.saturating_add(self.max_age_ms),
            last_used_at: stamp,
            token_hash: sha256_hex(&token),
            previous_token_hash: Some(presented_hash),
            previous_expires_at: Some(previous_expires_at),
            ..row
        };
        conn.execute(
            "UPDATE device_tokens SET token_hash=?2, previous_token_hash=?3, previous_expires_at=?4,
               expires_at=?5, last_used_at=?6 WHERE id=?1",
            params![
                rotated.id,
                rotated.token_hash,
                rotated.previous_token_hash,
                rotated.previous_expires_at,
                rotated.expires_at,
                rotated.last_used_at
            ],
        )?;
        Ok((self.summary(&rotated), token))
    }

    pub fn revoke(&self, user: &str, device_id: &str) -> ApiResult<()> {
        let removed = self.db.lock().execute(
            "DELETE FROM device_tokens WHERE id=? AND owner_user=?",
            [device_id, user],
        )?;
        if removed == 0 {
            return Err(ApiError::not_found("Device not found"));
        }
        self.disconnect(device_id);
        Ok(())
    }

    /// Whether `token` still opens its device, without touching it: the
    /// current token, or a replaced one inside its grace time. A database
    /// failure is an error, not a dead token.
    pub fn still_live(&self, token: &str) -> ApiResult<bool> {
        if !well_formed(token) {
            return Ok(false);
        }
        let hash = sha256_hex(token);
        let stamp = now_ms();
        let row = self
            .db
            .lock()
            .query_row(
                "SELECT * FROM device_tokens WHERE token_hash=?1 OR previous_token_hash=?1",
                [&hash],
                DeviceRow::from_row,
            )
            .optional()?;
        Ok(row.is_some_and(|row| {
            stamp < self.deadline(&row)
                && (row.token_hash == hash
                    || row
                        .previous_expires_at
                        .is_some_and(|deadline| stamp < deadline))
        }))
    }

    /// Call `close` when the device's token dies; dropping the guard unsubscribes.
    pub fn track(self: &Arc<Self>, device_id: &str, close: Closer) -> Tracked {
        let key = self.next_socket.fetch_add(1, Ordering::Relaxed);
        self.sockets()
            .entry(device_id.to_owned())
            .or_default()
            .insert(key, close);
        Tracked {
            devices: Arc::downgrade(self),
            device_id: device_id.to_owned(),
            key,
        }
    }
}

impl DeviceAuthenticator for DeviceTokens {
    /// The live token's device and owner; any failure is a 401 that reveals nothing.
    ///
    /// The lookup, the end of a replaced token and the touch happen under one
    /// lock of the database, so a token that a rotation replaced cannot be
    /// accepted once more after the new one's first use.
    fn authenticate(&self, token: &str) -> ApiResult<Device> {
        if !well_formed(token) {
            return Err(invalid());
        }
        let hash = sha256_hex(token);
        let stamp = now_ms();
        let (outcome, disconnect) = {
            let conn = self.db.lock();
            let row = conn
                .query_row(
                    "SELECT * FROM device_tokens WHERE token_hash=?1 OR previous_token_hash=?1",
                    [&hash],
                    DeviceRow::from_row,
                )
                .optional()?;
            match row {
                None => (Err(invalid()), None),
                Some(row) if stamp >= self.deadline(&row) => {
                    conn.execute("DELETE FROM device_tokens WHERE id=?", [&row.id])?;
                    (Err(invalid()), Some(row.id))
                }
                Some(row) => {
                    let mut disconnect = None;
                    if row.token_hash == hash {
                        // The first use of a rotated token ends the one it
                        // replaced, and the sockets that one opened: every
                        // socket tracked now was opened before this use.
                        if row.previous_token_hash.is_some() {
                            conn.execute(
                                "UPDATE device_tokens SET previous_token_hash=NULL, previous_expires_at=NULL
                                 WHERE id=?1",
                                [&row.id],
                            )?;
                            disconnect = Some(row.id.clone());
                        }
                    } else if !row
                        .previous_expires_at
                        .is_some_and(|deadline| stamp < deadline)
                    {
                        return Err(invalid());
                    }
                    if stamp - row.last_used_at >= TOUCH_INTERVAL_MS {
                        conn.execute(
                            "UPDATE device_tokens SET last_used_at=? WHERE id=?",
                            params![stamp, row.id],
                        )?;
                    }
                    (
                        Ok(Device {
                            id: row.id,
                            user: row.owner_user,
                        }),
                        disconnect,
                    )
                }
            }
        };
        // Outside the lock: closing may call back into `Tracked::drop`.
        if let Some(device_id) = disconnect {
            self.disconnect(&device_id);
        }
        outcome
    }
}

/// A tracked socket; dropping it stops tracking.
pub struct Tracked {
    devices: Weak<DeviceTokens>,
    device_id: String,
    key: u64,
}

impl Drop for Tracked {
    fn drop(&mut self) {
        let Some(devices) = self.devices.upgrade() else {
            return;
        };
        let removed = {
            let mut sockets = devices.sockets();
            let removed = sockets
                .get_mut(&self.device_id)
                .and_then(|closers| closers.remove(&self.key));
            if sockets.get(&self.device_id).is_some_and(HashMap::is_empty) {
                sockets.remove(&self.device_id);
            }
            removed
        };
        // Dropped outside the lock: it may own another `Tracked`.
        drop(removed);
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicUsize;

    use super::*;

    #[test]
    fn lifecycle() {
        let db = Arc::new(Db::memory());
        let devices = DeviceTokens::new(db.clone(), 7 * 86_400_000, 30 * 86_400_000);
        let (device, token) = devices.create("u", "Phone").unwrap();
        assert!(well_formed(&token));
        assert_eq!(device.expires_at - device.created_at, 7 * 86_400_000);
        assert_eq!(devices.authenticate(&token).unwrap().user, "u");
        assert!(devices.authenticate(&format!("{token}x")).is_err());
        assert_eq!(devices.list("u").unwrap().len(), 1);
        assert!(devices.list("v").unwrap().is_empty());

        let closed = Arc::new(AtomicUsize::new(0));
        let counter = closed.clone();
        let tracked = devices.track(
            &device.id,
            Box::new(move || {
                counter.fetch_add(1, Ordering::SeqCst);
            }),
        );
        assert_eq!(
            devices.revoke("v", &device.id).unwrap_err().code,
            "not_found"
        );
        devices.revoke("u", &device.id).unwrap();
        assert_eq!(closed.load(Ordering::SeqCst), 1);
        drop(tracked);
        assert!(devices.authenticate(&token).is_err());
    }

    #[test]
    fn rotation_keeps_the_record_and_ends_the_old_token_on_first_use() {
        let db = Arc::new(Db::memory());
        let devices = DeviceTokens::new(db.clone(), 7 * 86_400_000, 30 * 86_400_000);
        let (device, old) = devices.create("u", "Phone").unwrap();
        db.lock()
            .execute(
                "UPDATE device_tokens SET created_at=created_at-86400000, expires_at=expires_at-86400000",
                [],
            )
            .unwrap();
        let (rotated, new) = devices.rotate("u", &device.id, &old).unwrap();
        assert_eq!(
            (rotated.id.as_str(), rotated.name.as_str()),
            (device.id.as_str(), "Phone")
        );
        assert_ne!(new, old);
        let max: i64 = db
            .lock()
            .query_row("SELECT expires_at FROM device_tokens", [], |r| r.get(0))
            .unwrap();
        assert!(
            max - now_ms() > 30 * 86_400_000 - 60_000,
            "a new maximum window"
        );
        // Until the new token is used, the old one still works.
        assert_eq!(devices.authenticate(&old).unwrap().id, device.id);
        let closed = Arc::new(AtomicUsize::new(0));
        let counter = closed.clone();
        let tracked = devices.track(
            &device.id,
            Box::new(move || {
                counter.fetch_add(1, Ordering::SeqCst);
            }),
        );
        assert_eq!(devices.authenticate(&new).unwrap().id, device.id);
        assert!(
            devices.authenticate(&old).is_err(),
            "ended by the first use"
        );
        assert_eq!(closed.load(Ordering::SeqCst), 1, "its sockets closed");
        drop(tracked);
        assert!(devices.rotate("u", &device.id, &old).is_err());
        assert!(devices.rotate("v", &device.id, &new).is_err());
    }

    #[test]
    fn a_lost_rotation_can_be_asked_again_within_five_minutes() {
        let db = Arc::new(Db::memory());
        let devices = DeviceTokens::new(db.clone(), 7 * 86_400_000, 30 * 86_400_000);
        let (device, old) = devices.create("u", "Phone").unwrap();
        let (_, lost) = devices.rotate("u", &device.id, &old).unwrap();
        let (_, again) = devices.rotate("u", &device.id, &old).unwrap();
        assert!(
            devices.authenticate(&lost).is_err(),
            "never received, replaced"
        );
        assert!(devices.authenticate(&old).is_ok());
        // The grace time is not extended by asking again, and it ends.
        db.lock()
            .execute(
                "UPDATE device_tokens SET previous_expires_at=?",
                [now_ms() - 1],
            )
            .unwrap();
        let closed = Arc::new(AtomicUsize::new(0));
        let counter = closed.clone();
        let _tracked = devices.track(
            &device.id,
            Box::new(move || {
                counter.fetch_add(1, Ordering::SeqCst);
            }),
        );
        assert!(devices.authenticate(&old).is_err());
        assert!(devices.rotate("u", &device.id, &old).is_err());
        // The sweep ends the sockets the expired token opened.
        devices.sweep().unwrap();
        assert_eq!(closed.load(Ordering::SeqCst), 1);
        assert!(devices.authenticate(&again).is_ok());
    }

    #[test]
    fn limits_and_expiry() {
        let db = Arc::new(Db::memory());
        let devices = DeviceTokens::new(db.clone(), 1000, 2000);
        for index in 0..MAX_DEVICES_PER_USER {
            devices.create("u", &format!("d{index}")).unwrap();
        }
        assert_eq!(
            devices.create("u", "one more").unwrap_err().code,
            "conflict"
        );
        db.lock()
            .execute(
                "UPDATE device_tokens SET last_used_at=last_used_at-5000",
                [],
            )
            .unwrap();
        assert!(devices.list("u").unwrap().is_empty());
    }
}
