#!/bin/bash
# Work Clock installer.
#   curl -fsSL https://raw.githubusercontent.com/team-angeleski/work-clock/main/install.sh | bash -s BOARDCODE
# Downloads the app, puts it in Applications, and opens it ready to join the board.
set -euo pipefail

CODE="${1:-}"
URL="https://github.com/team-angeleski/work-clock/releases/latest/download/WorkClock.zip"

if [[ "$(uname)" != "Darwin" ]]; then echo "Work Clock is Mac only for now."; exit 1; fi
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if (( MAJOR < 15 )); then echo "Work Clock needs macOS 15 or later (you have $(sw_vers -productVersion))."; exit 1; fi

echo "⏱  Installing Work Clock…"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/WorkClock.zip"
ditto -x -k "$TMP/WorkClock.zip" "$TMP"

# Replace any older copy (your focus history is kept; it lives in Application Support).
pkill -x WorkClock 2>/dev/null || true
sleep 1
rm -rf /Applications/WorkClock.app
mv "$TMP/WorkClock.app" /Applications/
xattr -dr com.apple.quarantine /Applications/WorkClock.app 2>/dev/null || true

if [[ -n "$CODE" ]]; then defaults write local.workclock inviteCode -string "$CODE"; fi
open /Applications/WorkClock.app

cat <<'EOF'

✅ Work Clock is installed and open (look next to your Dock).

Next:
  1. Allow it under System Settings → Privacy & Security → Accessibility,
     so it can sit right next to your Dock.
  2. Type your name in the box that pops up and press Join.
  3. Click the clock, click the apps you work in, click the clock again. Go.

EOF
