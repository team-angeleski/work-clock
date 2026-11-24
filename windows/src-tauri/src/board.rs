//! The friend board: up to 5 friends ranked by focus score. Yesterday's winner gets 3 taunts.
//! The race is blind: today's times stay sealed, and the result is revealed the next day.
//! State and race maths from Board.swift; the network calls are in api.rs.

use crate::api::{Friend, Taunt};
use crate::clock;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// Everything kept between runs, apart from the focus record (engine.rs).
#[derive(Serialize, Deserialize, Default, Clone)]
pub struct Settings {
    pub member: Option<String>,
    pub secret: Option<String>,
    pub code: Option<String>,
    pub name: Option<String>,
    pub invite_code: Option<String>,
    pub device_id: Option<String>,
    pub announced_day: Option<String>,
    #[serde(default)]
    pub office: crate::office::Office,
    #[serde(default)]
    pub coach_once: HashMap<String, String>,
    pub pill_pos: Option<(i32, i32)>,
    #[serde(default)]
    pub setup_done: bool,
    #[serde(default)]
    pub autostart_off: bool,
    /// The version an automatic update started from, so the next launch can say "Updated from X to Y".
    pub updated_from: Option<String>,
}

impl Settings {
    pub fn load(path: &std::path::Path) -> Settings {
        std::fs::read(path).ok().and_then(|j| serde_json::from_slice(&j).ok()).unwrap_or_default()
    }
    pub fn save(&self, path: &std::path::Path) {
        if let Ok(j) = serde_json::to_vec_pretty(self) {
            let tmp = path.with_extension("json.tmp");
            if std::fs::write(&tmp, j).is_ok() { let _ = std::fs::rename(&tmp, path); }
        }
    }
    /// This computer, as one of possibly several on the account.
    pub fn device_id(&mut self) -> String {
        if let Some(d) = &self.device_id { return d.clone(); }
        let id = uuid::Uuid::new_v4().to_string().to_uppercase();
        self.device_id = Some(id.clone());
        id
    }
    pub fn joined(&self) -> bool { self.member.is_some() && self.secret.is_some() }
}

#[derive(Default)]
pub struct Board {
    pub friends: Vec<Friend>,
    pub taunts_left: i64,
    pub error: Option<String>,
    pub busy: bool,
    pub last_synced: Option<f64>,
    pub last_sync_attempt: f64,
    pub showing: Option<Taunt>,
    pub showing_until: f64,
    pub email: Option<String>,
    pub scheduled: HashSet<String>,
    /// Taunts waiting to pop up, with when.
    pub pending: Vec<(f64, Taunt)>,
    pub next_show_at: f64,
    /// I won yesterday, so I get to pick today's character.
    pub can_pick: bool,
    pub unlocked: Vec<String>,
    pub can_unlock: bool,
    /// When the friends' numbers were last fetched (full sync or inbox).
    pub live_at: f64,
}

pub fn short(name: &str) -> String {
    let first = name.split(' ').next().unwrap_or(name);
    if first.chars().count() > 9 { format!("{}…", first.chars().take(8).collect::<String>()) } else { first.to_string() }
}

impl Board {
    pub fn me<'a>(&'a self, member: &Option<String>) -> Option<&'a Friend> {
        let m = member.as_ref()?;
        self.friends.iter().find(|f| f.id.eq_ignore_ascii_case(m))
    }

    /// Everyone but me, with live numbers.
    pub fn others(&self, member: &Option<String>) -> Vec<Friend> {
        self.friends.iter().filter(|f| member.as_ref().map(|m| !f.id.eq_ignore_ascii_case(m)).unwrap_or(true))
            .map(|f| self.live(f)).collect()
    }

    /// A focusing friend's clock runs on between fetches (for up to 3 minutes), so the race is live.
    pub fn live(&self, f: &Friend) -> Friend {
        let mut g = f.clone();
        if f.focusing {
            let add = (clock::now() - self.live_at).clamp(0.0, 180.0) as i64;
            g.today += add;
            g.score += add;
        }
        g
    }

    /// Yesterday's winner(s), by score.
    pub fn champions(&self) -> HashSet<String> {
        let best = self.friends.iter().map(|f| f.yesterday).max().unwrap_or(0);
        if best < 600 { return HashSet::new(); }
        self.friends.iter().filter(|f| f.yesterday == best).map(|f| f.id.to_lowercase()).collect()
    }

    /// The only thing shown about the race today: who is working right now. Never a time or a gap.
    pub fn race_line(&self, member: &Option<String>) -> Option<String> {
        if member.is_none() { return None; }
        let on: Vec<Friend> = self.others(member).into_iter().filter(|f| f.focusing).collect();
        match on.len() {
            0 => None,
            1 => Some(format!("{} is on the clock", short(&on[0].name))),
            n => Some(format!("{n} friends on the clock")),
        }
    }

    pub fn won_yesterday(&self, member: &Option<String>) -> bool {
        member.as_ref().map(|m| self.champions().contains(&m.to_lowercase())).unwrap_or(false)
    }

    /// Each unseen taunt pops up right away, as long as I'm at the computer.
    pub fn schedule(&mut self, incoming: Vec<Taunt>) {
        for t in incoming {
            if self.scheduled.contains(&t.id) { continue; }
            self.scheduled.insert(t.id.clone());
            self.pending.push((clock::now(), t));
        }
    }

    pub fn forget(&mut self) {
        self.friends.clear();
        self.taunts_left = 0;
        self.pending.clear();
        self.scheduled.clear();
        self.email = None;
        self.last_synced = None;
        self.can_pick = false;
        self.unlocked.clear();
        self.can_unlock = false;
    }
}

/// Starters for the taunt box.
pub const IDEAS: [&str; 6] = [
    "ur a loser 🫵",
    "I did more before lunch than you did all day",
    "Is your keyboard decorative?",
    "Touch keyboard, not grass",
    "Elite tier called. It said 'who?'",
    "Imagine being out-focused by me",
];
