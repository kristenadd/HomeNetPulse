#!/bin/bash
# Builds an ad-hoc HomeNet Pulse .ipa for registered iPhones and iPads.
#
#   scripts/release-ios.sh
#
# Output: build/release/HomeNetPulse-<version>-ios.ipa
#
# Signing is automatic: Xcode makes or updates the ad-hoc profile, which holds every device
# registered for the team. In CI it signs in with the App Store Connect API key:
#   ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID   (optional locally: Xcode's account is used instead)
# Environment: VERSION, BUILD_NUMBER as in release-mac.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

# CI only: a local release build is a second copy of com.kristenadd.HomeNetPulse on this Mac, which
# confuses macOS permissions for the notarized app in /Applications. Set ALLOW_LOCAL_RELEASE=1 to
# override (and delete build/release afterwards).
if [ -z "${CI:-}" ] && [ "${ALLOW_LOCAL_RELEASE:-0}" != 1 ]; then
    echo "error: release builds run in GitHub Actions. Use scripts/run-debug-mac.sh to test locally." >&2
    exit 1
fi

APP_NAME="HomeNetPulse"
TEAM_ID="B4H429V95D"
OUT="build/release"
ARCHIVE="build/ios/$APP_NAME-ios.xcarchive"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

VERSION="${VERSION:-$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\} *$/\1/p' project.yml | head -1)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([0-9]*\)"\{0,1\} *$/\1/p' project.yml | head -1)}"
IPA="$OUT/$APP_NAME-$VERSION-ios.ipa"

AUTH=(-allowProvisioningUpdates)
if [ -n "${ASC_KEY_PATH:-}" ]; then
    AUTH+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

rm -rf build/ios
mkdir -p build/ios "$OUT"

step "Archiving HomeNet Pulse $VERSION ($BUILD_NUMBER) for iOS"
xcodebuild archive -quiet \
    -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -derivedDataPath build/ios/DerivedData \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    "${AUTH[@]}"

step "Exporting the ad-hoc .ipa"
cat > build/ios/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>release-testing</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>thinning</key><string>&lt;none&gt;</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/ios/ExportOptions.plist \
    -exportPath build/ios/export "${AUTH[@]}"
cp build/ios/export/*.ipa "$IPA"

step "Provisioned devices"
unzip -o -q "$IPA" 'Payload/*/embedded.mobileprovision' -d build/ios/ipa
security cms -D -i build/ios/ipa/Payload/*/embedded.mobileprovision > build/ios/profile.plist
/usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' build/ios/profile.plist || true
/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.networking.wifi-info' build/ios/profile.plist >/dev/null \
    || fail "The profile is missing the Access Wi-Fi Information capability"

echo "$IPA"
