#!/bin/bash
# Builds a Developer ID–signed, notarized and stapled HomeNet Pulse DMG.
#
#   scripts/release-mac.sh
#
# Output: build/release/HomeNetPulse-<version>.dmg
#
# Needs a "Developer ID Application" certificate in a keychain on the search list and notary
# credentials saved as $NOTARY_PROFILE (the CI workflow sets both up; see .github/workflows/release.yml).
#
# Environment:
#   VERSION, BUILD_NUMBER   version (1.2.3) and build number to stamp (default: project.yml's)
#   SIGNING_IDENTITY        default "Developer ID Application"
#   NOTARY_PROFILE          notarytool keychain profile (default HomeNetPulse-Notary)
#   NOTARY_KEYCHAIN         keychain holding that profile (default: the search list)
#   SKIP_NOTARIZATION=1     sign and package only (local testing)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="HomeNetPulse"
DISPLAY_NAME="HomeNet Pulse"
TEAM_ID="B4H429V95D"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-HomeNetPulse-Notary}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"
NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
[ -n "${NOTARY_KEYCHAIN:-}" ] && NOTARY_AUTH+=(--keychain "$NOTARY_KEYCHAIN")
OUT="build/release"
ARCHIVE="$OUT/$APP_NAME-mac.xcarchive"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

VERSION="${VERSION:-$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\} *$/\1/p' project.yml | head -1)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([0-9]*\)"\{0,1\} *$/\1/p' project.yml | head -1)}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "VERSION must look like 1.2.3, not \"$VERSION\""
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "BUILD_NUMBER must be a whole number, not \"$BUILD_NUMBER\""
DMG="$OUT/$APP_NAME-$VERSION.dmg"

step "Checking prerequisites"
security find-identity -v -p codesigning | grep -q "\"$SIGNING_IDENTITY" || fail "No \"$SIGNING_IDENTITY\" certificate found"
if [ "$SKIP_NOTARIZATION" != 1 ]; then
    xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 || fail "No notary credentials saved as \"$NOTARY_PROFILE\""
fi
echo "HomeNet Pulse $VERSION ($BUILD_NUMBER), signing as \"$SIGNING_IDENTITY\""

rm -rf "$OUT"
mkdir -p "$OUT"

step "Archiving"
xcodebuild archive -quiet \
    -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
    PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

APP="$OUT/$DISPLAY_NAME.app"
ditto "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
signature=$(codesign -d --verbose=2 "$APP" 2>&1)
[[ "$signature" == *"Authority=Developer ID Application"* ]] || fail "Not signed with Developer ID"
[[ "$signature" == *"(runtime)"* ]] || fail "Hardened runtime isn't enabled"
entitlements=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
[[ "$entitlements" != *"get-task-allow"* ]] || fail "Release build has the debugging entitlement"
built=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[ "$built" = "$VERSION" ] || fail "Built version is $built, expected $VERSION"

notarize() {
    xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --output-format json \
        | tee "$OUT/notary.json" | python3 -c 'import json,sys; r=json.load(sys.stdin); print("Notarization:", r["status"]); sys.exit(r["status"] != "Accepted")' \
        || { id=$(python3 -c 'import json; print(json.load(open("'"$OUT"'/notary.json"))["id"])'); \
             xcrun notarytool log "$id" "${NOTARY_AUTH[@]}"; fail "Notarization failed (log above)"; }
}

if [ "$SKIP_NOTARIZATION" != 1 ]; then
    step "Notarizing the app"
    ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"
    notarize "$OUT/$APP_NAME.zip"
    rm "$OUT/$APP_NAME.zip"
    xcrun stapler staple "$APP"
fi

step "Building the DMG"
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$DISPLAY_NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "$DISPLAY_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGING"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"

if [ "$SKIP_NOTARIZATION" != 1 ]; then
    step "Notarizing the DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    step "Checking Gatekeeper"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    spctl --assess --type execute --verbose=2 "$APP"
fi

rm -f "$OUT/notary.json"
step "Done"
echo "$DMG"
