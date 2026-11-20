#!/bin/zsh
# Builds "Darnell Jr..app" (executable and bundle id: WorkClock / local.workclock).
set -euo pipefail
cd "${0:A:h}"
VERSION="2.5"

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

# Signed with a neutral self-signed certificate named "Darnell Jr." (no name or email in it), kept in
# this Mac's login keychain. One identity for every build means macOS keeps Accessibility across
# updates. Without it a release would change identity, so RELEASE=1 refuses to build.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"Darnell Jr\."/ {print $2; exit}')
if [[ -z "$IDENTITY" ]]; then
  [[ -n "${RELEASE:-}" ]] && { echo 'No "Darnell Jr." signing certificate in the keychain'; exit 1; }
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"
if [[ -n "${RELEASE:-}" ]]; then (cd build && rm -f WorkClock.zip && ditto -c -k --keepParent "Darnell Jr..app" WorkClock.zip); fi
echo "Built $APP"
