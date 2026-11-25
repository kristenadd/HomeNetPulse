#!/bin/sh
# Build "HomeNet Pulse (Debug)" (com.kristenadd.HomeNetPulse.debug) and install it on every paired,
# available iPhone/iPad. It sits next to the release app from Firebase without sharing anything.
# Usage: scripts/install-ios.sh [--launch] [device-udid ...]
#   --launch  also open the app on each device after installing (off by default)
set -eu
launch=0
if [ "${1:-}" = "--launch" ]; then launch=1; shift; fi
cd "$(dirname "$0")/.."
xcodegen generate -q
xcodebuild -project HomeNetPulse.xcodeproj -scheme HomeNetPulse -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build -quiet
APP=build/Build/Products/Debug-iphoneos/HomeNetPulse.app

if [ $# -gt 0 ]; then
  devices="$*"
else
  # Physical iPhones/iPads that are connected or paired and reachable.
  devices=$(xcrun devicectl list devices 2>/dev/null \
    | awk '/physical/ && /(iPhone|iPad)/ && /(connected|available)/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i }')
fi

for d in $devices; do
  echo "Installing on $d…"
  xcrun devicectl device install app --device "$d" "$APP"
  if [ "$launch" = 1 ]; then
    xcrun devicectl device process launch --device "$d" com.kristenadd.HomeNetPulse.debug || true
  fi
done
