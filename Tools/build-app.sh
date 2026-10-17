#!/bin/bash
# Builds build/PurifierBar.app (release, LSUIElement) and signs it with a stable
# certificate (Tools/sign.sh), so Keychain permissions survive rebuilds.
#   build-app.sh [--install]   --install - only for an accepted stable version
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product PurifierBar 2>&1 | tail -3
APP=build/PurifierBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PurifierBar "$APP/Contents/MacOS/PurifierBar"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Localization/en.lproj Resources/Localization/uk.lproj "$APP/Contents/Resources/"
VERSION="$(git describe --tags --always 2>/dev/null || echo dev)"
# A build exactly on a release tag (v1.0) shows that version; otherwise 0.1.
SHORT_VERSION="$( (git describe --tags --exact-match 2>/dev/null || true) | sed -n 's/^v\([0-9][0-9.]*\)$/\1/p')"
SHORT_VERSION="${SHORT_VERSION:-0.1}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.purifierbar.PurifierBar</string>
  <key>CFBundleName</key><string>Purifier Bar</string>
  <key>CFBundleExecutable</key><string>PurifierBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>uk</string></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Purifier Bar controls the air purifier directly over the local network.</string>
</dict></plist>
PLIST
./Tools/sign.sh "$APP"
echo "build-app.sh: $APP"
if [ "${1:-}" = "--install" ]; then
    pkill -x PurifierBar || true
    rm -rf /Applications/PurifierBar.app && cp -R "$APP" /Applications/
    codesign --verify --deep --strict /Applications/PurifierBar.app && open /Applications/PurifierBar.app
    echo "build-app.sh: installed to /Applications"
fi
