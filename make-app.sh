#!/bin/zsh
# Builds MacSweep.app (release, ad-hoc signed) next to this script.
set -euo pipefail
cd "${0:A:h}"
swift build -c release
APP=MacSweep.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp .build/release/MacSweep "$APP/Contents/MacOS/MacSweep"
ICONSET=$(mktemp -d)/AppIcon.iconset
.build/release/MacSweep --make-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MacSweep</string>
  <key>CFBundleIdentifier</key><string>app.macsweep</string>
  <key>CFBundleExecutable</key><string>MacSweep</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>MacSweep lists your connected Bluetooth devices in the Mac Health menu.</string>
</dict></plist>
PLIST
codesign --force -s - "$APP"
echo "Built $PWD/$APP"
