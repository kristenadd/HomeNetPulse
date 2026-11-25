#!/bin/sh
# Build a Release copy of HomeNet Pulse and install it as /Applications/HomeNet Pulse.app.
set -eu
cd "$(dirname "$0")/.."
xcodegen generate -q
xcodebuild -project HomeNetPulse.xcodeproj -scheme HomeNetPulse -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build -quiet
osascript -e 'tell application id "com.kristenadd.HomeNetPulse" to quit' 2>/dev/null || true
sleep 1
rm -rf "/Applications/HomeNet Pulse.app"
ditto build/Build/Products/Release/HomeNetPulse.app "/Applications/HomeNet Pulse.app"
# Keep Spotlight/Launchpad pointing at the installed copy, not the build folder.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for p in build/Build/Products/*/HomeNetPulse.app; do "$LSR" -u "$PWD/$p" 2>/dev/null || true; done
"$LSR" -f "/Applications/HomeNet Pulse.app"
open "/Applications/HomeNet Pulse.app"
echo "Installed /Applications/HomeNet Pulse.app"
