//! Notification preferences per push target (plans/roadmap.md M8 defaults C
//! and D): a level per category, quiet hours, the target's time zone, what
//! the lock screen shows and the time of the daily summary. The Gateway
//! applies them before it sends anything, so a muted category is never sent.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::calendar::recurrence::{instant, wall};
use crate::error::{ApiError, ApiResult};
use crate::schedules::Zone;

/// What a notification is about (design D20).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Category {
    /// Agent questions, missed or stuck runs, model approvals, budget
    /// requests and handovers.
    NeedsYou,
    /// A completed schedule, a pot's reply, an observation notification.
    Done,
    /// A pot opening work, work progress.
    Progress,
    /// Calendar reminders.
    Calendar,
}

impl Category {
    pub const ALL: [Self; 4] = [Self::NeedsYou, Self::Done, Self::Progress, Self::Calendar];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::NeedsYou => "needs_you",
            Self::Done => "done",
            Self::Progress => "progress",
            Self::Calendar => "calendar",
        }
    }

    fn default_level(self) -> Level {
        match self {
            Self::NeedsYou | Self::Calendar => Level::Immediate,
            Self::Done => Level::Digest,
            Self::Progress => Level::Off,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Level {
    Immediate,
    Digest,
    Off,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LockScreen {
    Hidden,
    Title,
    Full,
}

impl LockScreen {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Hidden => "hidden",
            Self::Title => "title",
            Self::Full => "full",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "hidden" => Some(Self::Hidden),
            "title" => Some(Self::Title),
            "full" => Some(Self::Full),
            _ => None,
        }
    }
}

/// A local time of day, `HH:MM`, as minutes after midnight.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClockTime(u32);

impl ClockTime {
    pub const DIGEST_DEFAULT: Self = Self(18 * 60);

    pub fn parse(text: &str) -> Option<Self> {
        let (hours, minutes) = text.split_once(':')?;
        let digits = |part: &str| {
            (part.len() == 2 && part.bytes().all(|b| b.is_ascii_digit()))
                .then(|| part.parse::<u32>().ok())
                .flatten()
        };
        let (hours, minutes) = (digits(hours)?, digits(minutes)?);
        (hours < 24 && minutes < 60).then_some(Self(hours * 60 + minutes))
    }

    pub fn text(self) -> String {
        format!("{:02}:{:02}", self.0 / 60, self.0 % 60)
    }
}

impl Serialize for ClockTime {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.text())
    }
}

impl<'de> Deserialize<'de> for ClockTime {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        Self::parse(&text).ok_or_else(|| serde::de::Error::custom("expected HH:MM"))
    }
}

/// Quiet hours; `end` before `start` crosses midnight.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct QuietHours {
    pub start: ClockTime,
    pub end: ClockTime,
}

impl QuietHours {
    fn contains(self, minute: u32) -> bool {
        let (start, end) = (self.start.0, self.end.0);
        if start < end {
            (start..end).contains(&minute)
        } else {
            minute >= start || minute < end
        }
    }
}

/// One target's settings.
#[derive(Clone, Debug, PartialEq)]
pub struct Preferences {
    pub levels: BTreeMap<Category, Level>,
    pub quiet_hours: Option<QuietHours>,
    pub time_zone: String,
    pub lock_screen: LockScreen,
    pub digest_at: ClockTime,
}

/// What to do with one notification for one target.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    Send,
    /// Sent without sound or vibration (`needs_you` during quiet hours).
    SendSilent,
    /// Kept for the summary at the end of quiet hours.
    Hold,
    /// Kept for the next summary (level `digest`).
    Digest,
    Skip,
}

/// The stored levels, each category falling back to its default.
pub fn levels_from_json(text: &str) -> BTreeMap<Category, Level> {
    let stored: BTreeMap<Category, Level> = serde_json::from_str(text).unwrap_or_default();
    Category::ALL
        .into_iter()
        .map(|category| {
            (
                category,
                stored
                    .get(&category)
                    .copied()
                    .unwrap_or(category.default_level()),
            )
        })
        .collect()
}

impl Preferences {
    pub fn zone(&self) -> Zone {
        Zone::parse(&self.time_zone).unwrap_or(Zone::Fixed(0))
    }

    pub fn level(&self, category: Category) -> Level {
        self.levels
            .get(&category)
            .copied()
            .unwrap_or(category.default_level())
    }

    /// Whether `now` is inside the quiet hours.
    pub fn quiet_at(&self, now: i64) -> bool {
        let Some(quiet) = self.quiet_hours else {
            return false;
        };
        wall(now, self.zone()).is_ok_and(|local| {
            use chrono::Timelike;
            quiet.contains(local.hour() * 60 + local.minute())
        })
    }

    /// What to do with a notification of `category`. An update to a
    /// notification (an answered question) goes only where the question went
    /// on its own (level `immediate`), silently during quiet hours; it is
    /// never kept for a summary.
    pub fn decide(&self, category: Category, update: bool, now: i64) -> Decision {
        let level = self.level(category);
        if level == Level::Off {
            return Decision::Skip;
        }
        if update {
            return match (level, self.quiet_at(now)) {
                (Level::Digest, _) => Decision::Skip,
                (_, true) => Decision::SendSilent,
                _ => Decision::Send,
            };
        }
        if level == Level::Digest {
            return Decision::Digest;
        }
        if !self.quiet_at(now) {
            return Decision::Send;
        }
        match category {
            Category::NeedsYou => Decision::SendSilent,
            // The user set the reminder for this time.
            Category::Calendar => Decision::Send,
            Category::Done | Category::Progress => Decision::Hold,
        }
    }

    /// The latest instant at or before `now` whose local time is `at`.
    fn last_moment(&self, at: ClockTime, now: i64) -> Option<i64> {
        let zone = self.zone();
        let local = wall(now, zone).ok()?;
        let time = chrono::NaiveTime::from_hms_opt(at.0 / 60, at.0 % 60, 0)?;
        let today = instant(local.date().and_time(time), zone);
        if today <= now {
            return Some(today);
        }
        let yesterday = local.date().pred_opt()?.and_time(time);
        Some(instant(yesterday, zone))
    }

    /// Whether a summary is due: a digest time or an end of quiet hours
    /// passed after `mark` (also while the Gateway was offline), and quiet
    /// hours are not on now.
    pub fn summary_due(&self, mark: i64, now: i64) -> bool {
        if self.quiet_at(now) {
            return false;
        }
        let digest = self.last_moment(self.digest_at, now);
        let quiet_end = self
            .quiet_hours
            .and_then(|quiet| self.last_moment(quiet.end, now));
        digest
            .into_iter()
            .chain(quiet_end)
            .any(|moment| moment > mark)
    }
}

/// A `PATCH /api/push/subscriptions/{id}` body: the revision it was read at
/// and the settings to change.
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PreferencesPatch {
    pub revision: i64,
    #[serde(default, deserialize_with = "crate::util::present")]
    pub levels: Option<BTreeMap<Category, Level>>,
    /// `null` turns quiet hours off.
    #[serde(default, deserialize_with = "crate::util::present")]
    pub quiet_hours: Option<Option<QuietHours>>,
    #[serde(default, deserialize_with = "crate::util::present")]
    pub time_zone: Option<String>,
    #[serde(default, deserialize_with = "crate::util::present")]
    pub lock_screen: Option<LockScreen>,
    #[serde(default, deserialize_with = "crate::util::present")]
    pub digest_at: Option<ClockTime>,
}

impl PreferencesPatch {
    /// `current` with this patch applied, or why it cannot be.
    pub fn apply(&self, current: &Preferences) -> ApiResult<Preferences> {
        let mut next = current.clone();
        if let Some(levels) = &self.levels {
            next.levels.extend(levels.iter().map(|(c, l)| (*c, *l)));
        }
        if let Some(quiet) = self.quiet_hours {
            if quiet.is_some_and(|quiet| quiet.start == quiet.end) {
                return Err(ApiError::new(
                    400,
                    "invalid_input",
                    "Quiet hours need a start and an end that differ",
                ));
            }
            next.quiet_hours = quiet;
        }
        if let Some(zone) = &self.time_zone {
            if zone.len() > 64 || Zone::parse(zone).is_none() {
                return Err(ApiError::new(400, "invalid_input", "Unknown time zone"));
            }
            next.time_zone = zone.clone();
        }
        if let Some(lock_screen) = self.lock_screen {
            next.lock_screen = lock_screen;
        }
        if let Some(digest_at) = self.digest_at {
            next.digest_at = digest_at;
        }
        Ok(next)
    }
}
