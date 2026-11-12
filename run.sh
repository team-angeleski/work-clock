#!/bin/zsh
# Rebuild, install to /Applications and relaunch.
set -eo pipefail
cd "${0:A:h}"
APP="Darnell Jr..app"
pkill -x WorkClock || true
./build.sh | tail -1
[ -x "build/$APP/Contents/MacOS/WorkClock" ] || { echo "Build failed; installed app left untouched"; exit 1; }
rm -rf /Applications/WorkClock.app "/Applications/$APP"   # the old name too
ditto "build/$APP" "/Applications/$APP"
# Mark this Mac's copy as a dev build so it never auto-updates over itself.
defaults write local.workclock devBuild -bool YES
open "/Applications/$APP"
