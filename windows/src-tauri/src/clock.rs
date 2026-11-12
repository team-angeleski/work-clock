//! Local-time helpers. Times are Unix seconds (f64) everywhere; days are local midnights.

use chrono::{Datelike, Local, NaiveDate, TimeZone, Timelike};

pub fn now() -> f64 {
    let n = Local::now();
    n.timestamp() as f64 + n.timestamp_subsec_millis() as f64 / 1000.0
}

fn local(t: f64) -> chrono::DateTime<Local> {
    Local.timestamp_millis_opt((t * 1000.0) as i64).single().unwrap_or_else(Local::now)
}

/// Local midnight at the start of the day holding `t`.
pub fn start_of_day(t: f64) -> f64 {
    let d = local(t).date_naive();
    midnight(d)
}

fn midnight(d: NaiveDate) -> f64 {
    let naive = d.and_hms_opt(0, 0, 0).unwrap();
    match Local.from_local_datetime(&naive) {
        chrono::LocalResult::Single(x) => x.timestamp() as f64,
        chrono::LocalResult::Ambiguous(a, _) => a.timestamp() as f64,
        // A DST jump at midnight: take the first valid moment after it.
        chrono::LocalResult::None => Local.from_local_datetime(&(naive + chrono::Duration::hours(1))).earliest()
            .map(|x| x.timestamp() as f64).unwrap_or(0.0),
    }
}

/// Midnight `n` days from the day holding `t` (handles 23/25-hour days).
pub fn add_days(t: f64, n: i64) -> f64 {
    let d = local(t).date_naive() + chrono::Duration::days(n);
    midnight(d)
}

/// `t` plus `hours` on its local day, measured from midnight on the clock face.
pub fn at_hour(day: f64, hour: u32, minute: u32) -> f64 {
    let d = local(day).date_naive();
    let naive = d.and_hms_opt(hour.min(23), minute.min(59), 0).unwrap();
    Local.from_local_datetime(&naive).earliest().map(|x| x.timestamp() as f64).unwrap_or(day + hour as f64 * 3600.0)
}

pub fn same_day(a: f64, b: f64) -> bool { local(a).date_naive() == local(b).date_naive() }

pub fn hour(t: f64) -> u32 { local(t).hour() }
pub fn minute(t: f64) -> u32 { local(t).minute() }

/// "2026-11-12", the board's day key.
pub fn day_key(t: f64) -> String { local(t).format("%Y-%m-%d").to_string() }

pub fn parse_day(s: &str) -> Option<f64> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d").ok().map(midnight)
}

/// 0 = Monday … 6 = Sunday, the bit order the board uses for workdays.
pub fn weekday_bit(t: f64) -> u32 { local(t).weekday().num_days_from_monday() }

pub fn weekday_short(t: f64) -> String { local(t).format("%a").to_string() }

pub fn tz_minutes() -> i32 { Local::now().offset().local_minus_utc() / 60 }

pub fn time_text(t: f64) -> String {
    let l = local(t);
    let h = l.hour();
    format!("{}:{:02}{}", if h % 12 == 0 { 12 } else { h % 12 }, l.minute(), if h < 12 { "am" } else { "pm" })
}

/// Live clock: 4:07, 52:30, 1:02:45
pub fn clock(t: f64) -> String {
    let s = t.max(0.0) as i64;
    let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60);
    if h > 0 { format!("{h}:{m:02}:{sec:02}") } else { format!("{m}:{sec:02}") }
}

/// Readable duration: 45m, 2h 10m
pub fn long(t: f64) -> String {
    if t > 0.0 && t < 60.0 { return format!("{}s", t as i64); }
    let m = (t.max(0.0) as i64) / 60;
    if m >= 60 {
        if m % 60 == 0 { format!("{}h", m / 60) } else { format!("{}h {}m", m / 60, m % 60) }
    } else { format!("{m}m") }
}
