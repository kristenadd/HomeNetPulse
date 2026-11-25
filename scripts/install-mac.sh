#!/bin/sh
# Installs the notarized HomeNet Pulse from a GitHub release into /Applications.
#
#   scripts/install-mac.sh            # the latest release
#   scripts/install-mac.sh 1.0.2      # a specific version
#
# Only notarized releases go into /Applications. For local testing use scripts/run-debug-mac.sh,
# which runs "HomeNet Pulse (Debug)" (a separate app, com.kristenadd.HomeNetPulse.debug) from the
# build folder.
set -eu
cd "$(dirname "$0")/.."

tag=${1:+v${1#v}}
tmp=$(mktemp -d)
trap 'hdiutil detach -quiet "$tmp/mnt" 2>/dev/null || true; rm -rf "$tmp"' EXIT

gh release download ${tag:+"$tag"} --pattern 'HomeNetPulse-*.dmg' --dir "$tmp"
dmg=$(ls "$tmp"/HomeNetPulse-*.dmg)
echo "Downloaded $(basename "$dmg")"

# Refuse anything Gatekeeper wouldn't open.
spctl --assess --type open --context context:primary-signature "$dmg"
xcrun stapler validate -q "$dmg"

mkdir "$tmp/mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$tmp/mnt" "$dmg"
spctl --assess --type execute "$tmp/mnt/HomeNet Pulse.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$tmp/mnt/HomeNet Pulse.app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$tmp/mnt/HomeNet Pulse.app/Contents/Info.plist")

osascript -e 'tell application id "com.kristenadd.HomeNetPulse" to quit' 2>/dev/null || true
sleep 1
rm -rf "/Applications/HomeNet Pulse.app"
ditto "$tmp/mnt/HomeNet Pulse.app" "/Applications/HomeNet Pulse.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/HomeNet Pulse.app"
open "/Applications/HomeNet Pulse.app"
echo "Installed HomeNet Pulse $version ($build) in /Applications"
