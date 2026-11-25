//! Text as memory compares and stores it: JavaScript whitespace, NFKC
//! folding, UTF-16 clipping and local time stamps.

use std::sync::LazyLock;

use icu_normalizer::ComposingNormalizerBorrowed;
use pirc_config::text::is_space as js_space;
use tz::TimeZone;
use tz::timezone::TimeZoneSettings;

use crate::util::sha256_hex;

/// `text.replace(/\s+/g, ' ').trim()`.
pub fn squash(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut space = false;
    for c in text.chars() {
        if js_space(c) {
            space = true;
            continue;
        }
        if space && !out.is_empty() {
            out.push(' ');
        }
        space = false;
        out.push(c);
    }
    out
}

/// `text.split(/\s+/).filter(Boolean)`.
pub fn words(text: &str) -> impl Iterator<Item = &str> {
    text.split(js_space).filter(|word| !word.is_empty())
}

/// `text.normalize('NFKC').toLowerCase()`.
pub fn fold(text: &str) -> String {
    ComposingNormalizerBorrowed::new_nfkc()
        .normalize(text)
        .to_lowercase()
}

/// Hash that ignores case, width and spacing (`contentHash`).
pub fn content_hash(text: &str) -> String {
    sha256_hex(squash(&fold(text)))
}

/// `text.slice(0, max - 1).trimEnd() + '…'` when longer than `max` UTF-16 units.
pub fn clip(text: &str, max: usize) -> String {
    let units: Vec<u16> = text.encode_utf16().collect();
    if units.len() <= max {
        return text.to_owned();
    }
    let head = String::from_utf16_lossy(&units[..max.saturating_sub(1)]);
    format!("{}…", head.trim_end_matches(js_space))
}

/// `1234567` as `toLocaleString('en-US')` writes it: `1,234,567`.
pub fn grouped(number: i64) -> String {
    let digits = number.unsigned_abs().to_string();
    let mut out = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    if number < 0 { format!("-{out}") } else { out }
}

/// The process's time zone, as JavaScript's `Date` uses it: `$TZ` (a zone
/// name, `:path` or POSIX rule), else `/etc/localtime`, else UTC. Zone files
/// come from the system (`$TZDIR` first).
static LOCAL: LazyLock<Option<TimeZone>> = LazyLock::new(|| {
    let tzdir = std::env::var("TZDIR").ok();
    let mut directories: Vec<&str> = tzdir.iter().map(String::as_str).collect();
    directories.extend(TimeZoneSettings::DEFAULT_DIRECTORIES);
    let settings = TimeZoneSettings::new(&directories, TimeZoneSettings::DEFAULT_READ_FILE_FN);
    match std::env::var("TZ") {
        Ok(tz) => settings.parse_posix_tz(&tz).ok(),
        Err(_) => settings.parse_local().ok(),
    }
});

/// Seconds east of UTC of local time at `unix` seconds.
fn offset_at(unix: i64) -> i64 {
    LOCAL
        .as_ref()
        .and_then(|zone| zone.find_local_time_type(unix).ok())
        .map_or(0, |kind| i64::from(kind.ut_offset()))
}

/// Days since 1970-01-01 of a proleptic Gregorian date.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let of_era = year - era * 400;
    let of_year = (153 * ((month + 9) % 12) + 2) / 5 + day - 1;
    let of_era_days = of_era * 365 + of_era / 4 - of_era / 100 + of_year;
    era * 146_097 + of_era_days - 719_468
}

static ISO: LazyLock<regex_lite::Regex> = LazyLock::new(|| {
    regex_lite::Regex::new(
        r"^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(Z|[+-]\d{2}:\d{2})?)?$",
    )
    .expect("ISO date pattern")
});

/// `Date.parse` of an ISO date or date-time: a date alone is UTC, a time
/// without an offset local. `None` for anything else.
pub fn parse_date(text: &str) -> Option<i64> {
    let parts = ISO.captures(text)?;
    let number = |index: usize| -> Option<i64> {
        parts
            .get(index)
            .map_or(Some(0), |part| part.as_str().parse().ok())
    };
    let (year, month, day) = (number(1)?, number(2)?, number(3)?);
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let month_days = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    if !(1..=12).contains(&month) || day < 1 || day > month_days[(month - 1) as usize] {
        return None;
    }
    let days = days_from_civil(year, month, day);
    if parts.get(4).is_none() {
        return Some(days * 86_400_000);
    }
    let (hour, minute, second) = (number(4)?, number(5)?, number(6)?);
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let millis: i64 = parts.get(7).map_or(Some(0), |fraction| {
        let digits: String = fraction
            .as_str()
            .chars()
            .chain("00".chars())
            .take(3)
            .collect();
        digits.parse().ok()
    })?;
    let naive = days * 86_400 + hour * 3600 + minute * 60 + second;
    let unix = match parts.get(8).map(|zone| zone.as_str()) {
        Some("Z") => naive,
        Some(offset) => {
            let sign = if offset.starts_with('-') { -1 } else { 1 };
            let hours: i64 = offset[1..3].parse().ok()?;
            let minutes: i64 = offset[4..6].parse().ok()?;
            naive - sign * (hours * 3600 + minutes * 60)
        }
        // The earliest instant showing this local time; in a gap (clocks
        // moved forward), the offset before it.
        None => {
            let before = offset_at(naive - 86_400);
            let after = offset_at(naive + 86_400);
            [before, after]
                .into_iter()
                .map(|offset| naive - offset)
                .filter(|unix| naive - offset_at(*unix) == *unix)
                .min()
                .unwrap_or(naive - before)
        }
    };
    Some(unix * 1000 + millis)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whitespace_and_hashes() {
        assert_eq!(squash("  a \n\u{a0} b\t"), "a b");
        assert_eq!(squash(""), "");
        assert_eq!(
            words(" a  b\u{3000}c ").collect::<Vec<_>>(),
            ["a", "b", "c"]
        );
        assert_eq!(
            content_hash("Ｈas  TWO cats."),
            content_hash("has two cats.")
        );
        assert_ne!(content_hash("two cats"), content_hash("three cats"));
        assert_eq!(fold("ＡＢＣ"), "abc");
    }

    #[test]
    fn clipping_and_numbers() {
        assert_eq!(clip("abcdef", 6), "abcdef");
        assert_eq!(clip("abc defg", 5), "abc…");
        assert_eq!(grouped(8000), "8,000");
        assert_eq!(grouped(123), "123");
        assert_eq!(grouped(1_234_567), "1,234,567");
    }

    #[test]
    fn dates() {
        assert_eq!(parse_date("2026-09-27"), Some(1_790_467_200_000));
        assert_eq!(parse_date("2026-09-27T10:00Z"), Some(1_790_503_200_000));
        assert_eq!(
            parse_date("2026-09-27T12:00+02:00"),
            Some(1_790_503_200_000)
        );
        assert_eq!(parse_date("2026-13-27T10:00"), None);
        assert_eq!(parse_date("yesterday"), None);
        assert!(parse_date("2026-09-27T10:00").is_some());
        assert_eq!(parse_date("2026-02-29"), None);
        assert_eq!(parse_date("2024-02-29"), Some(1_709_164_800_000));
        assert_eq!(parse_date("1969-12-31T23:59:59.5Z"), Some(-500));
    }
}
