//! Office hours: a clock-in time and workdays. Changes start tomorrow, so today's start can't
//! be pushed back once you're running late. Clocking in = the first 5 focused minutes. (Office.swift)

use crate::clock;
use serde::{Deserialize, Serialize};

pub const GRACE: i64 = 5;
pub const CLOCK_IN_SECONDS: f64 = 300.0;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Office {
    pub start_min: i64,
    pub workdays: i64, // bit 0 = Monday … bit 6 = Sunday
    pub next_start_min: Option<i64>,
    pub next_workdays: Option<i64>,
    pub next_from: Option<String>,
    pub lock_distractions: bool,
}

impl Default for Office {
    fn default() -> Self {
        Office { start_min: 540, workdays: 31, next_start_min: None, next_workdays: None, next_from: None, lock_distractions: true }
    }
}

impl Office {
    pub fn planned_start(&self) -> i64 { self.next_start_min.unwrap_or(self.start_min) }
    pub fn planned_days(&self) -> i64 { self.next_workdays.unwrap_or(self.workdays) }

    /// First-time setup applies straight away.
    pub fn set_now(&mut self, start: i64, days: i64) {
        self.start_min = start;
        self.workdays = days;
        self.next_start_min = None;
        self.next_workdays = None;
        self.next_from = None;
    }

    /// Ask for a new schedule. It starts tomorrow.
    pub fn plan(&mut self, start: i64, days: i64) {
        if start == self.start_min && days == self.workdays {
            self.next_start_min = None;
            self.next_workdays = None;
            self.next_from = None;
        } else {
            self.next_start_min = Some(start);
            self.next_workdays = Some(days);
            self.next_from = Some(clock::day_key(clock::add_days(clock::now(), 1)));
        }
    }

    /// The server is the referee once you're on a board. Returns true if anything changed.
    pub fn adopt(&mut self, start: i64, days: i64, next_start: Option<i64>, next_days: Option<i64>, from: Option<String>) -> bool {
        if start == self.start_min && days == self.workdays && next_start == self.next_start_min
            && next_days == self.next_workdays && from == self.next_from { return false; }
        self.start_min = start;
        self.workdays = days;
        self.next_start_min = next_start;
        self.next_workdays = next_days;
        self.next_from = from;
        true
    }

    pub fn promote(&mut self) -> bool {
        match &self.next_from {
            Some(f) if f.as_str() <= clock::day_key(clock::now()).as_str() => {
                self.start_min = self.next_start_min.unwrap_or(self.start_min);
                self.workdays = self.next_workdays.unwrap_or(self.workdays);
                self.next_start_min = None;
                self.next_workdays = None;
                self.next_from = None;
                true
            }
            _ => false,
        }
    }

    pub fn is_workday(&self, t: f64) -> bool { self.workdays & (1 << clock::weekday_bit(t)) != 0 }

    /// When you're due on the day holding `t`, or None on a day off.
    pub fn due(&self, t: f64) -> Option<f64> {
        if !self.is_workday(t) { return None; }
        Some(clock::start_of_day(t) + (self.start_min * 60) as f64)
    }

    /// Minutes late right now (0 within the grace period, capped at 2 hours).
    pub fn late_minutes(&self, now: f64, clocked_in: bool) -> i64 {
        if clocked_in { return 0; }
        let Some(due) = self.due(now) else { return 0 };
        let m = ((now - due) / 60.0) as i64;
        if m <= GRACE { 0 } else { m.min(120) }
    }

    pub fn text(minutes: i64) -> String {
        let (h, m) = (minutes / 60, minutes % 60);
        let h12 = if h % 12 == 0 { 12 } else { h % 12 };
        format!("{}:{:02}{}", h12, m, if h < 12 { "am" } else { "pm" })
    }
}
