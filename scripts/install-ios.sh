#!/bin/sh
# Build a Release copy of HomeNet Pulse and install it on every paired, available iPhone/iPad.
# Usage: scripts/install-ios.sh [device-udid ...]
set -eu
cd "$(dirname "$0")/.."
xcodegen generate -q
xcodebuild -project HomeNetPulse.xcodeproj -scheme HomeNetPulse -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build -quiet
APP=build/Build/Products/Release-iphoneos/HomeNetPulse.app

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
  xcrun devicectl device process launch --device "$d" com.kristenadd.HomeNetPulse || true
done
