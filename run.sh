#!/bin/zsh
# Rebuild, install to /Applications and relaunch.
set -eo pipefail
cd "${0:A:h}"
pkill -f WorkClock.app/Contents/MacOS || true
./build.sh | tail -1
[ -x build/WorkClock.app/Contents/MacOS/WorkClock ] || { echo "Build failed; installed app left untouched"; exit 1; }
rm -rf /Applications/WorkClock.app
ditto build/WorkClock.app /Applications/WorkClock.app
# Mark this Mac's copy as a dev build so it never auto-updates over itself.
defaults write local.workclock devBuild -bool YES
open /Applications/WorkClock.app
