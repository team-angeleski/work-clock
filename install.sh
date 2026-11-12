#!/bin/bash
# Darnell Jr. installer (the focus clock, formerly Work Clock).
#   curl -fsSL https://raw.githubusercontent.com/team-angeleski/work-clock/main/install.sh | bash -s BOARDCODE
# Downloads the app, puts it in Applications, and opens it ready to join the board.
set -euo pipefail

CODE="${1:-}"
URL="https://github.com/team-angeleski/work-clock/releases/latest/download/WorkClock.zip"

if [[ "$(uname)" != "Darwin" ]]; then echo "This installer is for Macs. On Windows, use the PowerShell line instead."; exit 1; fi
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if (( MAJOR < 15 )); then echo "Darnell Jr. needs macOS 15 or later (you have $(sw_vers -productVersion))."; exit 1; fi

echo "⏱  Installing Darnell Jr.…"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/WorkClock.zip"
ditto -x -k "$TMP/WorkClock.zip" "$TMP/app"
SRC=$(find "$TMP/app" -maxdepth 1 -name "*.app" | head -1)
[[ -n "$SRC" ]] || { echo "The download didn't contain the app. Try again in a minute."; exit 1; }
NAME=$(basename "$SRC")

# Replace any older copy, under its old or new name. Focus history is kept (Application Support).
pkill -x WorkClock 2>/dev/null || true
sleep 1
rm -rf /Applications/WorkClock.app "/Applications/Darnell Jr..app"
mv "$SRC" /Applications/
xattr -dr com.apple.quarantine "/Applications/$NAME" 2>/dev/null || true

if [[ -n "$CODE" ]]; then defaults write local.workclock inviteCode -string "$CODE"; fi
open "/Applications/$NAME"

cat <<'MSG'

✅ Darnell Jr. is installed and open.

A setup window walks you through the rest: permissions, your email,
your start time, and joining your friends' board. Takes a minute.

MSG
