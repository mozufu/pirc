//! Pot records (plans/pots.md, Data model): create with every section at once,
//! read, update by section with a revision check, pause/resume/archive, and the
//! owner-wide settings. All queries are owner-scoped.

use rusqlite::{Connection, OptionalExtension, Row, TransactionBehavior, params};
use serde::{Deserialize, Serialize};

use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms};

/// Pots one owner may have, archived ones included.
pub const MAX_POTS: i64 = 32;
const MAX_RESPONSIBILITIES: usize = 50;
const MAX_SCOPES: usize = 100;
const MAX_LOCATIONS: usize = 50;
const MAX_FALLBACKS: usize = 19;
const MAX_WORK_MODELS: usize = 50;

fn invalid(message: &str) -> ApiError {
    ApiError::new(400, "invalid_input", message)
}

fn text(value: &str, field: &str, min: usize, max: usize) -> ApiResult<String> {
    let value = value.trim();
    let count = value.chars().count();
    if count < min || count > max {
        return Err(invalid(&format!(
            "{field} must be {min} to {max} characters"
        )));
    }
    Ok(value.to_owned())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Reach {
    Answer,
    Observe,
    Work,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DmRule {
    All,
    Selected,
    Off,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PotState {
    Active,
    Paused,
    Archived,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScopeKind {
    Project,
    Workspace,
    Session,
    Calendar,
    Schedules,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Access {
    Read,
    Write,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelMode {
    Direct,
    Ask,
}

macro_rules! text_enum {
    ($type:ty { $($variant:ident = $text:literal),* $(,)? }) => {
        impl $type {
            pub fn as_str(self) -> &'static str {
                match self { $(Self::$variant => $text),* }
            }
            pub fn parse(text: &str) -> Option<Self> {
                match text { $($text => Some(Self::$variant),)* _ => None }
            }
        }
        crate::db::sql_text_enum!($type);
    };
}
text_enum!(Reach { Answer = "answer", Observe = "observe", Work = "work" });
text_enum!(DmRule { All = "all", Selected = "selected", Off = "off" });
text_enum!(PotState { Active = "active", Paused = "paused", Archived = "archived" });
text_enum!(ScopeKind {
    Project = "project",
    Workspace = "workspace",
    Session = "session",
    Calendar = "calendar",
    Schedules = "schedules",
});
text_enum!(Access { Read = "read", Write = "write" });
text_enum!(ModelMode { Direct = "direct", Ask = "ask" });

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Profile {
    pub name: String,
    pub avatar_color: u8,
    #[serde(default)]
    pub personality: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Responsibility {
    pub title: String,
    #[serde(default)]
    pub detail: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Work {
    #[serde(default)]
    pub intro: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub responsibilities: Vec<Responsibility>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Scope {
    pub kind: ScopeKind,
    #[serde(default)]
    pub r#ref: String,
    #[serde(default)]
    pub lead: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Location {
    pub workspace_id: String,
    pub access: Access,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Dm {
    pub send: DmRule,
    pub receive: DmRule,
    /// Pots this one may message when `send` is `selected`.
    #[serde(default)]
    pub send_to: Vec<String>,
    /// Pots this one accepts messages from when `receive` is `selected`.
    #[serde(default)]
    pub receive_from: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Permissions {
    pub reach: Reach,
    #[serde(default)]
    pub observe: Vec<Scope>,
    pub dm: Dm,
    #[serde(default)]
    pub work_locations: Vec<Location>,
    pub max_concurrent_works: u32,
    /// Monthly money cap, micro-US-dollars. Required: no default spending.
    pub budget_money_month_micros: u64,
    /// Daily token cap. Required: no default spending.
    pub budget_tokens_day: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelChoice {
    pub provider: String,
    pub model: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkModel {
    pub provider: String,
    pub model: String,
    pub mode: ModelMode,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Models {
    pub main: ModelChoice,
    #[serde(default)]
    pub fallbacks: Vec<ModelChoice>,
    pub thinking: String,
    #[serde(default)]
    pub thinking_auto: bool,
    #[serde(default)]
    pub work_models: Vec<WorkModel>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Autonomy {
    /// Seconds between autonomy reviews; `None` turns them off.
    pub interval_s: Option<u64>,
}

/// Everything a pot is created with (the four steps of the design).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PotInput {
    pub profile: Profile,
    pub work: Work,
    pub permissions: Permissions,
    pub models: Models,
    #[serde(default = "default_autonomy")]
    pub autonomy: Autonomy,
}

fn default_autonomy() -> Autonomy {
    Autonomy {
        interval_s: Some(172_800),
    }
}

/// A partial update: each present section replaces that section whole.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PotPatch {
    pub revision: i64,
    pub profile: Option<Profile>,
    pub work: Option<Work>,
    pub permissions: Option<Permissions>,
    pub models: Option<Models>,
    pub autonomy: Option<Autonomy>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Pot {
    pub id: String,
    pub state: PotState,
    pub revision: i64,
    pub created_at: i64,
    pub updated_at: i64,
    pub session_id: Option<String>,
    #[serde(flatten)]
    pub input: PotInput,
}

pub const THINKING: [&str; 6] = ["off", "minimal", "low", "medium", "high", "xhigh"];

impl PotInput {
    /// Shape and limits only; whether models, workspaces and peers exist is
    /// checked against the owner's data by [`validate_references`].
    fn normalize(mut self) -> ApiResult<Self> {
        let p = &mut self.profile;
        p.name = text(&p.name, "name", 1, 40)?;
        if !(1..=5).contains(&p.avatar_color) {
            return Err(invalid("avatarColor must be 1 to 5"));
        }
        p.personality = text(&p.personality, "personality", 0, 8000)?;
        let w = &mut self.work;
        w.intro = text(&w.intro, "intro", 0, 200)?;
        w.description = text(&w.description, "description", 0, 8000)?;
        if w.responsibilities.len() > MAX_RESPONSIBILITIES {
            return Err(invalid("Too many responsibilities"));
        }
        for r in &mut w.responsibilities {
            r.title = text(&r.title, "responsibility title", 1, 200)?;
            r.detail = text(&r.detail, "responsibility detail", 0, 2000)?;
        }
        let perm = &self.permissions;
        if perm.observe.len() > MAX_SCOPES || perm.work_locations.len() > MAX_LOCATIONS {
            return Err(invalid("Too many scopes or work locations"));
        }
        if perm.max_concurrent_works > 16 {
            return Err(invalid("maxConcurrentWorks must be 0 to 16"));
        }
        if perm.reach != Reach::Work && !perm.work_locations.is_empty() {
            return Err(invalid("Only a pot that may start work has work locations"));
        }
        if perm.reach == Reach::Answer && !perm.observe.is_empty() {
            return Err(invalid("A pot that only answers observes nothing"));
        }
        for scope in &perm.observe {
            let global = matches!(scope.kind, ScopeKind::Calendar | ScopeKind::Schedules);
            if global != scope.r#ref.is_empty() || scope.r#ref.len() > 256 {
                return Err(invalid(
                    "Observe scopes name a source, except calendar and schedules",
                ));
            }
        }
        let m = &self.models;
        if m.fallbacks.len() > MAX_FALLBACKS || m.work_models.len() > MAX_WORK_MODELS {
            return Err(invalid("Too many models"));
        }
        if !THINKING.contains(&m.thinking.as_str()) {
            return Err(invalid("Unknown thinking level"));
        }
        if self.permissions.reach != Reach::Work && !m.work_models.is_empty() {
            return Err(invalid("Only a pot that may start work has work models"));
        }
        if let Some(interval) = self.autonomy.interval_s
            && !(3_600..=31_536_000).contains(&interval)
        {
            return Err(invalid("The autonomy interval is 1 hour to 1 year, or off"));
        }
        Ok(self)
    }
}

/// Peers must be the owner's other pots; locations known workspaces (the API
/// also checks the owner can see them).
fn validate_references(
    conn: &Connection,
    owner: &str,
    pot_id: Option<&str>,
    input: &PotInput,
) -> ApiResult<()> {
    let dm = &input.permissions.dm;
    for peer in dm.send_to.iter().chain(&dm.receive_from) {
        let owned: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM pots WHERE id=?1 AND owner_user=?2)",
            params![peer, owner],
            |r| r.get(0),
        )?;
        if !owned || Some(peer.as_str()) == pot_id {
            return Err(invalid("Message peers must be your other pots"));
        }
    }
    for location in &input.permissions.work_locations {
        let owned: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM workspaces WHERE id=?1)",
            [&location.workspace_id],
            |r| r.get(0),
        )?;
        if !owned {
            return Err(invalid("Work locations must be your workspaces"));
        }
    }
    Ok(())
}

fn write_sections(conn: &Connection, id: &str, input: &PotInput, replace: bool) -> ApiResult<()> {
    if replace {
        for table in [
            "pot_responsibilities",
            "pot_observe_scopes",
            "pot_dm_peers",
            "pot_work_locations",
            "pot_models",
            "pot_work_models",
        ] {
            conn.execute(&format!("DELETE FROM {table} WHERE pot_id=?1"), [id])?;
        }
    }
    for (position, r) in input.work.responsibilities.iter().enumerate() {
        conn.execute(
            "INSERT INTO pot_responsibilities(id,pot_id,title,detail,position) VALUES(?1,?2,?3,?4,?5)",
            params![new_id("resp"), id, r.title, r.detail, position as i64],
        )?;
    }
    let perm = &input.permissions;
    conn.execute(
        "INSERT INTO pot_permissions(pot_id,reach,dm_send,dm_receive,max_concurrent_works,
          budget_money_month_micros,budget_tokens_day) VALUES(?1,?2,?3,?4,?5,?6,?7)
         ON CONFLICT(pot_id) DO UPDATE SET reach=excluded.reach,dm_send=excluded.dm_send,
          dm_receive=excluded.dm_receive,max_concurrent_works=excluded.max_concurrent_works,
          budget_money_month_micros=excluded.budget_money_month_micros,
          budget_tokens_day=excluded.budget_tokens_day",
        params![
            id,
            perm.reach,
            perm.dm.send,
            perm.dm.receive,
            perm.max_concurrent_works,
            perm.budget_money_month_micros as i64,
            perm.budget_tokens_day as i64,
        ],
    )?;
    for scope in &perm.observe {
        conn.execute(
            "INSERT OR REPLACE INTO pot_observe_scopes(pot_id,kind,ref,lead) VALUES(?1,?2,?3,?4)",
            params![id, scope.kind, scope.r#ref, scope.lead],
        )?;
    }
    for (peers, direction) in [
        (&perm.dm.send_to, "send"),
        (&perm.dm.receive_from, "receive"),
    ] {
        for peer in peers {
            conn.execute(
                "INSERT OR IGNORE INTO pot_dm_peers(pot_id,peer_pot_id,direction) VALUES(?1,?2,?3)",
                params![id, peer, direction],
            )?;
        }
    }
    for location in &perm.work_locations {
        conn.execute(
            "INSERT OR REPLACE INTO pot_work_locations(pot_id,workspace_id,access) VALUES(?1,?2,?3)",
            params![id, location.workspace_id, location.access],
        )?;
    }
    let models = &input.models;
    for (position, choice) in std::iter::once(&models.main)
        .chain(&models.fallbacks)
        .enumerate()
    {
        conn.execute(
            "INSERT INTO pot_models(pot_id,position,provider,model) VALUES(?1,?2,?3,?4)",
            params![id, position as i64, choice.provider, choice.model],
        )?;
    }
    for work in &models.work_models {
        conn.execute(
            "INSERT OR REPLACE INTO pot_work_models(pot_id,provider,model,mode) VALUES(?1,?2,?3,?4)",
            params![id, work.provider, work.model, work.mode],
        )?;
    }
    conn.execute(
        "INSERT INTO pot_runtime(pot_id,thinking,thinking_auto,autonomy_interval_s) VALUES(?1,?2,?3,?4)
         ON CONFLICT(pot_id) DO UPDATE SET thinking=excluded.thinking,
          thinking_auto=excluded.thinking_auto,autonomy_interval_s=excluded.autonomy_interval_s",
        params![
            id,
            models.thinking,
            models.thinking_auto,
            input.autonomy.interval_s.map(|s| s as i64),
        ],
    )?;
    Ok(())
}

pub fn create(conn: &mut Connection, owner: &str, input: PotInput) -> ApiResult<Pot> {
    let input = input.normalize()?;
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let count: i64 = tx.query_row(
        "SELECT count(*) FROM pots WHERE owner_user=?1",
        [owner],
        |r| r.get(0),
    )?;
    if count >= MAX_POTS {
        return Err(ApiError::new(
            409,
            "limit_reached",
            "You have the most pots allowed",
        ));
    }
    validate_references(&tx, owner, None, &input)?;
    let id = new_id("pot");
    let stamp = now_ms();
    let p = &input.profile;
    tx.execute(
        "INSERT INTO pots(id,owner_user,name,avatar_color,personality,intro,work_description,created_at,updated_at)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?8)",
        params![id, owner, p.name, p.avatar_color, p.personality, input.work.intro, input.work.description, stamp],
    )?;
    write_sections(&tx, &id, &input, false)?;
    let pot = read(&tx, owner, &id)?;
    tx.commit()?;
    Ok(pot)
}

fn base(row: &Row) -> rusqlite::Result<(Pot, String)> {
    Ok((
        Pot {
            id: row.get(0)?,
            state: row.get(1)?,
            revision: row.get(2)?,
            created_at: row.get(3)?,
            updated_at: row.get(4)?,
            session_id: row.get(5)?,
            input: PotInput {
                profile: Profile {
                    name: row.get(6)?,
                    avatar_color: row.get(7)?,
                    personality: row.get(8)?,
                },
                work: Work {
                    intro: row.get(9)?,
                    description: row.get(10)?,
                    responsibilities: Vec::new(),
                },
                permissions: Permissions {
                    reach: row.get(11)?,
                    observe: Vec::new(),
                    dm: Dm {
                        send: row.get(12)?,
                        receive: row.get(13)?,
                        send_to: Vec::new(),
                        receive_from: Vec::new(),
                    },
                    work_locations: Vec::new(),
                    max_concurrent_works: row.get(14)?,
                    budget_money_month_micros: row.get::<_, i64>(15)? as u64,
                    budget_tokens_day: row.get::<_, i64>(16)? as u64,
                },
                models: Models {
                    main: ModelChoice {
                        provider: String::new(),
                        model: String::new(),
                    },
                    fallbacks: Vec::new(),
                    thinking: row.get(17)?,
                    thinking_auto: row.get(18)?,
                    work_models: Vec::new(),
                },
                autonomy: Autonomy {
                    interval_s: row.get::<_, Option<i64>>(19)?.map(|s| s as u64),
                },
            },
        },
        row.get(20)?,
    ))
}

const SELECT: &str = "SELECT p.id,p.state,p.revision,p.created_at,p.updated_at,r.session_id,
  p.name,p.avatar_color,p.personality,p.intro,p.work_description,
  m.reach,m.dm_send,m.dm_receive,m.max_concurrent_works,m.budget_money_month_micros,m.budget_tokens_day,
  r.thinking,r.thinking_auto,r.autonomy_interval_s,p.owner_user
  FROM pots p JOIN pot_permissions m ON m.pot_id=p.id JOIN pot_runtime r ON r.pot_id=p.id";

fn fill(conn: &Connection, pot: &mut Pot) -> rusqlite::Result<()> {
    let id = pot.id.clone();
    let input = &mut pot.input;
    input.work.responsibilities = conn
        .prepare("SELECT title,detail FROM pot_responsibilities WHERE pot_id=?1 ORDER BY position")?
        .query_map([&id], |r| {
            Ok(Responsibility {
                title: r.get(0)?,
                detail: r.get(1)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    input.permissions.observe = conn
        .prepare("SELECT kind,ref,lead FROM pot_observe_scopes WHERE pot_id=?1 ORDER BY kind,ref")?
        .query_map([&id], |r| {
            Ok(Scope {
                kind: r.get(0)?,
                r#ref: r.get(1)?,
                lead: r.get(2)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    let peers = |direction: &str| -> rusqlite::Result<Vec<String>> {
        conn.prepare(
            "SELECT peer_pot_id FROM pot_dm_peers WHERE pot_id=?1 AND direction=?2 ORDER BY peer_pot_id",
        )?
        .query_map(params![id, direction], |r| r.get(0))?
        .collect()
    };
    input.permissions.dm.send_to = peers("send")?;
    input.permissions.dm.receive_from = peers("receive")?;
    input.permissions.work_locations = conn
        .prepare("SELECT workspace_id,access FROM pot_work_locations WHERE pot_id=?1 ORDER BY workspace_id")?
        .query_map([&id], |r| {
            Ok(Location {
                workspace_id: r.get(0)?,
                access: r.get(1)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    let mut models: Vec<ModelChoice> = conn
        .prepare("SELECT provider,model FROM pot_models WHERE pot_id=?1 ORDER BY position")?
        .query_map([&id], |r| {
            Ok(ModelChoice {
                provider: r.get(0)?,
                model: r.get(1)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    if !models.is_empty() {
        input.models.main = models.remove(0);
    }
    input.models.fallbacks = models;
    input.models.work_models = conn
        .prepare("SELECT provider,model,mode FROM pot_work_models WHERE pot_id=?1 ORDER BY provider,model")?
        .query_map([&id], |r| {
            Ok(WorkModel {
                provider: r.get(0)?,
                model: r.get(1)?,
                mode: r.get(2)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(())
}

fn not_found() -> ApiError {
    ApiError::not_found("Pot not found")
}

pub fn read(conn: &Connection, owner: &str, id: &str) -> ApiResult<Pot> {
    let found = conn
        .query_row(
            &format!("{SELECT} WHERE p.id=?1 AND p.owner_user=?2"),
            params![id, owner],
            base,
        )
        .optional()?;
    let (mut pot, _) = found.ok_or_else(not_found)?;
    fill(conn, &mut pot)?;
    Ok(pot)
}

pub fn list(conn: &Connection, owner: &str) -> ApiResult<Vec<Pot>> {
    let rows: Vec<(Pot, String)> = conn
        .prepare(&format!(
            "{SELECT} WHERE p.owner_user=?1 ORDER BY p.created_at, p.id"
        ))?
        .query_map([owner], base)?
        .collect::<Result<_, _>>()?;
    let mut pots = Vec::with_capacity(rows.len());
    for (mut pot, _) in rows {
        fill(conn, &mut pot)?;
        pots.push(pot);
    }
    Ok(pots)
}

fn conflict() -> ApiError {
    ApiError::new(
        409,
        "revision_conflict",
        "The pot changed; reload it and try again",
    )
}

pub fn update(conn: &mut Connection, owner: &str, id: &str, patch: PotPatch) -> ApiResult<Pot> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current = read(&tx, owner, id)?;
    if current.revision != patch.revision {
        return Err(conflict());
    }
    if current.state == PotState::Archived {
        return Err(ApiError::new(
            409,
            "pot_archived",
            "Restore the pot before changing it",
        ));
    }
    let mut input = current.input.clone();
    if let Some(profile) = patch.profile {
        input.profile = profile;
    }
    if let Some(work) = patch.work {
        input.work = work;
    }
    if let Some(permissions) = patch.permissions {
        input.permissions = permissions;
    }
    if let Some(models) = patch.models {
        input.models = models;
    }
    if let Some(autonomy) = patch.autonomy {
        input.autonomy = autonomy;
    }
    let input = input.normalize()?;
    validate_references(&tx, owner, Some(id), &input)?;
    let p = &input.profile;
    tx.execute(
        "UPDATE pots SET name=?1,avatar_color=?2,personality=?3,intro=?4,work_description=?5,
          revision=revision+1,updated_at=?6 WHERE id=?7 AND owner_user=?8",
        params![
            p.name,
            p.avatar_color,
            p.personality,
            input.work.intro,
            input.work.description,
            now_ms(),
            id,
            owner
        ],
    )?;
    write_sections(&tx, id, &input, true)?;
    let pot = read(&tx, owner, id)?;
    tx.commit()?;
    Ok(pot)
}

/// Pause, resume, archive or restore. Archived pots are restored to paused.
pub fn set_state(
    conn: &mut Connection,
    owner: &str,
    id: &str,
    revision: i64,
    to: PotState,
) -> ApiResult<Pot> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current = read(&tx, owner, id)?;
    if current.revision != revision {
        return Err(conflict());
    }
    let allowed = matches!(
        (current.state, to),
        (PotState::Active, PotState::Paused)
            | (PotState::Paused, PotState::Active)
            | (PotState::Active | PotState::Paused, PotState::Archived)
            | (PotState::Archived, PotState::Paused)
    );
    if !allowed {
        return Err(ApiError::new(
            409,
            "invalid_transition",
            "The pot cannot change to that state",
        ));
    }
    tx.execute(
        "UPDATE pots SET state=?1,revision=revision+1,updated_at=?2 WHERE id=?3 AND owner_user=?4",
        params![to, now_ms(), id, owner],
    )?;
    let pot = read(&tx, owner, id)?;
    tx.commit()?;
    Ok(pot)
}

/// Owner-wide pot settings.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Settings {
    pub cap_money_month_micros: u64,
    pub cap_tokens_day: u64,
    pub on_exhausted: String,
    pub activity_retention_days: u32,
    pub count_subscription_money: bool,
    pub loop_depth: u32,
    pub loop_fanout: u32,
    pub loop_no_progress_wakes: u32,
    pub loop_no_progress_messages: u32,
    pub handback_cooldown_s: u32,
    #[serde(default)]
    pub revision: i64,
}

pub fn settings(conn: &Connection, owner: &str) -> ApiResult<Settings> {
    conn.execute(
        "INSERT OR IGNORE INTO pot_settings(owner_user) VALUES(?1)",
        [owner],
    )?;
    Ok(conn.query_row(
        "SELECT cap_money_month_micros,cap_tokens_day,on_exhausted,activity_retention_days,
          count_subscription_money,loop_depth,loop_fanout,loop_no_progress_wakes,
          loop_no_progress_messages,handback_cooldown_s,revision FROM pot_settings WHERE owner_user=?1",
        [owner],
        |r| {
            Ok(Settings {
                cap_money_month_micros: r.get::<_, i64>(0)? as u64,
                cap_tokens_day: r.get::<_, i64>(1)? as u64,
                on_exhausted: r.get(2)?,
                activity_retention_days: r.get(3)?,
                count_subscription_money: r.get(4)?,
                loop_depth: r.get(5)?,
                loop_fanout: r.get(6)?,
                loop_no_progress_wakes: r.get(7)?,
                loop_no_progress_messages: r.get(8)?,
                handback_cooldown_s: r.get(9)?,
                revision: r.get(10)?,
            })
        },
    )?)
}

pub fn update_settings(conn: &mut Connection, owner: &str, next: Settings) -> ApiResult<Settings> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current = settings(&tx, owner)?;
    if current.revision != next.revision {
        return Err(conflict());
    }
    let changed = tx.execute(
        "UPDATE pot_settings SET cap_money_month_micros=?1,cap_tokens_day=?2,on_exhausted=?3,
          activity_retention_days=?4,count_subscription_money=?5,loop_depth=?6,loop_fanout=?7,
          loop_no_progress_wakes=?8,loop_no_progress_messages=?9,handback_cooldown_s=?10,
          revision=revision+1 WHERE owner_user=?11",
        params![
            next.cap_money_month_micros as i64,
            next.cap_tokens_day as i64,
            next.on_exhausted,
            next.activity_retention_days,
            next.count_subscription_money,
            next.loop_depth,
            next.loop_fanout,
            next.loop_no_progress_wakes,
            next.loop_no_progress_messages,
            next.handback_cooldown_s,
            owner,
        ],
    );
    // The table's CHECK constraints are the range rules.
    if let Err(rusqlite::Error::SqliteFailure(failure, _)) = &changed
        && failure.code == rusqlite::ErrorCode::ConstraintViolation
    {
        return Err(invalid("A setting is out of range"));
    }
    changed?;
    let out = settings(&tx, owner)?;
    tx.commit()?;
    Ok(out)
}
