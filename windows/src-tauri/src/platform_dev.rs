//! Stand-in senses for building and trying the UI on a Mac. Pretends `WORKCLOCK_FAKE_FRONT`
//! (default "code.exe") is always in front and someone is typing.

use crate::engine::Senses;

pub struct Win;

impl Win {
    pub fn new() -> Win { Win }
    pub fn close_front_tab(&self) {}
}

impl Senses for Win {
    fn front(&mut self) -> Option<String> { Some(std::env::var("WORKCLOCK_FAKE_FRONT").unwrap_or_else(|_| "code.exe".into())) }
    fn is_self(&self, app: &str) -> bool { app == "workclock.exe" }
    fn is_browser(&self, app: &str) -> bool { app == "chrome.exe" }
    fn domain(&mut self) -> Option<String> { std::env::var("WORKCLOCK_FAKE_DOMAIN").ok() }
    fn idle(&self) -> f64 { 0.0 }
    fn hands_idle(&self) -> f64 { 0.0 }
    fn display_name(&mut self, app: &str) -> String {
        match app { "code.exe" => "Visual Studio Code".into(), "chrome.exe" => "Google Chrome".into(), _ => app.into() }
    }
}
