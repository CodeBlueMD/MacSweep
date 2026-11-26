#!/bin/zsh
# Packages MacSweep.app into MacSweep-<version>.dmg. Run ./make-app.sh first.
# The app is ad-hoc signed and NOT notarized; no personal certificate is used.
set -euo pipefail
cd "${0:A:h}/.."
VERSION=${1:-$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" MacSweep.app/Contents/Info.plist)}
STAGE=$(mktemp -d)
cp -R MacSweep.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "MacSweep-$VERSION.dmg"
hdiutil create -volname "MacSweep" -srcfolder "$STAGE" -ov -format UDZO "MacSweep-$VERSION.dmg"
echo "Built $PWD/MacSweep-$VERSION.dmg"
