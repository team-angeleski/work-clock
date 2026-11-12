# Darnell Jr.

Your little focus buddy (formerly Work Clock).

A focus clock that sits next to your Mac's Dock. Pick the apps (or browser sites) you work in, click to start, and it only counts time while you're actually in them.

Race your friends: the board ranks today's focus score, and whoever wins the day gets three taunts that pop up on everyone else's screen.

## Install

Paste into Terminal (replace `CODE` with your friend's board code, or leave it off):

```bash
curl -fsSL https://raw.githubusercontent.com/team-angeleski/work-clock/main/install.sh | bash -s CODE
```

Needs macOS 15 or later, on an Apple Silicon or Intel Mac.

### Windows

Paste into PowerShell (Start → type "PowerShell" → Enter):

```powershell
irm https://raw.githubusercontent.com/team-angeleski/work-clock/main/windows/install.ps1 | iex
```

To join a friend's board straight away, put the code at the end instead:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/team-angeleski/work-clock/main/windows/install.ps1))) CODE
```

Needs Windows 10 or 11 (64-bit). Already have an account on your Mac? Choose **I have an account** in setup and sign in with the same email: both computers add up. See [windows/README.md](windows/README.md).

## How scoring works

- 1 point per focused minute in the apps or sites you picked.
- **Late:** −1 per minute late to clock in (see Office hours).
- **Early bird:** focus before 9am counts 1.5×.
- **Clean morning:** no Instagram, YouTube, TikTok, X, Reddit, Facebook, Netflix or Twitch before 1pm, plus at least an hour of focus by then: +30.
- No mouse or keyboard for 30 seconds, or no key, click or scroll for 10 minutes, and the time is handed back.
- The server only accepts focus that fits in the real time since your last check-in.

## Office hours

Working from home, nobody's waiting for you at 9. Office hours fix that:

- Pick a start time and workdays. Your first 5 focused minutes clock you in.
- Late costs a point a minute after 5 minutes' grace (max 120). At 15 minutes late your friends get an email; at an hour, another.
- Changes only take effect the next day, so you can't push today back once you're running late.
- Until you clock in on a workday, YouTube, Instagram, TikTok and co get closed.

## Several computers

Your email is your account. On another computer (Mac or Windows), install Darnell Jr. and choose **Sign in** in setup: a 6-digit code is emailed to you. Every computer reports its own time and the server adds them up, so your clock, week, streak and the race show your total. A computer can only add as much as real time allows since it last checked in, and a day can never hold more than the hours since midnight.

Settings → Account → **Sign Out** stops counting that one computer; **Delete** removes the account everywhere.

## Email alerts

Your email is part of your account (required to join). You get an email when a friend passes you, when you're late, and when you're taunted. Sent by the database (pg_cron + pg_net) through Resend.

## The coach

Small pushes back to work, all as Mac notifications plus a shake of the clock:

- **Drifting:** on a distraction site mid-session, the clock shakes at 20s and 60s and notifies you at 2 minutes. In any other non-work app: a shake at 90s, a notification at 5 minutes. Idle time never nags.
- **Clock in:** a reminder 10 minutes before your start, a shake at your start time, and a nudge at 15 minutes late.
- **Not started:** at your Mac for 15 minutes without starting, you get your rank and the race. Again at 90 minutes.
- **Friends:** a notification within seconds when a friend starts working (once per 20 minutes per friend), when someone overtakes you, and when you take the lead. Taunts pop up straight away.
- **Streak at risk:** at 8pm, if your goal isn't hit and you have a streak going.
- **Recap:** at 9pm, today's time, rank, the race and tomorrow's goal.

Click the clock, click the apps you'll work in, click the clock again. Tap twice without picking to reuse last time's apps.

## Updates

Darnell Jr. checks for a new release every hour and installs it by itself as soon as you're not in a focus session (it restarts in a couple of seconds; your time and board stay). The Update button in the panel installs it straight away. After an update, macOS may ask you to switch Accessibility back on; the app opens that setting for you.

## Build

```bash
./build.sh   # universal app in build/
./run.sh     # build, install to /Applications and relaunch
```

`windows/build.sh` builds the Windows installer (`build/WorkClock-Setup.exe`) on a Mac; see [windows/README.md](windows/README.md).

`server/focusboard.sql`, `server/office_hours.sql`, `server/email_required.sql` and `server/devices.sql` are the board's database, in order. `tools/set-mail-key.sh` copies the Resend key into Supabase Vault so emails can send. `server/anon.key` (not committed) holds the public Supabase key.
