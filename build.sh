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
# Layered icon (light, dark, tinted, clear); actool needs absolute paths.
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$PWD/$APP/Contents/Resources/.icon-partial.plist" >/dev/null
rm -f "$APP/Contents/Resources/.icon-partial.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
# The bundle was deleted and recreated; without this Finder keeps showing a blank icon for it.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/$APP"
echo "$PWD/$APP"
