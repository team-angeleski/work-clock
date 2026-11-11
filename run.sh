#!/bin/zsh
# Rebuild, install to /Applications and relaunch.
set -e
cd "${0:A:h}"
pkill -f WorkClock.app/Contents/MacOS || true
./build.sh | tail -1
rm -rf /Applications/WorkClock.app
ditto build/WorkClock.app /Applications/WorkClock.app
open /Applications/WorkClock.app
