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

## Build

```bash
./build.sh   # universal app in build/
./run.sh     # build, install to /Applications and relaunch
```

`server/focusboard.sql` is the board's database. `server/anon.key` (not committed) holds the public Supabase key.
