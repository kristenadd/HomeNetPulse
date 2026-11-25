#!/bin/sh
# Builds and runs "HomeNet Pulse (Debug)" (com.kristenadd.HomeNetPulse.debug, Mac only) from the build folder.
# It's a separate app from the notarized release in /Applications: its own settings, Keychain item
# and permissions, so testing never touches the everyday copy. It is never copied to /Applications.
set -eu
cd "$(dirname "$0")/.."
xcodegen generate -q
xcodebuild -project HomeNetPulse.xcodeproj -scheme HomeNetPulse -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build build -quiet
osascript -e 'tell application id "com.kristenadd.HomeNetPulse.debug" to quit' 2>/dev/null || true
sleep 1
open build/Build/Products/Debug/HomeNetPulse.app
echo "Running HomeNet Pulse (Debug) from build/Build/Products/Debug"
