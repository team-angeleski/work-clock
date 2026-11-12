//! The friend board's server calls (Supabase RPC in the `focusboard` schema), exactly as the Mac
//! app's Board.swift makes them. The server checks every number; this is only transport.

use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::time::Duration;

const BASE: &str = "https://kjjhpstxwwldjlskefrr.supabase.co/rest/v1/rpc/";
const KEY: &str = env!("WORKCLOCK_ANON_KEY");

#[derive(Deserialize, Clone, Debug, serde::Serialize)]
pub struct Friend {
    pub id: String,
    pub name: String,
    pub level: i64,
    pub streak: i64,
    pub focusing: bool,
    pub today: i64,
    pub score: i64,
    pub yesterday: i64,
    pub week: i64,
    pub taunted_today: i64,
    pub late: Option<i64>,
    pub due_min: Option<i64>,
    pub in_min: Option<i64>,
    /// Yesterday's winner's costume for today, and what they named it.
    #[serde(default)]
    pub character: Option<String>,
    #[serde(default)]
    pub character_name: Option<String>,
}

#[derive(Deserialize, Clone, Debug, serde::Serialize)]
pub struct Taunt { pub id: String, pub message: String, pub from_name: String }

#[derive(Deserialize, Debug)]
pub struct MeInfo {
    pub email: Option<String>,
    pub start_min: i64,
    pub workdays: i64,
    pub next_start_min: Option<i64>,
    pub next_workdays: Option<i64>,
    pub next_from: Option<String>,
}

#[derive(Deserialize, Debug)]
pub struct Mine { pub others_today: i64, pub history: HashMap<String, i64> }

#[derive(Deserialize, Debug)]
pub struct BoardState {
    pub code: String,
    pub taunts_left: i64,
    pub members: Vec<Friend>,
    pub incoming: Vec<Taunt>,
    pub me: Option<MeInfo>,
    pub mine: Option<Mine>,
    /// I won yesterday, so I get to pick today's character.
    #[serde(default)]
    pub can_pick_character: Option<bool>,
}

#[derive(Deserialize, Debug)]
pub struct Joined { pub member_id: String, pub secret: String, pub code: String }

#[derive(Deserialize, Debug)]
pub struct SignedIn {
    pub member_id: Option<String>,
    pub secret: Option<String>,
    pub code: Option<String>,
    pub name: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug)]
pub enum ApiError { Server(String), Offline }

impl ApiError {
    pub fn text(&self) -> String {
        match self { ApiError::Server(s) => s.clone(), ApiError::Offline => "Couldn't reach the board. Check your internet.".into() }
    }
}

pub fn has_key() -> bool { !KEY.is_empty() }

/// POST /rpc/<fn>, retrying dropped connections and timeouts before giving up.
pub fn call(func: &str, body: Value) -> Result<Value, ApiError> {
    if KEY.is_empty() { return Err(ApiError::Server("This build has no board key".into())); }
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(10)).build();
    let mut last = ApiError::Offline;
    for attempt in 0..3 {
        let r = agent.post(&format!("{BASE}{func}"))
            .set("apikey", KEY)
            .set("Authorization", &format!("Bearer {KEY}"))
            .set("Content-Type", "application/json")
            .send_json(body.clone());
        match r {
            Ok(resp) => {
                let text = resp.into_string().unwrap_or_default();
                return Ok(serde_json::from_str(&text).unwrap_or(Value::Null));
            }
            Err(ureq::Error::Status(_, resp)) => {
                let v: Value = resp.into_json().unwrap_or(Value::Null);
                let msg = v.get("message").and_then(|m| m.as_str()).unwrap_or("Couldn't reach the board");
                return Err(ApiError::Server(msg.to_string()));
            }
            Err(ureq::Error::Transport(_)) => {
                last = ApiError::Offline;
                std::thread::sleep(Duration::from_millis(600 * (attempt + 1)));
            }
        }
    }
    Err(last)
}

pub fn decode<T: serde::de::DeserializeOwned>(v: Value) -> Result<T, ApiError> {
    serde_json::from_value(v).map_err(|e| ApiError::Server(format!("Unexpected reply from the board ({e})")))
}

pub struct SyncArgs {
    pub member: String,
    pub secret: String,
    pub day: String,
    pub seconds: i64,
    pub score: i64,
    pub level: i64,
    pub streak: i64,
    pub focusing: bool,
    pub tz_minutes: i32,
    pub device: String,
    pub blown: bool,
}

pub fn sync(a: &SyncArgs) -> Result<BoardState, ApiError> {
    decode(call("focus_sync", json!({
        "p_member": a.member, "p_secret": a.secret, "p_day": a.day, "p_seconds": a.seconds,
        "p_score": a.score, "p_level": a.level, "p_streak": a.streak, "p_focusing": a.focusing,
        "p_tz_minutes": a.tz_minutes, "p_device": a.device, "p_blown": a.blown,
    }))?)
}

pub fn create(name: &str, email: &str, start: i64, days: i64) -> Result<Joined, ApiError> {
    decode(call("focus_create", json!({"p_name": name, "p_platform": "windows", "p_email": email,
                                         "p_start_min": start, "p_workdays": days}))?)
}

pub fn join(code: &str, name: &str, email: &str, start: i64, days: i64) -> Result<Joined, ApiError> {
    decode(call("focus_join", json!({"p_code": code, "p_name": name, "p_platform": "windows", "p_email": email,
                                       "p_start_min": start, "p_workdays": days}))?)
}

pub fn login_start(email: &str) -> Result<(), ApiError> {
    call("focus_login_start", json!({"p_email": email.trim()})).map(|_| ())
}

pub fn login_finish(email: &str, code: &str) -> Result<SignedIn, ApiError> {
    let digits: String = code.chars().filter(|c| c.is_ascii_digit()).collect();
    decode(call("focus_login_finish", json!({"p_email": email.trim(), "p_code": digits}))?)
}

pub fn taunt(member: &str, secret: &str, target: &str, message: &str, day: &str) -> Result<(), ApiError> {
    let msg: String = message.chars().take(80).collect();
    call("focus_taunt", json!({"p_member": member, "p_secret": secret, "p_target": target, "p_message": msg, "p_day": day})).map(|_| ())
}

pub fn seen(member: &str, secret: &str, taunt: &str) -> Result<(), ApiError> {
    call("focus_seen", json!({"p_member": member, "p_secret": secret, "p_taunt": taunt})).map(|_| ())
}

/// The winner dresses up for the day, optionally with their own name for the character.
pub fn set_character(member: &str, secret: &str, character: &str, day: &str, name: Option<&str>) -> Result<(), ApiError> {
    let name: Option<String> = name.map(|n| n.trim().chars().take(24).collect::<String>()).filter(|n| !n.is_empty());
    call("focus_set_character", json!({"p_member": member, "p_secret": secret, "p_character": character, "p_day": day, "p_name": name})).map(|_| ())
}

pub fn set_email(member: &str, secret: &str, email: &str) -> Result<(), ApiError> {
    call("focus_set_email", json!({"p_member": member, "p_secret": secret, "p_email": email})).map(|_| ())
}

pub fn schedule(member: &str, secret: &str, start: i64, days: i64) -> Result<(), ApiError> {
    call("focus_schedule", json!({"p_member": member, "p_secret": secret, "p_start_min": start, "p_workdays": days})).map(|_| ())
}

pub fn leave(member: &str, secret: &str) -> Result<(), ApiError> {
    call("focus_leave", json!({"p_member": member, "p_secret": secret})).map(|_| ())
}

/// The newest release that has a Windows build ("v1.5" → "1.5"), for the update button.
/// Mac-only releases are skipped.
pub fn latest_version() -> Option<String> {
    let v: Value = ureq::get("https://api.github.com/repos/team-angeleski/work-clock/releases?per_page=20")
        .set("User-Agent", "WorkClock-Windows").timeout(Duration::from_secs(10)).call().ok()?.into_json().ok()?;
    let release = v.as_array()?.iter().find(|r| {
        r.get("draft").and_then(|d| d.as_bool()) != Some(true)
            && r.get("assets").and_then(|a| a.as_array()).map(|a| a.iter()
                .any(|x| x.get("name").and_then(|n| n.as_str()) == Some("WorkClock-Setup.exe"))).unwrap_or(false)
    })?;
    Some(release.get("tag_name")?.as_str()?.trim_start_matches('v').to_string())
}
