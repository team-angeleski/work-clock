#!/bin/zsh
# Builds the Windows installer on a Mac (cross-compiled): ../build/WorkClock-Setup.exe
# Needs: rustup target add x86_64-pc-windows-gnu; brew install mingw-w64 makensis; npm install
set -euo pipefail
cd "${0:A:h}"
[ -s ../server/anon.key ] || { echo "server/anon.key is missing: the build would have no board key"; exit 1; }
python3 ../tools/poop.py ui/poop.wav
[ -d node_modules ] || npm install --silent
# makensis from Homebrew crashes (std::bad_alloc) unless the locale is UTF-8.
rm -rf src-tauri/target/x86_64-pc-windows-gnu/release/bundle/nsis
LC_ALL=en_US.UTF-8 npx tauri build --target x86_64-pc-windows-gnu --bundles nsis
mkdir -p ../build
# The asset keeps its old name: install.ps1 and the in-app updater look for WorkClock-Setup.exe.
cp src-tauri/target/x86_64-pc-windows-gnu/release/bundle/nsis/*_x64-setup.exe ../build/WorkClock-Setup.exe
echo "Built ../build/WorkClock-Setup.exe"
