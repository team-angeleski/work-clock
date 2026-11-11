# Work Clock

A focus clock that sits next to your Mac's Dock. Pick the apps (or browser sites) you work in, click to start, and it only counts time while you're actually in them.

Race your friends: the board ranks today's focus score, and whoever wins the day gets three taunts that pop up on everyone else's screen.

## Install

Paste into Terminal (replace `CODE` with your friend's board code, or leave it off):

```bash
curl -fsSL https://raw.githubusercontent.com/team-angeleski/work-clock/main/install.sh | bash -s CODE
```

Needs macOS 15 or later, on an Apple Silicon or Intel Mac.

## How scoring works

- 1 point per focused minute in the apps or sites you picked.
- **Early bird:** focus before 9am counts 1.5×.
- **Clean morning:** no Instagram, YouTube, TikTok, X, Reddit, Facebook, Netflix or Twitch before 1pm, plus at least an hour of focus by then: +30.
- Idle for 2 minutes, or no key, click or scroll for 10 minutes, and the time is handed back.
- The server only accepts focus that fits in the real time since your last check-in.

## The coach

Small pushes back to work, all as Mac notifications plus a shake of the clock:

- **Drifting:** on a distraction site mid-session, the clock shakes at 20s and 60s and notifies you at 2 minutes. In any other non-work app: a shake at 90s, a notification at 5 minutes. Idle time never nags.
- **Not started:** at your Mac for 15 minutes without starting, you get your rank and the race. Again at 90 minutes.
- **Friends:** a notification when a friend starts focusing and you haven't (at most hourly), when someone overtakes you, and when you take the lead.
- **Streak at risk:** at 8pm, if your goal isn't hit and you have a streak going.
- **Recap:** at 9pm, today's time, rank, the race and tomorrow's goal.

One click on the clock starts a session with your usual apps. Option-click (or "Change apps" in the panel) picks again.

## Updates

The panel shows an Update button when a new release is out. After updating, macOS may ask you to allow Accessibility again (System Settings → Privacy & Security → Accessibility).

## Build

```bash
./build.sh   # universal app in build/
./run.sh     # build, install to /Applications and relaunch
```

`server/focusboard.sql` is the board's database. `server/anon.key` (not committed) holds the public Supabase key.
