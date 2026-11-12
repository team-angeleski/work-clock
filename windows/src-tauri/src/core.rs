//! Ties the clock, the board and the coach together, and builds what the windows draw.

use crate::api::{self, BoardState, Friend};
use crate::board::{Board, Settings};
use crate::clock::{self, long, now};
use crate::engine::{self, Engine, Event, Mode};
use crate::office::Office;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;

pub struct Core {
    pub engine: Engine,
    pub board: Board,
    pub settings: Settings,
    settings_path: PathBuf,
    // Coach state (Coach.swift)
    off_start: Option<f64>,
    shook: usize,
    notified: bool,
    first_active: Option<f64>,
    first_active_day: String,
    last_lock_check: f64,
    pub shake_tick: u64,
    pub bump_tick: u64,
    pub update: Option<String>,
    pub idle_now: f64,
}

impl Core {
    pub fn new(dir: Option<PathBuf>) -> Core {
        let settings_path = dir.as_ref().map(|d| d.join("settings.json")).unwrap_or_else(|| PathBuf::from("/dev/null"));
        let mut settings = if dir.is_some() { Settings::load(&settings_path) } else { Settings::default() };
        settings.device_id();
        let mut engine = Engine::new(dir.as_ref().map(|d| d.join("data.json")));
        engine.office = settings.office.clone();
        engine.strict = settings.joined();
        let c = Core {
            engine, board: Board::default(), settings, settings_path,
            off_start: None, shook: 0, notified: false, first_active: None, first_active_day: String::new(),
            last_lock_check: 0.0,
            shake_tick: 0, bump_tick: 0, update: None, idle_now: 0.0,
        };
        c.save_settings();
        c
    }

    pub fn save_settings(&self) {
        if self.settings_path.as_os_str() == "/dev/null" { return; }
        let mut s = self.settings.clone();
        s.office = self.engine.office.clone();
        s.save(&self.settings_path);
    }

    pub fn joined(&self) -> bool { self.settings.joined() }

    fn notify(&mut self, title: &str, body: &str) { self.engine.events.push(Event::Notify(title.into(), body.into())); }
    fn shake(&mut self) { self.engine.events.push(Event::Shake); }

    // MARK: Live numbers

    /// Minutes late today, as the server counts them (live locally until clocked in).
    pub fn my_late(&self) -> i64 {
        let Some(me) = self.board.me(&self.settings.member) else { return 0 };
        if me.due_min.is_none() { return 0; }
        me.late.unwrap_or(0).max(self.engine.office.late_minutes(self.engine.now, self.engine.clocked_in()))
    }

    /// My live score after the lateness penalty.
    pub fn my_score(&mut self) -> i64 {
        let server = self.board.me(&self.settings.member).map(|m| m.score).unwrap_or(0);
        let late = self.my_late();
        server.max((self.engine.today_score() as i64 - late * 60).max(0))
    }

    /// The race with my own row using my live numbers (the server's copy lags a few minutes).
    pub fn ranked(&mut self) -> Vec<Friend> {
        let score = self.my_score();
        let late = self.my_late();
        let level = self.engine.level();
        let streak = self.engine.streak();
        let focusing = self.engine.mode == Mode::Running && self.engine.on_task;
        let today = self.engine.today() as i64;
        let member = self.settings.member.clone();
        let mut v: Vec<Friend> = self.board.friends.iter().map(|f| {
            if member.as_ref().map(|m| f.id.eq_ignore_ascii_case(m)) != Some(true) { return f.clone(); }
            Friend { level, streak, focusing, today: f.today.max(today), score, week: f.week - f.score + score, late: Some(late), ..f.clone() }
        }).collect();
        v.sort_by(|a, b| b.score.cmp(&a.score).then(a.name.cmp(&b.name)));
        v
    }

    pub fn race_line(&mut self) -> Option<String> {
        let mine = self.my_score();
        let rate = self.engine.score_rate();
        self.board.race_line(&self.settings.member, mine, rate)
    }

    pub fn leading(&mut self) -> bool { let s = self.my_score(); self.board.leading(&self.settings.member, s) }

    // MARK: Sync

    /// Every 2 minutes while focusing, every 5 otherwise; and just before 9am and 1pm, since the
    /// server only credits bonus time it saw before the cut-off.
    pub fn sync_due(&self) -> bool {
        if !self.joined() { return false; }
        let every = if std::env::var("WORKCLOCK_FAST_SYNC").is_ok() { 15.0 } else if self.engine.mode == Mode::Running { 120.0 } else { 300.0 };
        let since = now() - self.board.last_sync_attempt;
        let h = clock::hour(now());
        let cutoff = (h == 8 || h == 12) && clock::minute(now()) == 59 && since > 45.0;
        since >= every || cutoff
    }

    pub fn sync_args(&mut self) -> Option<api::SyncArgs> {
        let member = self.settings.member.clone()?;
        let secret = self.settings.secret.clone()?;
        self.board.last_sync_attempt = now();
        Some(api::SyncArgs {
            member, secret, day: clock::day_key(now()),
            seconds: self.engine.local_today() as i64, score: self.engine.today_score() as i64,
            level: self.engine.level(), streak: self.engine.streak(),
            focusing: self.engine.mode == Mode::Running && self.engine.on_task,
            tz_minutes: clock::tz_minutes(), device: self.settings.device_id(), blown: self.engine.blown_today(),
        })
    }

    pub fn apply_sync(&mut self, r: Result<BoardState, api::ApiError>) {
        match r {
            Ok(s) => {
                self.board.friends = s.members;
                self.settings.code = Some(s.code);
                self.board.taunts_left = s.taunts_left;
                self.board.can_pick = s.can_pick_character.unwrap_or(false);
                self.board.unlocked = s.unlocked.unwrap_or_default();
                self.board.can_unlock = s.can_unlock.unwrap_or(false);
                if let Some(m) = s.mine { self.engine.apply_remote(m.others_today as f64, &m.history); }
                if let Some(m) = s.me {
                    self.board.email = m.email;
                    if self.engine.office.adopt(m.start_min, m.workdays, m.next_start_min, m.next_workdays, m.next_from) { self.save_settings(); }
                }
                self.board.last_synced = Some(now());
                self.board.error = None;
                self.board.schedule(s.incoming);
                self.board_synced();
                self.announce_day();
                self.announce_lead_change();
            }
            Err(api::ApiError::Server(t)) if t == "Not a member of this board" => {
                self.forget();
                self.board.error = Some("You were removed from the board".into());
            }
            Err(_) => {} // Offline: keep the last known board; the next sync catches up.
        }
    }

    pub fn adopt_account(&mut self, member: String, secret: String, code: Option<String>, name: Option<String>) {
        self.settings.member = Some(member);
        self.settings.secret = Some(secret);
        self.settings.code = code;
        self.settings.name = name;
        self.settings.invite_code = None;
        self.board.error = None;
        self.engine.strict = true;
        self.save_settings();
    }

    pub fn forget(&mut self) {
        self.settings.member = None;
        self.settings.secret = None;
        self.settings.code = None;
        self.board.forget();
        self.engine.strict = false;
        self.engine.apply_remote(0.0, &HashMap::new());
        self.save_settings();
    }

    /// Once a day: tell me who won yesterday.
    fn announce_day(&mut self) {
        let today = clock::day_key(now());
        if self.settings.announced_day.as_deref() == Some(&today) || self.board.friends.len() < 2 { return; }
        let Some(mine) = self.settings.member.clone() else { return };
        let champs = self.board.champions();
        if champs.is_empty() { return; }
        self.settings.announced_day = Some(today);
        self.save_settings();
        if champs.contains(&mine.to_lowercase()) {
            let n = self.board.taunts_left;
            self.engine.announce(&format!("You won yesterday! {n} taunts ready"), Some("hero"), 6.0);
            self.notify("You won yesterday 👑", &format!("You've got {n} taunts to send. Open your clock's panel."));
        } else if let Some(w) = self.board.friends.iter().find(|f| champs.contains(&f.id.to_lowercase())).map(|f| f.name.clone()) {
            self.engine.announce(&format!("{w} won yesterday. Brace yourself."), Some("funk"), 6.0);
            self.notify(&format!("{w} won yesterday"), "Taunts incoming. Win today to get your revenge.");
        }
    }

    fn announce_lead_change(&mut self) {
        if self.board.others(&self.settings.member).is_empty() || self.engine.today() <= 300.0 { return; }
        let now_lead = self.leading();
        if let Some(before) = self.board.last_lead {
            if before != now_lead {
                let race = self.race_line();
                if now_lead {
                    self.engine.announce("You took the lead!", Some("glass"), 4.0);
                    self.notify("You took the lead 👑", race.as_deref().unwrap_or("Keep going"));
                } else if let Some(top) = self.board.others(&self.settings.member).into_iter().max_by_key(|f| f.score).map(|f| f.name.clone()) {
                    self.engine.announce(&format!("{top} overtook you"), Some("basso"), 4.0);
                    let body = race.map(|r| format!("{r}. Get back to it.")).unwrap_or_else(|| "Get back to it.".into());
                    self.notify(&format!("{top} overtook you"), &body);
                }
            }
        }
        self.board.last_lead = Some(now_lead);
    }

    // MARK: Taunts popping up

    /// Returns a taunt to mark as seen on the server, when one pops up.
    pub fn step_taunts(&mut self, idle: f64) -> Option<String> {
        let t = now();
        if self.board.showing.is_some() && t >= self.board.showing_until { self.board.showing = None; self.board.next_show_at = t + 4.0; }
        if self.board.showing.is_some() || t < self.board.next_show_at { return None; }
        let i = self.board.pending.iter().position(|(at, _)| *at <= t)?;
        // Only pop up when someone's actually there to see it: check again every 10 seconds, so it
        // pops the moment they're back.
        if idle >= 60.0 { self.board.next_show_at = t + 10.0; return None; }
        let (_, next) = self.board.pending.remove(i);
        self.board.showing_until = t + 9.0;
        self.engine.events.push(Event::Sound("poop"));
        let (title, body) = (format!("{} says", next.from_name), next.message.clone());
        self.notify(&title, &body);
        let id = next.id.clone();
        self.board.showing = Some(next);
        self.shake_tick += 1;
        Some(id)
    }

    pub fn dismiss_taunt(&mut self) {
        if self.board.showing.take().is_some() { self.board.next_show_at = now() + 4.0; }
    }

    /// The 20-second inbox: taunts queue at once; each friend who just started gets a notice.
    pub fn apply_inbox(&mut self, inbox: api::Inbox) {
        self.board.schedule(inbox.taunts);
        for e in inbox.events.into_iter().filter(|e| e.kind == "started") { self.friend_started(&e.from_name, e.today); }
    }

    /// A friend just started working: tell me straight away, then sync for fresh race numbers.
    fn friend_started(&mut self, name: &str, today: i64) {
        let theirs = long(today as f64);
        let mine = long(self.engine.today());
        let short = crate::board::short(name);
        if self.engine.mode == Mode::Running {
            self.notify(&format!("{name} started too"), &format!("They're on {theirs} today. You're on {mine}. Keep going."));
            self.engine.announce(&format!("{short} started too"), Some("pop"), 5.0);
        } else {
            self.notify(&format!("{name} just started working"), &format!("They're on {theirs} today. You're on {mine}. Your move."));
            self.engine.announce(&format!("{short} started. Your move"), Some("funk"), 6.0);
        }
        self.engine.events.push(Event::Nudge);
    }

    pub fn inbox_args(&self) -> Option<(String, String)> {
        Some((self.settings.member.clone()?, self.settings.secret.clone()?))
    }

    // MARK: The coach (Coach.swift): small, well-timed pushes back to work

    fn once(&mut self, key: &str) -> bool {
        let day = clock::day_key(now());
        if self.settings.coach_once.get(key) == Some(&day) { return false; }
        self.settings.coach_once.insert(key.to_string(), day);
        self.save_settings();
        true
    }

    /// Runs every couple of seconds. `front` is the front app, `front_domain` its site if a browser.
    /// Returns true when the front browser tab should be closed (locked until clock-in).
    pub fn coach_step(&mut self, idle: f64, browser_domain: Option<String>) -> bool {
        let t = now();
        self.drifting(t);
        self.clock_in(t);
        let close = self.lock_distractions(t, browser_domain);
        self.not_started(t, idle);
        self.streak_at_risk(t);
        self.recap(t);
        close
    }

    fn on_board_with_friends(&self) -> bool { self.joined() && !self.board.others(&self.settings.member).is_empty() }

    fn clock_in(&mut self, t: f64) {
        let Some(due) = self.engine.office.due(t) else { return };
        if self.engine.clocked_in() || self.engine.mode == Mode::Running { return; }
        let to_go = due - t;
        let at = Office::text(self.engine.office.start_min);
        let on_board = self.on_board_with_friends();
        if to_go <= 600.0 && to_go > 0.0 && self.once("soon") {
            let extra = if on_board { " Late costs a point a minute, and your friends get told." } else { "" };
            self.notify(&format!("Clock in by {at}"), &format!("10 minutes.{extra}"));
        } else if to_go <= 0.0 && to_go > -3600.0 && self.once("due") {
            self.notify(&format!("It's {at}. Clock in."), "One click on your clock, pick your apps, go.");
            self.engine.announce("Clock in", Some("funk"), 6.0);
            self.shake();
        } else if to_go <= -900.0 && to_go > -3.0 * 3600.0 && self.once("late15") {
            let late = self.engine.office.late_minutes(t, false);
            let body = if on_board { format!("Your friends have been told. −{late} and counting.") }
                       else { "Every minute you wait makes it harder. Start with 5 minutes.".into() };
            self.notify(&format!("You're {late} minutes late"), &body);
            self.shake();
        }
    }

    /// Before you've clocked in on a workday, distracting sites get closed.
    fn lock_distractions(&mut self, t: f64, domain: Option<String>) -> bool {
        if !self.engine.office.lock_distractions || !self.engine.office.is_workday(t) || self.engine.clocked_in()
            || clock::hour(t) < 5 || t - self.last_lock_check < 4.0 { return false; }
        let Some(d) = domain else { return false };
        self.last_lock_check = t;
        if !engine::is_distraction(&d) { return false; }
        self.engine.announce("Clock in first 🔒", Some("basso"), 5.0);
        self.shake();
        true
    }

    fn streak_at_risk(&mut self, t: f64) {
        if clock::hour(t) < 20 || self.engine.goal_met() || self.engine.mode == Mode::Running { return; }
        let streak = self.engine.streak();
        if streak <= 0 || !self.once("streak") { return; }
        let left = long((self.engine.goal() - self.engine.today()).max(0.0));
        self.notify(&format!("Your {streak}-day streak ends at midnight"), &format!("{left} to go. Start now and keep it alive."));
        self.engine.announce("Streak at risk", Some("funk"), 6.0);
        self.shake();
    }

    fn drifting(&mut self, t: f64) {
        // Only while a session is running and you've left your work; idle is handled by idle pause.
        if self.engine.mode != Mode::Running || self.engine.on_task || self.engine.off_reason.as_deref() == Some("Away") {
            self.off_start = None; self.shook = 0; self.notified = false;
            return;
        }
        let start = *self.off_start.get_or_insert(t);
        let off = (t - start) * if std::env::var("WORKCLOCK_FAST_COACH").is_ok() { 10.0 } else { 1.0 };
        let site = self.engine.off_reason.clone();
        let shakes: &[f64] = if site.is_some() { &[20.0, 60.0] } else { &[90.0] };
        let notify_at = if site.is_some() { 120.0 } else { 300.0 };
        if self.shook < shakes.len() && off >= shakes[self.shook] {
            self.shook += 1;
            self.engine.announce("Back to work?", Some("basso"), 4.0);
            self.shake();
        }
        if off >= notify_at && !self.notified {
            self.notified = true;
            let race = self.race_line().map(|r| format!(" {r}.")).unwrap_or_default();
            let title = site.map(|s| format!("{} minutes on {s}", (notify_at / 60.0) as i64)).unwrap_or_else(|| "You left your work apps".into());
            self.notify(&title, &format!("Your clock is paused.{race} Get back in."));
        }
    }

    fn not_started(&mut self, t: f64, idle: f64) {
        let day = clock::day_key(t);
        if self.first_active_day != day { self.first_active_day = day; self.first_active = None; }
        if self.engine.mode != Mode::Idle || self.engine.today() >= 60.0 || !(7..20).contains(&clock::hour(t)) || idle >= 60.0 { return; }
        let first = *self.first_active.get_or_insert(t);
        let waited = t - first;
        if waited >= 900.0 && self.once("nudge1") {
            let body = match self.race_line() {
                Some(r) => format!("{r}. One click on your clock and you're in."),
                None => format!("{} today so far. One click on your clock and you're in.", engine::rank(0.0)),
            };
            self.notify("You haven't started yet", &body);
            self.engine.announce("Tap to start", Some("funk"), 6.0);
            self.shake();
        } else if waited >= 5400.0 && self.once("nudge2") {
            let line = self.board.others(&self.settings.member).into_iter().find(|f| f.today > 0)
                .map(|f| format!("{} is on {}. ", f.name, long(f.score as f64))).unwrap_or_default();
            self.notify("Still nothing on the clock", &format!("{line}Pick one thing and give it 25 minutes."));
            self.shake();
        }
    }

    /// After each board sync: friends blowing their clock-in. (Friends starting come through the inbox.)
    fn board_synced(&mut self) {
        let others: Vec<Friend> = self.board.others(&self.settings.member).into_iter().cloned().collect();
        for f in others.iter().filter(|f| f.due_min.is_some() && f.in_min.is_none() && f.late.unwrap_or(0) >= 15) {
            if !self.once(&format!("friendlate-{}", f.id)) { continue; }
            self.notify(&format!("{} hasn't clocked in", f.name),
                        &format!("{} minutes late and losing a point a minute. Get ahead.", f.late.unwrap_or(15)));
        }
    }

    fn recap(&mut self, t: f64) {
        if clock::hour(t) < 21 || self.engine.today() < 60.0 || !self.once("recap") { return; }
        let p = self.engine.today_percentile();
        let mut body = format!("{} focused · {} ({}).", long(self.engine.today()), engine::rank(p), engine::tier(p));
        if self.on_board_with_friends() {
            if self.leading() { body += " You're beating everyone. Win the day, earn 3 taunts."; }
            else if let Some(r) = self.race_line() { body += &format!(" {r} before midnight."); }
        }
        body += &format!(" Tomorrow's goal: {}.", long(self.engine.adaptive_goal_tomorrow()));
        self.engine.office.promote();
        let tomorrow = clock::add_days(t, 1);
        if self.engine.office.planned_days() & (1 << clock::weekday_bit(tomorrow)) != 0 {
            body += &format!(" Clock in by {}.", Office::text(self.engine.office.planned_start()));
        }
        let title = if self.engine.goal_met() { "Goal smashed today 🎉" } else { "Today's focus" };
        self.notify(title, &body);
    }

    // MARK: What the windows draw

    fn office_line(&self) -> Option<String> {
        let e = &self.engine;
        let due = e.office.due(e.now)?;
        if e.clocked_in() { return None; }
        let late = e.office.late_minutes(e.now, false);
        if late > 0 { return Some(format!("Late {late}m · clock in")); }
        let to_go = due - e.now;
        if to_go > 0.0 && to_go <= 3600.0 { Some(format!("Clock in by {}", Office::text(e.office.start_min))) } else { None }
    }

    fn subtitle(&mut self) -> String {
        if let Some(f) = &self.engine.flash { return f.clone(); }
        let n = self.engine.now as i64;
        match self.engine.mode {
            Mode::Idle => {
                if let Some(o) = self.office_line() { return o; }
                let minute = n / 60;
                if minute % 2 == 0 { if let Some(r) = self.race_line() { return r; } }
                if minute % 2 == 1 { if let Some((name, need)) = self.engine.next_tier() { return format!("{} to {name}", long(need)); } }
                if self.engine.picked.is_empty() { "Tap to focus".into() } else { engine::rank(self.engine.today_percentile()) }
            }
            Mode::Picking => {
                if !self.engine.picking_set.is_empty() { "Tap to start".into() }
                else if self.engine.picked.is_empty() { "Click your apps".into() } else { "Pick, or tap for same".into() }
            }
            Mode::Running => {
                if !self.engine.on_task { return self.engine.off_reason.clone().map(|r| format!("Off task · {r}")).unwrap_or_else(|| "Off task".into()); }
                if (n / 4) % 2 == 1 { if let Some(r) = self.race_line() { return r; } }
                if self.engine.early_bird() { return "Early bird ×1.5".into(); }
                let c = self.engine.combo_minutes();
                if c > 0 { format!("In flow {c}m") } else { "Focusing".into() }
            }
        }
    }

    pub fn snapshot(&mut self, icons: &HashMap<String, String>) -> Value {
        let e_now = self.engine.now;
        let subtitle = self.subtitle();
        let leading = self.leading();
        let race = self.race_line();
        let ranked = self.ranked();
        let champs = self.board.champions();
        let member = self.settings.member.clone().unwrap_or_default().to_lowercase();
        let today = self.engine.today();
        let goal = self.engine.goal();
        let progress = self.engine.progress();
        let goal_met = self.engine.goal_met();
        let mood = self.engine.mood();
        let p = self.engine.today_percentile();
        let week: Vec<Value> = self.engine.week().into_iter()
            .map(|(d, t)| json!({"label": clock::weekday_short(d).chars().next().unwrap_or(' ').to_string(), "total": t, "today": clock::same_day(d, e_now)}))
            .collect();
        let app = |k: &String, e: &Engine| json!({"key": k, "name": e.name(k), "icon": icons.get(engine::split(k).0)});
        let shown: Vec<Value> = self.engine.shown_apps().iter().map(|k| app(k, &self.engine)).collect();
        let by_app: Vec<Value> = self.engine.today_by_app().into_iter().take(6)
            .map(|(k, t)| json!({"name": self.engine.name(&k), "time": long(t), "icon": icons.get(engine::split(&k).0)})).collect();
        let friends: Vec<Value> = ranked.iter().map(|f| json!({
            "id": f.id, "name": f.name, "level": f.level, "streak": f.streak, "focusing": f.focusing,
            "today": long(f.today as f64), "score": f.score, "scoreText": long(f.score as f64), "week": long(f.week as f64),
            "me": f.id.to_lowercase() == member, "champion": champs.contains(&f.id.to_lowercase()),
            "late": f.late.unwrap_or(0), "due": f.due_min.map(Office::text), "in": f.in_min.map(Office::text),
            "tauntedToday": f.taunted_today,
            "character": f.character, "characterName": f.character_name,
        })).collect();
        let my_character = self.board.me(&self.settings.member).and_then(|m| m.character.clone());
        let my_character_name = self.board.me(&self.settings.member).and_then(|m| m.character_name.clone());
        let next_tier = self.engine.next_tier().map(|(n, t)| json!({"name": n, "needed": long(t)}));
        let late = self.my_late();
        let clocked_in = self.engine.clocked_in();
        let level = self.engine.level();
        let streak = self.engine.streak();
        let score = self.my_score();
        let office_line = self.office_line();
        let o = &self.engine.office;
        json!({
            "mode": self.engine.mode,
            "title": match self.engine.mode { Mode::Picking => if self.engine.picking_set.is_empty() { "Pick apps".to_string() } else { "Ready".to_string() }, _ => clock::clock(today) },
            "subtitle": subtitle,
            "onTask": self.engine.on_task,
            "offTask": self.engine.mode == Mode::Running && !self.engine.on_task,
            "multiplier": self.engine.multiplier(),
            "leading": leading,
            "progress": progress, "goalMet": goal_met, "mood": mood,
            "shown": shown, "byApp": by_app,
            "today": long(today), "todaySeconds": today, "goal": long(goal), "autoGoal": self.engine.auto_goal, "goalHours": self.engine.goal_hours,
            "idlePause": self.engine.idle_pause,
            "score": long(score as f64), "earlyBonus": long(self.engine.early_bonus(e_now)), "earlyBird": self.engine.early_bird(),
            "clean": self.engine.clean_morning_status(),
            "rank": engine::rank(p), "tier": engine::tier(p), "nextTier": next_tier,
            "level": level, "levelProgress": self.engine.level_progress(), "xpToNext": self.engine.xp_to_next(),
            "streak": streak, "week": week, "othersToday": long(self.engine.others_today), "hasOthers": self.engine.others_today > 0.0,
            "character": my_character,
            "bump": self.bump_tick, "shake": self.shake_tick,
            "office": {
                "start": o.start_min, "days": o.workdays, "plannedStart": o.planned_start(), "plannedDays": o.planned_days(),
                "pending": o.next_from, "lock": o.lock_distractions, "late": late, "clockedIn": clocked_in,
                "dueText": o.due(e_now).map(|_| Office::text(o.start_min)), "line": office_line,
            },
            "board": {
                "joined": self.joined(), "code": self.settings.code, "name": self.settings.name, "email": self.board.email,
                "friends": friends, "tauntsLeft": self.board.taunts_left, "race": race, "error": self.board.error,
                "busy": self.board.busy, "synced": self.board.last_synced.map(clock::time_text), "invite": self.settings.invite_code,
                "showing": self.board.showing, "canPick": self.board.can_pick, "unlocked": self.board.unlocked, "canUnlock": self.board.can_unlock, "characterName": my_character_name, "ideas": crate::board::IDEAS, "hasKey": api::has_key(),
                "installCommand": self.settings.code.as_ref().map(|c| format!("& ([scriptblock]::Create((irm https://raw.githubusercontent.com/team-angeleski/work-clock/main/windows/install.ps1))) {c}")),
                "macInstall": self.settings.code.as_ref().map(|c| format!("curl -fsSL https://raw.githubusercontent.com/team-angeleski/work-clock/main/install.sh | bash -s {c}")),
            },
            "update": self.update,
            "version": env!("CARGO_PKG_VERSION"),
        })
    }
}
