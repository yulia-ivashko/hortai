#!/bin/zsh
# Builds build/Hortai.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Hortai.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Hortai "$APP/Contents/MacOS/Hortai"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "$PWD/$APP"
