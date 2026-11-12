//! The clock: what counts as focus, XP, goals and the score. A line-for-line port of the Mac
//! app's Store.swift, so both computers count by the same rules:
//! - only the apps/sites you picked, while they're in front;
//! - idle 30 seconds = away; on a board, also no key press, click or scroll for 10 minutes;
//! - the away stretch is handed back; sessions split at midnight; sleep stops the clock.

use crate::clock::{self, now};
use crate::office::{Office, CLOCK_IN_SECONDS};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub const IDLE_LIMIT: f64 = 30.0;
pub const HANDS_LIMIT: f64 = 600.0;
const COMBO_BREAK: f64 = 15.0;
pub const EARLY_HOUR: u32 = 9;
pub const CLEAN_HOUR: u32 = 13;
const CLEAN_BONUS: f64 = 1800.0;
const MEDIAN_MINUTES: f64 = 110.0;
const SPREAD: f64 = 0.6;

/// Sites that never count unless you picked them yourself.
pub const DISTRACTIONS: [&str; 9] = ["youtube.com", "tiktok.com", "instagram.com", "facebook.com", "x.com",
    "twitter.com", "reddit.com", "netflix.com", "twitch.tv"];

pub fn is_distraction(domain: &str) -> bool {
    DISTRACTIONS.iter().any(|d| domain == *d || domain.ends_with(&format!(".{d}")))
}

/// "chrome.exe|github.com" → ("chrome.exe", Some("github.com"))
pub fn split(key: &str) -> (&str, Option<&str>) {
    match key.split_once('|') { Some((a, b)) => (a, Some(b)), None => (key, None) }
}

/// What the computer can tell us each second.
pub trait Senses {
    /// The app in front, as a lower-case exe name ("code.exe"); None if nothing.
    fn front(&mut self) -> Option<String>;
    fn is_self(&self, app: &str) -> bool;
    fn is_browser(&self, app: &str) -> bool;
    /// The front browser tab's site: Some("") for a new tab or non-web page, None if unreadable.
    fn domain(&mut self) -> Option<String>;
    /// Seconds since any input, mouse moves included.
    fn idle(&self) -> f64;
    /// Seconds since a key press, click or scroll (mouse-jiggler apps only move).
    fn hands_idle(&self) -> f64;
    fn display_name(&mut self, app: &str) -> String;
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Segment { pub start: f64, pub end: f64, pub app: String }
impl Segment { fn duration(&self) -> f64 { self.end - self.start } }

#[derive(Serialize, Deserialize, Default)]
struct SaveFile {
    segments: Vec<Segment>,
    xp: f64,
    picked: Vec<String>,
    goal_hours: f64,
    idle_pause: bool,
    running: Option<bool>,
    saved_at: Option<f64>,
    session_xp: Option<f64>,
    auto_goal: Option<bool>,
    distractions: Option<HashMap<String, f64>>,
    names: Option<HashMap<String, String>>,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Mode { Idle, Picking, Running }

/// Things the app layer should do: play a sound, post a notification, sync now, shake.
#[derive(Debug, Clone)]
pub enum Event { Sound(&'static str), Notify(String, String), Nudge, Bump, Shake }

pub struct Engine {
    pub mode: Mode,
    pub picked: Vec<String>,
    pub picking_set: Vec<String>,
    pub on_task: bool,
    pub off_reason: Option<String>,
    pub combo_start: Option<f64>,
    pub now: f64,
    pub session_xp: f64,
    pub xp: f64,
    pub flash: Option<String>,
    flash_until: f64,
    pub goal_hours: f64,
    pub idle_pause: bool,
    pub auto_goal: bool,
    pub office: Office,
    /// On a board the rules are stricter and can't be switched off.
    pub strict: bool,
    pub names: HashMap<String, String>,

    segments: Vec<Segment>,
    seg_start: Option<f64>,
    seg_app: String,
    off_since: Option<f64>,
    last_save: f64,
    last_tick: f64,
    day_cache: HashMap<i64, f64>,

    pub others_today: f64,
    others_day: f64,
    remote_history: HashMap<i64, f64>,

    pub distractions: HashMap<String, f64>,
    last_distraction_check: f64,
    clean_announced: String,
    pub events: Vec<Event>,
    file: Option<std::path::PathBuf>,
    loading: bool,
}

impl Engine {
    pub fn new(file: Option<std::path::PathBuf>) -> Self {
        let mut e = Engine {
            mode: Mode::Idle, picked: vec![], picking_set: vec![], on_task: false, off_reason: None,
            combo_start: None, now: now(), session_xp: 0.0, xp: 0.0, flash: None, flash_until: 0.0,
            goal_hours: 4.0, idle_pause: true, auto_goal: true, office: Office::default(), strict: false,
            names: HashMap::new(), segments: vec![], seg_start: None, seg_app: String::new(), off_since: None,
            last_save: now(), last_tick: 0.0, day_cache: HashMap::new(), others_today: 0.0,
            others_day: f64::MIN, remote_history: HashMap::new(), distractions: HashMap::new(),
            last_distraction_check: 0.0, clean_announced: String::new(), events: vec![], file, loading: false,
        };
        e.load();
        e
    }

    // MARK: Actions

    /// The single pill click: idle → pick apps → focus → stop.
    pub fn primary_action(&mut self) {
        match self.mode {
            Mode::Idle => self.begin_picking(),
            Mode::Picking => self.start(),
            Mode::Running => self.stop(),
        }
    }

    /// Hotkey: skip picking and reuse the last set of apps.
    pub fn quick_toggle(&mut self) {
        match self.mode {
            Mode::Running => self.stop(),
            Mode::Picking => self.start(),
            Mode::Idle => if self.picked.is_empty() { self.begin_picking() } else { self.start() },
        }
    }

    pub fn change_apps(&mut self) {
        if self.mode == Mode::Running { self.stop(); }
        self.begin_picking();
    }

    pub fn cancel_picking(&mut self) {
        if self.mode != Mode::Picking { return; }
        self.mode = Mode::Idle;
        self.picking_set.clear();
    }

    pub fn remove_picked(&mut self, key: &str) {
        self.picked.retain(|k| k != key);
        self.picking_set.retain(|k| k != key);
        self.save();
    }

    fn begin_picking(&mut self) {
        self.picking_set.clear();
        self.mode = Mode::Picking;
        self.flash = None;
    }

    fn start(&mut self) {
        if !self.picking_set.is_empty() { self.picked = std::mem::take(&mut self.picking_set); }
        if self.picked.is_empty() { self.show("Click an app first", 3.0); return; }
        self.picking_set.clear();
        self.mode = Mode::Running;
        self.session_xp = 0.0;
        self.combo_start = None;
        self.off_since = None;
        self.events.push(Event::Sound("pop"));
        self.events.push(Event::Nudge);
        self.save();
    }

    pub fn stop(&mut self) { self.stop_at(now()); }

    fn stop_at(&mut self, at: f64) {
        if self.on_task { self.close(at); }
        self.mode = Mode::Idle;
        self.combo_start = None;
        let earned = self.session_xp.round() as i64;
        if earned > 0 { self.show(&format!("+{earned} XP"), 4.0); }
        self.events.push(Event::Sound("bottle"));
        self.save();
        self.events.push(Event::Nudge);
    }

    /// While picking, add whatever is in front: an app, or the site in a browser's active tab.
    fn pick_front(&mut self, s: &mut dyn Senses) {
        let Some(front) = s.front() else { return };
        if front.is_empty() || s.is_self(&front) { return; }
        let mut key = front.clone();
        if s.is_browser(&front) {
            if let Some(domain) = s.domain() {
                if domain.is_empty() { return; } // new tab or settings page: wait for a real site
                key = format!("{front}|{domain}");
            }
        }
        if self.picking_set.contains(&key) || self.picking_set.len() >= 8 { return; }
        if !self.names.contains_key(&front) { let n = s.display_name(&front); self.names.insert(front.clone(), n); }
        self.picking_set.push(key.clone());
        self.events.push(Event::Sound("tink"));
        let n = self.name(&key);
        self.show(&format!("+ {n}"), 2.0);
    }

    // MARK: Clock

    pub fn tick(&mut self, s: &mut dyn Senses) {
        let t = now();
        // The computer slept (or the app froze): stop at the last moment we were awake, like the
        // Mac stops on sleep. Nothing from the gap counts.
        if self.last_tick > 0.0 && t - self.last_tick > 30.0 && self.mode == Mode::Running {
            let at = self.last_tick;
            self.now = at;
            self.stop_at(at);
        }
        self.last_tick = t;
        self.now = t;
        if self.flash.is_some() && t >= self.flash_until { self.flash = None; }
        if self.mode == Mode::Picking { self.pick_front(s); }
        self.watch_distractions(s);
        if self.now - self.last_save > 30.0 { self.save(); }
        if self.mode != Mode::Running { return; }

        // Split at midnight so each day gets its own time.
        if let Some(st) = self.seg_start {
            if !clock::same_day(st, self.now) {
                let midnight = clock::start_of_day(self.now);
                let app = self.seg_app.clone();
                self.close(midnight);
                self.begin(&app, midnight);
            }
        }

        let front = s.front().unwrap_or_default();
        let idle = s.idle();
        let strict = self.strict;
        let hands_idle = s.hands_idle();
        let idle_away = (self.idle_pause || strict) && idle > IDLE_LIMIT;
        let jiggle_away = strict && hands_idle > HANDS_LIMIT;
        let away = idle_away || jiggle_away;
        let away_for = if idle_away { idle } else { hands_idle };
        let is_self = !front.is_empty() && s.is_self(&front); // our own windows keep whatever state we were in

        // In a browser, the site decides. Only ask the browser if something of it was picked.
        let mut key = front.clone();
        let mut distraction: Option<String> = None;
        if !front.is_empty() && s.is_browser(&front) && self.picked.iter().any(|k| split(k).0 == front) {
            if let Some(domain) = s.domain() {
                if !domain.is_empty() {
                    key = format!("{front}|{domain}");
                    if is_distraction(&domain) { distraction = Some(domain); self.note_distraction(); }
                }
            }
        }
        let matches = !front.is_empty() && (self.picked.contains(&key) || (self.picked.contains(&front) && distraction.is_none()));
        let working = !away && (matches || (is_self && self.on_task));
        self.off_reason = if away { Some("Away".into()) } else { distraction };

        if working {
            if !self.on_task { self.begin(&key, self.now); }
            else if !is_self && key != self.seg_app { let n = self.now; self.close(n); self.begin(&key, n); }
            self.off_since = None;
            if self.combo_start.is_none() { self.combo_start = Some(self.now); }
            let m = self.multiplier();
            self.award(m / 60.0);
        } else {
            if self.on_task {
                if away {
                    // Hand back the idle stretch: it was not real work.
                    let st = self.seg_start.unwrap_or(self.now);
                    let end = st.max(self.now - away_for);
                    let m = self.multiplier();
                    self.close(end);
                    self.award(-away_for.min(601.0) / 60.0 * m);
                    self.combo_start = None;
                } else {
                    let n = self.now;
                    self.close(n);
                }
                self.off_since = Some(self.now);
            }
            if let (Some(o), Some(c)) = (self.off_since, self.combo_start) {
                if self.now - o > COMBO_BREAK {
                    let minutes = (o - c) / 60.0;
                    if minutes >= 10.0 {
                        self.events.push(Event::Sound("basso"));
                        self.show(&format!("Combo lost (×{})", if minutes >= 25.0 { 3 } else { 2 }), 4.0);
                    }
                    self.combo_start = None;
                }
            }
        }
    }

    fn begin(&mut self, app: &str, at: f64) {
        self.seg_start = Some(at);
        self.seg_app = app.to_string();
        self.on_task = true;
    }

    fn close(&mut self, end: f64) {
        let Some(st) = self.seg_start else { return };
        if end - st >= 1.0 {
            self.segments.push(Segment { start: st, end, app: self.seg_app.clone() });
            self.day_cache.clear();
        }
        self.seg_start = None;
        self.on_task = false;
    }

    fn award(&mut self, amount: f64) {
        let level_before = self.level();
        let goal_before = self.goal_met();
        let tier_before = tier(self.today_percentile());
        self.xp = (self.xp + amount).max(0.0);
        self.session_xp = (self.session_xp + amount).max(0.0);
        if self.level() > level_before {
            self.events.push(Event::Sound("glass"));
            self.events.push(Event::Bump);
            let l = self.level();
            self.show(&format!("Level {l}!"), 4.0);
        }
        let tier_now = tier(self.today_percentile());
        if amount > 0.0 && tier_now != tier_before && self.today_percentile() >= 40.0 {
            self.events.push(Event::Sound("glass"));
            self.events.push(Event::Bump);
            self.show(&format!("You're now {tier_now}"), 5.0);
        }
        if self.goal_met() && !goal_before {
            self.events.push(Event::Sound("hero"));
            self.events.push(Event::Bump);
            self.show("Goal reached", 5.0);
        }
    }

    pub fn show(&mut self, text: &str, seconds: f64) {
        self.flash = Some(text.to_string());
        self.flash_until = now() + seconds;
    }

    /// Friends' pranks and board events surface here.
    pub fn announce(&mut self, text: &str, sound: Option<&'static str>, seconds: f64) {
        if let Some(s) = sound { self.events.push(Event::Sound(s)); }
        self.events.push(Event::Bump);
        self.show(text, seconds);
    }

    // MARK: Derived

    pub fn multiplier(&self) -> f64 {
        match self.combo_start {
            Some(c) if self.on_task => {
                let m = (self.now - c) / 60.0;
                if m >= 25.0 { 3.0 } else if m >= 10.0 { 2.0 } else { 1.0 }
            }
            _ => 1.0,
        }
    }

    pub fn combo_minutes(&self) -> i64 { self.combo_start.map(|c| ((self.now - c) / 60.0) as i64).unwrap_or(0) }

    fn cost(n: i64) -> f64 { 60.0 + 30.0 * (n - 1) as f64 }

    fn level_parts(&self) -> (i64, f64) {
        let (mut n, mut left) = (1i64, self.xp);
        while left >= Self::cost(n) { left -= Self::cost(n); n += 1; }
        (n, left)
    }
    pub fn level(&self) -> i64 { self.level_parts().0 }
    pub fn level_progress(&self) -> f64 { let (n, l) = self.level_parts(); l / Self::cost(n) }
    pub fn xp_to_next(&self) -> i64 { let (n, l) = self.level_parts(); (Self::cost(n) - l).ceil() as i64 }

    pub fn clocked_in(&self) -> bool { self.today() >= CLOCK_IN_SECONDS }

    // MARK: Your other computers
    // The server adds up every computer signed in to your account. Past days: whichever is larger,
    // this computer's own record or the account's. Today: this computer's live time plus the others'.

    pub fn apply_remote(&mut self, others_today: f64, history: &HashMap<String, i64>) {
        self.remote_history = history.iter()
            .filter_map(|(k, v)| clock::parse_day(k).map(|d| (d as i64, *v as f64))).collect();
        self.others_day = clock::start_of_day(now());
        self.others_today = others_today.max(0.0);
    }

    pub fn total(&mut self, day: f64) -> f64 {
        let start = clock::start_of_day(day);
        let mine = self.local_total(day);
        if start == self.others_day { return mine + self.others_today; }
        mine.max(*self.remote_history.get(&(start as i64)).unwrap_or(&0.0))
    }

    pub fn local_today(&mut self) -> f64 { let n = self.now; self.local_total(n) }

    pub fn local_total(&mut self, day: f64) -> f64 {
        let start = clock::start_of_day(day);
        let end = clock::add_days(day, 1);
        let closed = match self.day_cache.get(&(start as i64)) {
            Some(c) => *c,
            None => {
                let c = self.segments.iter().filter(|s| s.start >= start && s.start < end).map(|s| s.duration()).sum();
                self.day_cache.insert(start as i64, c);
                c
            }
        };
        match self.seg_start {
            Some(s) if s >= start && s < end => closed + (self.now - s),
            _ => closed,
        }
    }

    pub fn today(&self) -> f64 {
        // Non-caching variant for &self callers.
        let start = clock::start_of_day(self.now);
        let end = clock::add_days(self.now, 1);
        let mut mine: f64 = self.segments.iter().filter(|s| s.start >= start && s.start < end).map(|s| s.duration()).sum();
        if let Some(s) = self.seg_start { if s >= start && s < end { mine += self.now - s; } }
        if start == self.others_day { mine + self.others_today } else { mine.max(*self.remote_history.get(&(start as i64)).unwrap_or(&0.0)) }
    }

    /// A distraction site was opened before 1pm today (blows the clean-morning bonus on every computer).
    pub fn blown_today(&self) -> bool {
        match self.distractions.get(&clock::day_key(self.now)) {
            Some(first) => clock::hour(*first) < CLEAN_HOUR,
            None => false,
        }
    }

    // MARK: Score: focus time plus bonuses (what the friend board ranks on)

    pub fn today_score(&mut self) -> f64 { let n = self.now; self.score(n) }

    pub fn score_rate(&self) -> f64 { if clock::hour(self.now) < EARLY_HOUR { 1.5 } else { 1.0 } }
    pub fn early_bird(&self) -> bool { self.score_rate() > 1.0 }

    pub fn score(&mut self, day: f64) -> f64 {
        self.total(day) + 0.5 * self.focused(day, EARLY_HOUR) + if self.clean_morning(day) { CLEAN_BONUS } else { 0.0 }
    }

    pub fn early_bonus(&self, day: f64) -> f64 { 0.5 * self.focused(day, EARLY_HOUR) }

    /// Focused seconds on a day before a given hour (this computer's own).
    pub fn focused(&self, day: f64, hour: u32) -> f64 {
        let start = clock::start_of_day(day);
        let cutoff = clock::at_hour(start, hour, 0);
        let mut t: f64 = self.segments.iter()
            .filter(|s| s.start >= start && s.start < cutoff)
            .map(|s| (s.end.min(cutoff) - s.start).max(0.0)).sum();
        if let Some(s) = self.seg_start { if s >= start && s < cutoff { t += (self.now.min(cutoff) - s).max(0.0); } }
        t
    }

    pub fn clean_morning(&self, day: f64) -> bool {
        let start = clock::start_of_day(day);
        let cutoff = clock::at_hour(start, CLEAN_HOUR, 0);
        if self.now < cutoff { return false; }
        if let Some(first) = self.distractions.get(&clock::day_key(day)) { if *first < cutoff { return false; } }
        self.focused(day, CLEAN_HOUR) >= 3600.0
    }

    pub fn clean_morning_status(&self) -> String {
        let start = clock::start_of_day(self.now);
        let cutoff = clock::at_hour(start, CLEAN_HOUR, 0);
        if let Some(first) = self.distractions.get(&clock::day_key(self.now)) {
            if *first < cutoff { return format!("Blown at {}", clock::time_text(*first)); }
        }
        if self.now >= cutoff {
            return if self.clean_morning(self.now) { "Earned +30m".into() } else { "Missed (needed 1h by 1pm)".into() };
        }
        let need = (3600.0 - self.focused(self.now, CLEAN_HOUR)).max(0.0);
        if need > 0.0 { format!("On track · {}m more by 1pm", (need / 60.0) as i64) } else { "On track · stay off socials till 1pm".into() }
    }

    /// Checks the front browser tab every few seconds, whether or not the clock is running.
    fn watch_distractions(&mut self, s: &mut dyn Senses) {
        let t = now();
        if t - self.last_distraction_check < 5.0 { return; }
        self.last_distraction_check = t;
        self.office.promote();
        if clock::hour(t) >= CLEAN_HOUR {
            let today = clock::day_key(t);
            if self.clean_announced != today && self.clean_morning(t) {
                self.clean_announced = today;
                self.announce("Clean morning bonus +30m", Some("hero"), 6.0);
            }
            return;
        }
        if self.distractions.contains_key(&clock::day_key(t)) { return; }
        let Some(front) = s.front() else { return };
        if front.is_empty() || !s.is_browser(&front) { return; }
        if let Some(d) = s.domain() { if !d.is_empty() && is_distraction(&d) { self.note_distraction(); } }
    }

    fn note_distraction(&mut self) {
        let key = clock::day_key(self.now);
        if self.distractions.contains_key(&key) || clock::hour(self.now) >= CLEAN_HOUR { return; }
        self.distractions.insert(key, now());
        self.announce("Clean morning blown", Some("basso"), 4.0);
        self.save();
    }

    // MARK: How you compare

    pub fn today_percentile(&self) -> f64 { percentile(self.today()) }

    pub fn week(&mut self) -> Vec<(f64, f64)> {
        let start = clock::start_of_day(self.now);
        (0..7).rev().map(|i| { let d = clock::add_days(start, -i); (d, self.total(d)) }).collect()
    }

    pub fn typical_day(&mut self) -> f64 {
        let worked: Vec<f64> = self.week().into_iter().map(|w| w.1).filter(|t| *t >= 60.0).collect();
        if worked.is_empty() { 0.0 } else { worked.iter().sum::<f64>() / worked.len() as f64 }
    }

    pub fn next_tier(&self) -> Option<(&'static str, f64)> {
        let cutoffs = [(40.0, "Average"), (60.0, "Above average"), (80.0, "Grinder"), (95.0, "Elite"), (99.0, "Monk mode")];
        let p = self.today_percentile();
        let next = cutoffs.iter().find(|c| c.0 > p)?;
        let minutes = MEDIAN_MINUTES * (inverse_normal(next.0 / 100.0) * SPREAD).exp();
        Some((next.1, (minutes * 60.0 - self.today()).max(0.0)))
    }

    pub fn expected_progress(&self) -> f64 {
        let start = clock::at_hour(self.now, 9, 0);
        ((self.now - start) / (8.0 * 3600.0)).clamp(0.0, 1.0)
    }

    pub fn goal(&mut self) -> f64 { if self.auto_goal { self.adaptive_goal() } else { self.goal_hours * 3600.0 } }

    fn adaptive_from(&mut self, days: std::ops::Range<i64>) -> f64 {
        let start = clock::start_of_day(self.now);
        let past: Vec<f64> = days.map(|i| { let d = clock::add_days(start, -i); self.total(d) }).filter(|t| *t >= 300.0).collect();
        let base = if past.is_empty() { 2700.0 } else { past.iter().sum::<f64>() / past.len() as f64 };
        ((base + 900.0).clamp(1800.0, 5.0 * 3600.0) / 900.0).round() * 900.0
    }

    /// Your recent average (before today) plus 15 minutes: always a stretch, never out of reach.
    pub fn adaptive_goal(&mut self) -> f64 { self.adaptive_from(1..8) }
    pub fn adaptive_goal_tomorrow(&mut self) -> f64 { self.adaptive_from(0..7) }

    pub fn progress(&mut self) -> f64 { let g = self.goal(); if g > 0.0 { self.today() / g } else { 0.0 } }
    pub fn goal_met(&mut self) -> bool { let g = self.goal(); self.today() >= g }

    /// Consecutive days that hit the goal. Today counts once it is hit.
    pub fn streak(&mut self) -> i64 {
        let goal = self.goal();
        let mut day = clock::start_of_day(self.now);
        if self.total(day) < goal { day = clock::add_days(day, -1); }
        let mut n = 0;
        while self.total(day) >= goal && n < 3650 { n += 1; day = clock::add_days(day, -1); }
        n
    }

    pub fn mood(&mut self) -> f64 {
        if self.mode == Mode::Running && !self.on_task {
            let off = self.off_since.map(|o| self.now - o).unwrap_or(0.0);
            return if off > 60.0 { -1.0 } else { -0.6 };
        }
        if self.goal_met() { return 1.0; }
        if self.mode == Mode::Running { let m = self.multiplier(); return if m >= 3.0 { 1.0 } else if m >= 2.0 { 0.75 } else { 0.5 }; }
        let delta = self.progress() - self.expected_progress();
        if delta >= 0.0 { 0.4 } else if delta > -0.15 { 0.0 } else { -0.6 }
    }

    pub fn today_by_app(&self) -> Vec<(String, f64)> {
        let mut map: HashMap<String, f64> = HashMap::new();
        for s in self.segments.iter().filter(|s| clock::same_day(s.start, self.now)) { *map.entry(s.app.clone()).or_default() += s.duration(); }
        if let Some(s) = self.seg_start { *map.entry(self.seg_app.clone()).or_default() += self.now - s; }
        let mut v: Vec<_> = map.into_iter().collect();
        v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
        v
    }

    pub fn shown_apps(&self) -> &Vec<String> { if self.mode == Mode::Picking { &self.picking_set } else { &self.picked } }

    pub fn name(&self, key: &str) -> String {
        let (app, domain) = split(key);
        if let Some(d) = domain { return d.to_string(); }
        self.names.get(app).cloned().unwrap_or_else(|| app.trim_end_matches(".exe").to_string())
    }

    // MARK: Persistence

    pub fn save(&mut self) {
        if self.loading { return; }
        let Some(file) = &self.file else { return };
        self.last_save = now();
        let mut all = self.segments.clone();
        if let Some(s) = self.seg_start { all.push(Segment { start: s, end: now(), app: self.seg_app.clone() }); }
        let data = SaveFile {
            segments: all, xp: self.xp, picked: self.picked.clone(), goal_hours: self.goal_hours,
            idle_pause: self.idle_pause, running: Some(self.mode == Mode::Running), saved_at: Some(now()),
            session_xp: Some(self.session_xp), auto_goal: Some(self.auto_goal),
            distractions: Some(self.distractions.clone()), names: Some(self.names.clone()),
        };
        if let Ok(json) = serde_json::to_vec(&data) {
            let tmp = file.with_extension("json.tmp");
            if std::fs::write(&tmp, json).is_ok() { let _ = std::fs::rename(&tmp, file); }
        }
    }

    fn load(&mut self) {
        let Some(file) = &self.file else { return };
        let Ok(json) = std::fs::read(file) else { return };
        let Ok(data) = serde_json::from_slice::<SaveFile>(&json) else { return };
        self.loading = true;
        self.segments = data.segments;
        self.xp = data.xp;
        self.picked = data.picked;
        self.goal_hours = if data.goal_hours > 0.0 { data.goal_hours } else { 4.0 };
        self.idle_pause = data.idle_pause;
        self.auto_goal = data.auto_goal.unwrap_or(true);
        self.names = data.names.unwrap_or_default();
        let t = now();
        self.distractions = data.distractions.unwrap_or_default().into_iter().filter(|(_, v)| t - v < 14.0 * 86400.0).collect();
        // Restarted mid-session (an update, a crash): carry on instead of stopping.
        if data.running == Some(true) && data.saved_at.map(|a| t - a < 300.0).unwrap_or(false) && !self.picked.is_empty() {
            self.mode = Mode::Running;
            self.session_xp = data.session_xp.unwrap_or(0.0);
        }
        self.loading = false;
    }
}

// MARK: How you compare
// A rough log-normal curve fitted to published figures: the average knowledge worker logs about
// 1h 51m of focus work a day, ~4h is the daily ceiling for elite performers.

/// 0–100: share of workers who focus less than this in a whole day.
pub fn percentile(t: f64) -> f64 {
    if t < 60.0 { return 0.0; }
    let z = (t / 60.0 / MEDIAN_MINUTES).ln() / SPREAD;
    0.5 * (1.0 + erf(z / 2f64.sqrt())) * 100.0
}

pub fn rank(p: f64) -> String {
    if p >= 50.0 { format!("Top {}%", ((100.0 - p).ceil() as i64).max(1)) } else { format!("Bottom {}%", (p.ceil() as i64).max(1)) }
}

pub fn tier(p: f64) -> &'static str {
    match p {
        p if p < 10.0 => "Slacking",
        p if p < 40.0 => "Below average",
        p if p < 60.0 => "Average",
        p if p < 80.0 => "Above average",
        p if p < 95.0 => "Grinder",
        p if p < 99.0 => "Elite",
        _ => "Monk mode",
    }
}

fn inverse_normal(p: f64) -> f64 {
    let (mut lo, mut hi) = (-6.0, 6.0);
    for _ in 0..60 {
        let mid = (lo + hi) / 2.0;
        if 0.5 * (1.0 + erf(mid / 2f64.sqrt())) < p { lo = mid } else { hi = mid }
    }
    (lo + hi) / 2.0
}

/// Abramowitz & Stegun 7.1.26 (error < 1.5e-7), since Rust's std has no erf.
fn erf(x: f64) -> f64 {
    let sign = if x < 0.0 { -1.0 } else { 1.0 };
    let x = x.abs();
    let t = 1.0 / (1.0 + 0.3275911 * x);
    let y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * (-x * x).exp();
    sign * y
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fake { front: String, idle: f64, hands: f64, domain: Option<String> }
    impl Senses for Fake {
        fn front(&mut self) -> Option<String> { Some(self.front.clone()) }
        fn is_self(&self, app: &str) -> bool { app == "workclock.exe" }
        fn is_browser(&self, app: &str) -> bool { app == "chrome.exe" }
        fn domain(&mut self) -> Option<String> { self.domain.clone() }
        fn idle(&self) -> f64 { self.idle }
        fn hands_idle(&self) -> f64 { self.hands }
        fn display_name(&mut self, app: &str) -> String { app.into() }
    }

    fn running(picked: &[&str]) -> Engine {
        let mut e = Engine::new(None);
        e.picked = picked.iter().map(|s| s.to_string()).collect();
        e.mode = Mode::Running;
        e
    }

    #[test]
    fn counts_only_picked_apps() {
        let mut e = running(&["code.exe"]);
        let mut s = Fake { front: "code.exe".into(), idle: 0.0, hands: 0.0, domain: None };
        e.tick(&mut s);
        assert!(e.on_task);
        s.front = "spotify.exe".into();
        e.tick(&mut s);
        assert!(!e.on_task);
    }

    #[test]
    fn sites_decide_in_browsers() {
        let mut e = running(&["chrome.exe|github.com"]);
        let mut s = Fake { front: "chrome.exe".into(), idle: 0.0, hands: 0.0, domain: Some("github.com".into()) };
        e.tick(&mut s);
        assert!(e.on_task);
        s.domain = Some("youtube.com".into());
        e.tick(&mut s);
        assert!(!e.on_task);
        assert_eq!(e.off_reason.as_deref(), Some("youtube.com"));
    }

    #[test]
    fn whole_browser_picked_still_blocks_distractions() {
        let mut e = running(&["chrome.exe"]);
        let mut s = Fake { front: "chrome.exe".into(), idle: 0.0, hands: 0.0, domain: Some("reddit.com".into()) };
        e.tick(&mut s);
        assert!(!e.on_task);
    }

    #[test]
    fn idle_hands_back_time() {
        let mut e = running(&["code.exe"]);
        let mut s = Fake { front: "code.exe".into(), idle: 0.0, hands: 0.0, domain: None };
        e.tick(&mut s);
        // Pretend the segment started 5 minutes ago and we've been idle 3 of them.
        e.seg_start = Some(now() - 300.0);
        s.idle = 180.0;
        e.tick(&mut s);
        assert!(!e.on_task);
        let t = e.local_today();
        assert!((t - 120.0).abs() < 3.0, "kept {t}");
    }

    #[test]
    fn thirty_seconds_idle_is_away() {
        let mut e = running(&["code.exe"]);
        let mut s = Fake { front: "code.exe".into(), idle: 25.0, hands: 0.0, domain: None };
        e.tick(&mut s);
        assert!(e.on_task);
        s.idle = 35.0;
        e.tick(&mut s);
        assert!(!e.on_task);
        assert_eq!(e.off_reason.as_deref(), Some("Away"));
    }

    #[test]
    fn jiggler_rule_only_on_a_board() {
        let mut e = running(&["code.exe"]);
        let mut s = Fake { front: "code.exe".into(), idle: 1.0, hands: 700.0, domain: None };
        e.tick(&mut s);
        assert!(e.on_task, "off the board, mouse moves are enough");
        e.strict = true;
        e.tick(&mut s);
        assert!(!e.on_task);
        assert_eq!(e.off_reason.as_deref(), Some("Away"));
    }

    #[test]
    fn strict_forces_idle_pause() {
        let mut e = running(&["code.exe"]);
        e.idle_pause = false;
        let mut s = Fake { front: "code.exe".into(), idle: 200.0, hands: 0.0, domain: None };
        e.tick(&mut s);
        assert!(e.on_task);
        e.strict = true;
        e.tick(&mut s);
        assert!(!e.on_task);
    }

    #[test]
    fn picking_adds_front_app_and_site() {
        let mut e = Engine::new(None);
        e.primary_action();
        let mut s = Fake { front: "workclock.exe".into(), idle: 0.0, hands: 0.0, domain: None };
        e.tick(&mut s);
        assert!(e.picking_set.is_empty(), "our own window is never picked");
        s.front = "code.exe".into();
        e.tick(&mut s);
        s.front = "chrome.exe".into();
        s.domain = Some("".into());
        e.tick(&mut s);
        s.domain = Some("docs.rs".into());
        e.tick(&mut s);
        assert_eq!(e.picking_set, vec!["code.exe", "chrome.exe|docs.rs"]);
        e.primary_action();
        assert_eq!(e.mode, Mode::Running);
    }

    #[test]
    fn sleep_stops_the_clock() {
        let mut e = running(&["code.exe"]);
        let mut s = Fake { front: "code.exe".into(), idle: 0.0, hands: 0.0, domain: None };
        e.tick(&mut s);
        e.last_tick = now() - 3600.0;
        e.tick(&mut s);
        assert_eq!(e.mode, Mode::Idle);
    }

    #[test]
    fn levels_and_percentiles() {
        let mut e = Engine::new(None);
        e.xp = 60.0;
        assert_eq!(e.level(), 2);
        assert!((percentile(110.0 * 60.0) - 50.0).abs() < 0.01);
        assert_eq!(tier(96.0), "Elite");
    }
}
