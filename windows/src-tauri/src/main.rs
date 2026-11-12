// Darnell Jr. (formerly Work Clock) for Windows: a focus clock that sits above the taskbar and races your friends.
// Same account, board and counting rules as the Mac app.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
#![recursion_limit = "256"]

mod api;
mod board;
mod clock;
mod core;
mod engine;
mod office;
#[cfg(windows)]
#[path = "platform_win.rs"]
mod platform;
#[cfg(not(windows))]
#[path = "platform_dev.rs"]
mod platform;

use crate::core::Core;
use crate::engine::{Event, Senses};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent};
use tauri_plugin_notification::NotificationExt;

const PILL_W: f64 = 216.0;
const PILL_H: f64 = 48.0;

struct App {
    core: Arc<Mutex<Core>>,
    nudge: Mutex<mpsc::Sender<()>>,
}

type St<'a> = tauri::State<'a, App>;

impl App {
    fn nudge(&self) { let _ = self.nudge.lock().unwrap().send(()); }
}

fn data_dir() -> std::path::PathBuf {
    // %APPDATA%\WorkClock on Windows. Elsewhere (trying it out on a Mac) a separate folder, so the
    // Mac app's own record in ~/Library/Application Support/WorkClock is never touched.
    let name = if cfg!(windows) { "WorkClock" } else { "WorkClock-WindowsDev" };
    let d = std::env::var_os("WORKCLOCK_DATA").map(std::path::PathBuf::from)
        .unwrap_or_else(|| dirs::data_dir().unwrap_or_else(std::env::temp_dir).join(name));
    let _ = std::fs::create_dir_all(&d);
    d
}

/// "--code ABC123" or a bare board code on the command line.
fn code_from_args(args: &[String]) -> Option<String> {
    let mut it = args.iter().skip(1);
    while let Some(a) = it.next() {
        if a == "--code" { return it.next().map(|c| c.trim().to_uppercase()); }
        if a.len() == 6 && a.chars().all(|c| c.is_ascii_alphanumeric()) { return Some(a.to_uppercase()); }
    }
    None
}

// MARK: Commands (called from the windows)

#[tauri::command]
fn state(s: St) -> Value { s.core.lock().unwrap().snapshot(&HashMap::new()) }

#[tauri::command]
fn primary(s: St) { s.core.lock().unwrap().engine.primary_action(); }

#[tauri::command]
fn quick(s: St) { s.core.lock().unwrap().engine.quick_toggle(); }

#[tauri::command]
fn change_apps(s: St) { s.core.lock().unwrap().engine.change_apps(); }

#[tauri::command]
fn cancel_picking(s: St) { s.core.lock().unwrap().engine.cancel_picking(); }

#[tauri::command]
fn remove_picked(s: St, key: String) { s.core.lock().unwrap().engine.remove_picked(&key); }

#[tauri::command]
fn dismiss_taunt(app: AppHandle, s: St) {
    s.core.lock().unwrap().dismiss_taunt();
    if let Some(w) = app.get_webview_window("taunt") { let _ = w.hide(); }
}

#[tauri::command]
fn set_goal(s: St, auto: bool, hours: f64) {
    let mut c = s.core.lock().unwrap();
    c.engine.auto_goal = auto;
    c.engine.goal_hours = hours.clamp(0.5, 12.0);
    c.engine.save();
}

#[tauri::command]
fn set_idle_pause(s: St, on: bool) { let mut c = s.core.lock().unwrap(); c.engine.idle_pause = on; c.engine.save(); }

#[tauri::command]
fn set_lock(s: St, on: bool) { let mut c = s.core.lock().unwrap(); c.engine.office.lock_distractions = on; c.save_settings(); }

#[tauri::command]
fn get_autostart(app: AppHandle) -> bool {
    use tauri_plugin_autostart::ManagerExt;
    app.autolaunch().is_enabled().unwrap_or(false)
}

#[tauri::command]
fn set_autostart(app: AppHandle, s: St, on: bool) {
    use tauri_plugin_autostart::ManagerExt;
    let a = app.autolaunch();
    let _ = if on { a.enable() } else { a.disable() };
    let mut c = s.core.lock().unwrap();
    c.settings.autostart_off = !on;
    c.save_settings();
}

#[tauri::command]
fn setup_done(app: AppHandle, s: St) {
    let mut c = s.core.lock().unwrap();
    c.settings.setup_done = true;
    c.save_settings();
    drop(c);
    if let Some(w) = app.get_webview_window("setup") { let _ = w.close(); }
}

// Window-making commands are async: a sync command runs on the main thread, and building a
// webview from there deadlocks on Windows.
#[tauri::command]
async fn open_panel(app: AppHandle) { toggle_panel(&app, true); }

#[tauri::command]
fn hide_panel(app: AppHandle) { if let Some(w) = app.get_webview_window("panel") { let _ = w.hide(); } }

#[tauri::command]
async fn open_setup(app: AppHandle) { show_setup(&app); }

#[tauri::command]
fn quit(app: AppHandle, s: St) { s.core.lock().unwrap().engine.save(); app.exit(0); }

/// The Update button: install now.
#[tauri::command]
fn run_update(s: St) { install_update(&s.core); }

/// Runs the one-line installer again, which replaces this copy and reopens it. History and board
/// stay. Once per run: if it fails, the next launch tries again. Builds on a Mac (dev) never update.
fn install_update(core: &Arc<Mutex<Core>>) {
    if !cfg!(windows) { return; }
    {
        let mut c = core.lock().unwrap();
        if c.updating { return; }
        c.updating = true;
        c.settings.updated_from = Some(env!("CARGO_PKG_VERSION").to_string());
        c.save_settings();
        c.engine.save();
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let _ = std::process::Command::new("powershell")
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
                   "irm https://raw.githubusercontent.com/team-angeleski/work-clock/main/windows/install.ps1 | iex"])
            .creation_flags(0x08000000)
            .spawn();
    }
}

/// "2.1.0" is newer than "2.0" (missing parts count as 0).
fn newer(a: &str, b: &str) -> bool {
    let p = |s: &str| s.split('.').map(|x| x.parse::<u32>().unwrap_or(0)).collect::<Vec<_>>();
    let (x, y) = (p(a), p(b));
    for i in 0..x.len().max(y.len()) {
        let (l, r) = (x.get(i).copied().unwrap_or(0), y.get(i).copied().unwrap_or(0));
        if l != r { return l > r; }
    }
    false
}

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    tauri::async_runtime::spawn_blocking(f).await.expect("worker")
}

fn busy(s: &St, on: bool) { s.core.lock().unwrap().board.busy = on; }

/// Emails a 6-digit code to the account's address.
#[tauri::command]
async fn send_code(s: St<'_>, email: String) -> Result<(), String> {
    busy(&s, true);
    let r = blocking(move || api::login_start(&email)).await;
    busy(&s, false);
    r.map_err(|e| e.text())
}

/// Trades the code for the account; this computer then counts toward it.
#[tauri::command]
async fn sign_in(s: St<'_>, email: String, code: String) -> Result<String, String> {
    busy(&s, true);
    let r = blocking(move || api::login_finish(&email, &code)).await;
    busy(&s, false);
    let r = r.map_err(|e| e.text())?;
    if let Some(e) = r.error { return Err(e); }
    let (Some(id), Some(secret)) = (r.member_id, r.secret) else { return Err("Couldn't sign in".into()) };
    let name = r.name.clone().unwrap_or_else(|| "you".into());
    {
        let mut c = s.core.lock().unwrap();
        c.adopt_account(id, secret, r.code, r.name);
        c.engine.announce(&format!("Signed in as {name}"), Some("glass"), 4.0);
    }
    s.nudge();
    Ok(name)
}

/// Create a new board (no code) or join a friend's.
#[tauri::command]
async fn join(s: St<'_>, code: Option<String>, name: String, email: String, start: i64, days: i64) -> Result<String, String> {
    let name = name.trim().to_string();
    if name.is_empty() { return Err("Add your name first".into()); }
    busy(&s, true);
    let (n2, e2, c2) = (name.clone(), email.trim().to_string(), code.clone());
    let r = blocking(move || match c2 {
        Some(c) if !c.trim().is_empty() => api::join(&c, &n2, &e2, start, days),
        _ => api::create(&n2, &e2, start, days),
    }).await;
    busy(&s, false);
    let j = r.map_err(|e| e.text())?;
    {
        let mut c = s.core.lock().unwrap();
        c.engine.office.set_now(start, days);
        c.adopt_account(j.member_id, j.secret, Some(j.code.clone()), Some(name));
        let created = code.map(|c| c.trim().is_empty()).unwrap_or(true);
        let msg = if created { format!("Board {} created", j.code) } else { "Joined the board".into() };
        c.engine.announce(&msg, Some("glass"), 4.0);
    }
    s.nudge();
    Ok(j.code)
}

fn creds(s: &St) -> Result<(String, String), String> {
    let c = s.core.lock().unwrap();
    match (c.settings.member.clone(), c.settings.secret.clone()) { (Some(m), Some(x)) => Ok((m, x)), _ => Err("Join a board first".into()) }
}

#[tauri::command]
async fn taunt(s: St<'_>, id: String, name: String, message: String) -> Result<(), String> {
    let text = message.trim().to_string();
    if text.is_empty() { return Err("Write something first".into()); }
    let (m, x) = creds(&s)?;
    let r = blocking(move || api::taunt(&m, &x, &id, &text, &clock::day_key(clock::now()))).await;
    r.map_err(|e| e.text())?;
    s.core.lock().unwrap().engine.announce(&format!("Taunt sent to {name}"), Some("purr"), 4.0);
    s.nudge();
    Ok(())
}

/// Yesterday's winner picks today's character. Its line shows on this screen only, with no sound.
#[tauri::command]
async fn set_character(s: St<'_>, id: String, name: Option<String>, line: String) -> Result<(), String> {
    let (m, x) = creds(&s)?;
    busy(&s, true);
    let r = blocking(move || api::set_character(&m, &x, &id, &clock::day_key(clock::now()), name.as_deref())).await;
    busy(&s, false);
    r.map_err(|e| e.text())?;
    s.core.lock().unwrap().engine.show(&format!("“{line}”"), 6.0);
    s.nudge();
    Ok(())
}

#[tauri::command]
async fn set_email(s: St<'_>, email: String) -> Result<(), String> {
    let v = email.trim().to_string();
    if v.is_empty() { return Err("An email is required".into()); }
    let (m, x) = creds(&s)?;
    blocking(move || api::set_email(&m, &x, &v)).await.map_err(|e| e.text())?;
    s.core.lock().unwrap().engine.announce("Email saved", Some("pop"), 3.0);
    s.nudge();
    Ok(())
}

/// Clock-in time and workdays. On a board the server applies it from tomorrow.
#[tauri::command]
async fn set_schedule(s: St<'_>, start: i64, days: i64) -> Result<(), String> {
    let joined = { let mut c = s.core.lock().unwrap(); c.engine.office.plan(start, days); c.save_settings(); c.joined() };
    if !joined { return Ok(()); }
    let (m, x) = creds(&s)?;
    blocking(move || api::schedule(&m, &x, start, days)).await.map_err(|e| e.text())?;
    s.nudge();
    Ok(())
}

/// Stop counting this computer toward the account. The account and its other computers carry on.
#[tauri::command]
fn sign_out(s: St) { s.core.lock().unwrap().forget(); }

/// Deletes the account everywhere.
#[tauri::command]
async fn leave(s: St<'_>) -> Result<(), String> {
    if let Ok((m, x)) = creds(&s) { let _ = blocking(move || api::leave(&m, &x)).await; }
    s.core.lock().unwrap().forget();
    Ok(())
}

// MARK: Windows on screen

fn pill_default(app: &AppHandle) -> PhysicalPosition<i32> {
    if let Ok(Some(m)) = app.primary_monitor() {
        let scale = m.scale_factor();
        let area = m.work_area();
        let (w, h) = ((PILL_W * scale) as i32, (PILL_H * scale) as i32);
        let margin = (12.0 * scale) as i32;
        return PhysicalPosition::new(area.position.x + area.size.width as i32 - w - margin, area.position.y + area.size.height as i32 - h - margin);
    }
    PhysicalPosition::new(100, 100)
}

fn make_pill(app: &AppHandle, core: &Arc<Mutex<Core>>) -> tauri::Result<WebviewWindow> {
    let w = WebviewWindowBuilder::new(app, "pill", WebviewUrl::App("pill.html".into()))
        .title("Darnell Jr.")
        .inner_size(PILL_W, PILL_H)
        .decorations(false).transparent(true).shadow(false).resizable(false)
        .always_on_top(true).skip_taskbar(true).focused(false)
        .visible(false)
        .build()?;
    let saved = core.lock().unwrap().settings.pill_pos;
    let pos = saved.map(|(x, y)| PhysicalPosition::new(x, y)).unwrap_or_else(|| pill_default(app));
    let _ = w.set_position(pos);
    // Off every screen (a monitor was unplugged): back to the corner.
    if w.current_monitor().ok().flatten().is_none() { let _ = w.set_position(pill_default(app)); }
    let _ = w.show();
    let core = core.clone();
    w.on_window_event(move |e| {
        if let WindowEvent::Moved(p) = e {
            let mut c = core.lock().unwrap();
            c.settings.pill_pos = Some((p.x, p.y));
            c.save_settings();
        }
    });
    Ok(w)
}

/// Above the pill (or below it near the top of the screen), right edges lined up.
fn place_above_pill(app: &AppHandle, w: &WebviewWindow, gap: f64) {
    let (Some(pill), Ok(size)) = (app.get_webview_window("pill"), w.outer_size()) else { return };
    let (Ok(pp), Ok(ps)) = (pill.outer_position(), pill.outer_size()) else { return };
    let scale = pill.scale_factor().unwrap_or(1.0);
    let g = (gap * scale) as i32;
    let x = pp.x + ps.width as i32 - size.width as i32;
    let mut y = pp.y - size.height as i32 - g;
    if let Ok(Some(m)) = pill.current_monitor() { if y < m.work_area().position.y { y = pp.y + ps.height as i32 + g; } }
    let _ = w.set_position(PhysicalPosition::new(x.max(0), y));
}

fn toggle_panel(app: &AppHandle, force_show: bool) {
    let w = match app.get_webview_window("panel") {
        Some(w) => w,
        None => {
            let Ok(w) = WebviewWindowBuilder::new(app, "panel", WebviewUrl::App("panel.html".into()))
                .title("Darnell Jr.").inner_size(392.0, 620.0)
                .decorations(false).transparent(true).resizable(false).shadow(true)
                .always_on_top(true).skip_taskbar(true).visible(false).build() else { return };
            let w2 = w.clone();
            w.on_window_event(move |e| if let WindowEvent::Focused(false) = e { let _ = w2.hide(); });
            w
        }
    };
    if w.is_visible().unwrap_or(false) && !force_show { let _ = w.hide(); return; }
    place_above_pill(app, &w, 10.0);
    let _ = w.show();
    let _ = w.set_focus();
    // Fresh race numbers whenever the panel opens.
    app.state::<App>().nudge();
}

fn show_setup(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("setup") { let _ = w.show(); let _ = w.set_focus(); return; }
    let _ = WebviewWindowBuilder::new(app, "setup", WebviewUrl::App("setup.html".into()))
        .title("Darnell Jr.").inner_size(540.0, 640.0).resizable(false).center().focused(true).build();
}

fn show_taunt(app: &AppHandle, show: bool) {
    let w = match app.get_webview_window("taunt") {
        Some(w) => w,
        None if show => match WebviewWindowBuilder::new(app, "taunt", WebviewUrl::App("taunt.html".into()))
            .title("Taunt").inner_size(340.0, 132.0)
            .decorations(false).transparent(true).shadow(false).resizable(false)
            .always_on_top(true).skip_taskbar(true).focused(false).visible(false).build() {
            Ok(w) => w,
            Err(_) => return,
        },
        None => return,
    };
    if show { place_above_pill(app, &w, 8.0); let _ = w.show(); } else { let _ = w.hide(); }
}

fn notify(app: &AppHandle, title: &str, body: &str) {
    let _ = app.notification().builder().title(title).body(body).show();
}

// MARK: Background loops

/// Once a second: count, coach, pop up taunts, redraw.
fn tick_loop(app: AppHandle, core: Arc<Mutex<Core>>, nudge: mpsc::Sender<()>) {
    let mut senses = platform::Win::new();
    let mut n: u64 = 0;
    let mut was_showing = false;
    loop {
        let started = Instant::now();
        let (events, snap, seen, close_tab, showing) = {
            let mut c = core.lock().unwrap();
            c.engine.tick(&mut senses);
            let idle = senses.idle();
            let mut close = false;
            if n % 2 == 0 {
                // The site in front matters to the coach only while distractions are locked.
                let domain = if c.engine.office.lock_distractions && !c.engine.clocked_in() {
                    match senses.front() { Some(f) if senses.is_browser(&f) => senses.domain(), _ => None }
                } else { None };
                close = c.coach_step(idle, domain);
            }
            let seen = c.step_taunts(idle).map(|id| (id, c.settings.member.clone(), c.settings.secret.clone()));
            let events = std::mem::take(&mut c.engine.events);
            for e in &events {
                match e { Event::Bump => c.bump_tick += 1, Event::Shake => c.shake_tick += 1, _ => {} }
            }
            let snap = c.snapshot(&HashMap::new());
            (events, snap, seen, close, c.board.showing.is_some())
        };
        if close_tab { senses.close_front_tab(); }
        for e in events {
            match e {
                Event::Sound(s) => { let _ = app.emit_to("pill", "sound", s); }
                Event::Notify(t, b) => notify(&app, &t, &b),
                Event::Nudge => { let _ = nudge.send(()); }
                _ => {}
            }
        }
        if let Some((id, Some(m), Some(x))) = seen { std::thread::spawn(move || { let _ = api::seen(&m, &x, &id); }); }
        if showing != was_showing {
            was_showing = showing;
            let a = app.clone();
            let _ = app.run_on_main_thread(move || show_taunt(&a, showing));
        }
        let _ = app.emit("state", &snap);
        n += 1;
        if let Some(rest) = Duration::from_secs(1).checked_sub(started.elapsed()) { std::thread::sleep(rest); }
    }
}

/// Checks in with the board every 20 seconds if a sync is due, or at once when nudged.
fn sync_loop(core: Arc<Mutex<Core>>, rx: mpsc::Receiver<()>) {
    let mut nudged = true;
    let mut last_inbox = Instant::now() - Duration::from_secs(60);
    loop {
        while rx.try_recv().is_ok() { nudged = true; }
        let args = {
            let mut c = core.lock().unwrap();
            if (nudged && c.joined()) || c.sync_due() { c.sync_args() } else { None }
        };
        if let Some(a) = args {
            let r = api::sync(&a);
            core.lock().unwrap().apply_sync(r);
        }
        // Taunts and "friend started" land within seconds: the inbox every 20 seconds.
        if last_inbox.elapsed() >= Duration::from_secs(19) {
            let creds = core.lock().unwrap().inbox_args();
            if let Some((m, x)) = creds {
                last_inbox = Instant::now();
                if let Ok(inbox) = api::inbox(&m, &x) { core.lock().unwrap().apply_inbox(inbox); }
            }
        }
        nudged = rx.recv_timeout(Duration::from_secs(20)).is_ok();
    }
}

/// Checks for a newer release with a Windows build on launch and every hour, and installs it by
/// itself the first minute no focus session is running (never mid-session). The Update button
/// still installs straight away.
fn update_loop(core: Arc<Mutex<Core>>) {
    let mut last_check: Option<Instant> = None;
    loop {
        if last_check.map(|t| t.elapsed() >= Duration::from_secs(3600)).unwrap_or(true) {
            last_check = Some(Instant::now());
            if let Some(v) = api::latest_version() {
                core.lock().unwrap().update = if newer(&v, env!("CARGO_PKG_VERSION")) { Some(v) } else { None };
            }
        }
        let ready = { let c = core.lock().unwrap(); c.update.is_some() && !c.updating && c.engine.mode == engine::Mode::Idle };
        if ready { install_update(&core); }
        std::thread::sleep(Duration::from_secs(60));
    }
}

fn main() {
    let dir = data_dir();
    let core = Arc::new(Mutex::new(Core::new(Some(dir.clone()))));
    let (tx, rx) = mpsc::channel::<()>();

    // A board code from the installer: on the command line, or left in invite.txt.
    let args: Vec<String> = std::env::args().collect();
    let invite = code_from_args(&args).or_else(|| {
        let f = dir.join("invite.txt");
        let c = std::fs::read_to_string(&f).ok().map(|s| s.trim().to_uppercase()).filter(|s| !s.is_empty());
        let _ = std::fs::remove_file(f);
        c
    });
    if let Some(code) = invite {
        let mut c = core.lock().unwrap();
        if !c.joined() { c.settings.invite_code = Some(code); c.save_settings(); }
    }

    // Just updated: say so on the clock.
    {
        let mut c = core.lock().unwrap();
        if let Some(from) = c.settings.updated_from.take() {
            c.save_settings();
            let now = env!("CARGO_PKG_VERSION");
            if newer(now, &from) { c.engine.announce(&format!("Updated from {from} to {now}"), Some("glass"), 5.0); }
        }
    }

    let core_setup = core.clone();
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, argv, _| {
            // Opened again (from the Start menu, or the installer with a code): show the panel or setup.
            let st = app.state::<App>();
            let joined = {
                let mut c = st.core.lock().unwrap();
                if let Some(code) = code_from_args(&argv) { if !c.joined() { c.settings.invite_code = Some(code); c.save_settings(); } }
                c.joined()
            };
            if joined { toggle_panel(app, true) } else { show_setup(app) }
        }))
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, None))
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_shortcuts(["ctrl+alt+f"]).expect("shortcut")
                .with_handler(|app, _, event| {
                    if event.state == tauri_plugin_global_shortcut::ShortcutState::Pressed {
                        app.state::<App>().core.lock().unwrap().engine.quick_toggle();
                    }
                })
                .build(),
        )
        .manage(App { core: core.clone(), nudge: Mutex::new(tx.clone()) })
        .invoke_handler(tauri::generate_handler![
            state, primary, quick, change_apps, cancel_picking, remove_picked, dismiss_taunt, set_goal, set_idle_pause,
            set_lock, get_autostart, set_autostart, setup_done, open_panel, hide_panel, open_setup, quit, run_update,
            send_code, sign_in, join, taunt, set_character, set_email, set_schedule, sign_out, leave
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            make_pill(&handle, &core_setup)?;

            let menu = Menu::with_items(app, &[
                &MenuItem::with_id(app, "panel", "Open Darnell Jr.", true, None::<&str>)?,
                &MenuItem::with_id(app, "toggle", "Start / Stop  (Ctrl+Alt+F)", true, None::<&str>)?,
                &MenuItem::with_id(app, "setup", "Setup…", true, None::<&str>)?,
                &PredefinedMenuItem::separator(app)?,
                &MenuItem::with_id(app, "quit", "Quit Darnell Jr.", true, None::<&str>)?,
            ])?;
            let mut tray = TrayIconBuilder::with_id("main").tooltip("Darnell Jr.").menu(&menu).show_menu_on_left_click(false)
                .on_menu_event(|app, e| match e.id.as_ref() {
                    "panel" => toggle_panel(app, true),
                    "toggle" => app.state::<App>().core.lock().unwrap().engine.quick_toggle(),
                    "setup" => show_setup(app),
                    "quit" => { app.state::<App>().core.lock().unwrap().engine.save(); app.exit(0) }
                    _ => {}
                })
                .on_tray_icon_event(|tray, e| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = e {
                        toggle_panel(tray.app_handle(), false);
                    }
                });
            if let Some(icon) = app.default_window_icon() { tray = tray.icon(icon.clone()); }
            tray.build(app)?;

            // Open at login unless turned off. Re-registered on every start, so the entry follows the
            // app's current name and folder (it was renamed from Work Clock to Darnell Jr.).
            let (joined, setup_done, autostart_off) = {
                let c = core_setup.lock().unwrap();
                (c.joined(), c.settings.setup_done, c.settings.autostart_off)
            };
            if !autostart_off {
                use tauri_plugin_autostart::ManagerExt;
                let _ = app.autolaunch().enable();
            }
            if !joined && !setup_done { show_setup(&handle); }

            let (h, c) = (handle.clone(), core_setup.clone());
            let tx2 = tx.clone();
            std::thread::spawn(move || tick_loop(h, c, tx2));
            let c = core_setup.clone();
            std::thread::spawn(move || sync_loop(c, rx));
            let c = core_setup.clone();
            std::thread::spawn(move || update_loop(c));
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Darnell Jr. failed to start")
        .run(|_, e| {
            // Closing the setup or panel window never quits: the clock lives in the pill.
            if let tauri::RunEvent::ExitRequested { api, code, .. } = e { if code.is_none() { api.prevent_exit(); } }
        });
}

#[allow(dead_code)]
fn _senses_is_object_safe(_: &dyn Senses) {}

#[cfg(test)]
mod tests {
    #[test]
    fn versions_compare_by_number() {
        assert!(super::newer("2.1.0", "2.0"));
        assert!(super::newer("2.10", "2.9.9"));
        assert!(!super::newer("2.0", "2.0.0"));
        assert!(!super::newer("1.9", "2.0.0"));
    }
}
