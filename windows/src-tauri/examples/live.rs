//! Talks to the live board with the Windows client's own API code, without the UI.
//! cargo run --example live -- <command>
//!   send EMAIL            email a sign-in code
//!   signin EMAIL CODE     sign in; saves the account to $LIVE_FILE (default live.json)
//!   join BOARD NAME EMAIL join a board as a new member
//!   sync SECONDS          report SECONDS of focus today from this test computer, print the board
//!   leave                 delete the saved account
#[path = "../src/api.rs"] mod api;
#[path = "../src/clock.rs"] mod clock;

use serde_json::{json, Value};

fn file() -> String { std::env::var("LIVE_FILE").unwrap_or_else(|_| "live.json".into()) }
fn saved() -> Value { serde_json::from_str(&std::fs::read_to_string(file()).expect("no saved account")).unwrap() }

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    match a.first().map(|s| s.as_str()) {
        Some("send") => { api::login_start(&a[1]).map_err(|e| e.text()).unwrap(); println!("code sent"); }
        Some("signin") => {
            let r = api::login_finish(&a[1], &a[2]).map_err(|e| e.text()).unwrap();
            if let Some(e) = r.error { panic!("{e}"); }
            std::fs::write(file(), json!({"member": r.member_id, "secret": r.secret, "name": r.name, "code": r.code,
                "device": uuid::Uuid::new_v4().to_string().to_uppercase()}).to_string()).unwrap();
            println!("signed in as {:?} on board {:?}", r.name, r.code);
        }
        Some("join") => {
            let j = api::join(&a[1], &a[2], &a[3], 540, 31).map_err(|e| e.text()).unwrap();
            std::fs::write(file(), json!({"member": j.member_id, "secret": j.secret, "name": a[2], "code": j.code,
                "device": uuid::Uuid::new_v4().to_string().to_uppercase()}).to_string()).unwrap();
            println!("joined {}", j.code);
        }
        Some("sync") => {
            let s = saved();
            let g = |k: &str| s[k].as_str().unwrap().to_string();
            let secs: i64 = a[1].parse().unwrap();
            let r = api::sync(&api::SyncArgs {
                member: g("member"), secret: g("secret"), day: clock::day_key(clock::now()), seconds: secs, score: secs,
                level: 1, streak: 0, focusing: false, tz_minutes: clock::tz_minutes(), device: g("device"), blown: false,
            }).map_err(|e| e.text()).unwrap();
            println!("board {} · taunts left {}", r.code, r.taunts_left);
            if let Some(m) = r.mine { println!("my other computers today: {}s", m.others_today); }
            for f in r.members { println!("  {:<12} today {:>6}s  score {:>6}s  focusing {}", f.name, f.today, f.score, f.focusing); }
        }
        Some("leave") => { let s = saved(); api::leave(s["member"].as_str().unwrap(), s["secret"].as_str().unwrap()).map_err(|e| e.text()).unwrap(); println!("left"); }
        _ => eprintln!("see the comment at the top of examples/live.rs"),
    }
}
