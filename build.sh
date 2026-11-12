#!/bin/zsh
# Builds "Darnell Jr..app" (executable and bundle id: WorkClock / local.workclock).
set -euo pipefail
cd "${0:A:h}"
VERSION="2.1"

APP="build/Darnell Jr..app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Universal: runs on Apple Silicon and Intel Macs, macOS 15 and later.
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -target $arch-apple-macos15.0 Sources/*.swift -o "build/WorkClock-$arch"
done
lipo -create build/WorkClock-arm64 build/WorkClock-x86_64 -output "$APP/Contents/MacOS/WorkClock"

# Resources: the board's public key and the synthesised poop sound.
mkdir -p "$APP/Contents/Resources"
[ -f server/anon.key ] && cp server/anon.key "$APP/Contents/Resources/anon.key"
python3 tools/poop.py "$APP/Contents/Resources/poop.wav"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # from tools/make_icon.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.workclock</string>
  <key>CFBundleName</key><string>Darnell Jr.</string>
  <key>CFBundleDisplayName</key><string>Darnell Jr.</string>
  <key>CFBundleExecutable</key><string>WorkClock</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Darnell Jr. reads the site in your browser's front tab so only the sites you picked count as focus.</string>
</dict>
</plist>
PLIST

# Sign with the developer identity if there is one, so the Accessibility
# permission survives rebuilds. Otherwise sign ad hoc.
# RELEASE=1 signs anonymously (ad hoc) so the public download carries no personal certificate.
IDENTITY=""
if [[ -z "${RELEASE:-}" ]]; then
  IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
if [[ -n "${RELEASE:-}" ]]; then (cd build && rm -f WorkClock.zip && ditto -c -k --keepParent "Darnell Jr..app" WorkClock.zip); fi
echo "Built $APP"
