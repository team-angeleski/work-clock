# Darnell Jr. for Windows

(Formerly Work Clock. The repo, the `WorkClock-Setup.exe` download, the `%APPDATA%\WorkClock` data folder and the app identifier keep the old name so installs and updates keep working.)

The same clock, board and account as the Mac app, for Windows 10 and 11. Use a Mac and a PC? Sign in to the same account on both and your time adds up.

## Install

Paste into PowerShell:

```powershell
irm https://raw.githubusercontent.com/team-angeleski/work-clock/main/windows/install.ps1 | iex
```

With a friend's board code:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/team-angeleski/work-clock/main/windows/install.ps1))) CODE
```

The script downloads `WorkClock-Setup.exe` from the newest GitHub release that has one, installs it for your user only (no admin prompt) into `%LOCALAPPDATA%\Darnell Jr` (Windows drops the trailing full stop from folder names), removes any copy installed under the old name,, and opens it. Running it again updates in place. Your focus record lives in `%APPDATA%\WorkClock` and survives updates and uninstalls.

You can also download `WorkClock-Setup.exe` from the [releases page](https://github.com/team-angeleski/work-clock/releases) and run it. It isn't code-signed, so Windows SmartScreen shows "Windows protected your PC": click **More info → Run anyway**. (The PowerShell line doesn't trigger this.)

Updates install themselves: the app checks GitHub on launch and every hour, and installs a newer Windows build the first minute you're not in a focus session (never mid-session), then reopens and says "Updated from X to Y" on the clock. The panel's Update button installs straight away.

Uninstall from Settings → Apps → Darnell Jr.

## Using it

- **The clock** sits above the taskbar, bottom right. Drag it anywhere.
- **Click** it, **click the apps** (or browser tabs) you'll work in, **click it again**. It counts only while one of them is in front.
- **Right-click** it (or click the tray icon) for today's numbers, the race, taunts and settings.
- **Ctrl+Alt+F** starts or stops from anywhere, reusing your last apps.
- **Setup**: new account (name, email, office hours, board code) or **I have an account**, which emails a 6-digit code to your account's address.

## Same rules as the Mac

The counting rules are a straight port of `Sources/Store.swift`, so both computers count the same way:

| Rule | Mac | Windows |
|---|---|---|
| Only picked apps count | front app's bundle id | front window's exe (`code.exe`); Store apps resolved past ApplicationFrameHost |
| Sites in browsers | AppleScript reads the tab URL | UI Automation reads the address bar (Chrome, Edge, Brave, Firefox, Opera, Vivaldi, Arc) |
| Idle 2 min = away, time handed back | `CGEventSource` | `GetLastInputInfo` |
| On a board: no key, click or scroll for 10 min = away | `CGEventSource` key/click/scroll | Raw Input key-down, left-click, wheel |
| Split at midnight | ✓ | ✓ |
| Sleep stops the clock | sleep notification | a gap of more than 30 s between ticks stops the session at the last tick |
| Distraction sites before 1pm blow the clean morning | ✓ | ✓ |
| Office hours, late penalty, sites closed until clock-in | ⌘W to the browser | Ctrl+W to the browser |
| Sync | every 30 s running / 5 min idle, and at 8:59 and 12:59; a small inbox check every 20 s (taunts, friends starting, live race numbers) | same |

Each computer reports its own seconds for the day with its own device id (`focus_sync` with `p_device` and `p_blown`); the server adds them up and holds each computer to real time. The Windows app registers as platform `windows`.

## Build (on a Mac)

```bash
rustup target add x86_64-pc-windows-gnu
brew install mingw-w64 makensis
cd windows && npm install
./build.sh        # → ../build/WorkClock-Setup.exe
```

`server/anon.key` must exist (it is baked into the binary at build time and is never committed). `makensis` from Homebrew crashes unless the locale is UTF-8; `build.sh` sets it.

To release: attach `build/WorkClock-Setup.exe` to the GitHub release as `WorkClock-Setup.exe`. The installer and the in-app Update button look for the newest release that has that asset, so Mac-only releases are fine.

### Layout

- `src-tauri/src/engine.rs`: the counting rules, XP, goal, score (port of Store.swift), with unit tests (`cargo test`).
- `src-tauri/src/office.rs`: office hours (Office.swift).
- `src-tauri/src/core.rs`: board state, the race, the coach's nudges (Board.swift, Coach.swift), and what the windows draw.
- `src-tauri/src/api.rs`: the Supabase RPC calls.
- `src-tauri/src/platform_win.rs`: front app, idle, raw input, browser address bar. `platform_dev.rs` stands in on a Mac.
- `ui/`: the pill, panel, setup and taunt windows (plain HTML, no build step).
- `src-tauri/examples/live.rs`: drives the live board from the command line with the app's own API code.

On a Mac, `cd windows/src-tauri && cargo run` runs the whole app with pretend input (always "typing in code.exe") and keeps its data in `~/Library/Application Support/WorkClock-WindowsDev`, apart from the Mac app's.
