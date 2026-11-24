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

use crate::auth::{Device, DeviceAuthenticator};
use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms, random_bytes, sha256_hex};

pub const DEVICE_TOKEN_PREFIX: &str = "pirc_dev_";
const MAX_DEVICES_PER_USER: usize = 10;
/// `last_used_at` is written at most this often per token.
const TOUCH_INTERVAL_MS: i64 = 60_000;
const SWEEP_INTERVAL: Duration = Duration::from_secs(60);

/// What a device's owner sees of it.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceSummary {
    pub id: String,
    pub name: String,
    pub created_at: i64,
    pub last_used_at: i64,
    /// When the token dies if it is not used again (idle or absolute limit).
    pub expires_at: i64,
}

struct DeviceRow {
    id: String,
    owner_user: String,
    name: String,
    created_at: i64,
    expires_at: i64,
    last_used_at: i64,
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
        })
    }
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
        let token = format!(
            "{DEVICE_TOKEN_PREFIX}{}",
            URL_SAFE_NO_PAD.encode(random_bytes::<32>())
        );
        let stamp = now_ms();
        let row = DeviceRow {
            id: new_id("dev"),
            owner_user: user.to_owned(),
            name: name.to_owned(),
            created_at: stamp,
            expires_at: stamp.saturating_add(self.max_age_ms),
            last_used_at: stamp,
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
                sha256_hex(&token),
                row.created_at,
                row.expires_at,
                row.last_used_at
            ],
        )?;
        Ok((self.summary(&row), token))
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
    fn authenticate(&self, token: &str) -> ApiResult<Device> {
        if !well_formed(token) {
            return Err(invalid());
        }
        let row = {
            let conn = self.db.lock();
            conn.query_row(
                "SELECT * FROM device_tokens WHERE token_hash=?",
                [sha256_hex(token)],
                DeviceRow::from_row,
            )
            .optional()?
        };
        let Some(row) = row else {
            return Err(invalid());
        };
        let stamp = now_ms();
        if stamp >= self.deadline(&row) {
            self.db
                .lock()
                .execute("DELETE FROM device_tokens WHERE id=?", [&row.id])?;
            self.disconnect(&row.id);
            return Err(invalid());
        }
        if stamp - row.last_used_at >= TOUCH_INTERVAL_MS {
            self.db.lock().execute(
                "UPDATE device_tokens SET last_used_at=? WHERE id=?",
                params![stamp, row.id],
            )?;
        }
        Ok(Device {
            id: row.id,
            user: row.owner_user,
        })
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
