#!/bin/bash
# Writes the Sparkle update feed (appcast.xml) for a release DMG and signs it.
#
#   scripts/make-appcast.sh <dmg> <version> <build-number> [release-notes.html]
#
# Output: appcast.xml next to the DMG. The release workflow uploads both to the GitHub release, and
# the Mac app reads the newest release's feed (SUFeedURL in project.yml).
#
# Signing key: SPARKLE_PRIVATE_KEY if set (as in CI), otherwise the key generate_keys saved in your
# keychain under the account "HomeNetPulse". The feed lists only this release; Sparkle only needs
# the newest version.
set -euo pipefail

cd "$(dirname "$0")/.."

[ $# -ge 3 ] || { echo "usage: $0 <dmg> <version> <build-number> [release-notes.html]" >&2; exit 2; }
DMG="$1" VERSION="$2" BUILD="$3" NOTES="${4:-}"
REPO="${GITHUB_REPOSITORY:-kristenadd/HomeNetPulse}"
# Sparkle's command-line tools come with the package: release-mac.sh's DerivedData in CI, the
# local build folder otherwise.
for BIN in build/release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin build/SourcePackages/artifacts/sparkle/Sparkle/bin; do
    [ -x "$BIN/sign_update" ] && break
done
[ -x "$BIN/sign_update" ] || { echo "Sparkle's tools weren't found; build the app first so Xcode fetches Sparkle" >&2; exit 1; }
[ -f "$DMG" ] || { echo "No such file: $DMG" >&2; exit 1; }

sign() {
    if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
        printf '%s' "$SPARKLE_PRIVATE_KEY" | "$BIN/sign_update" --ed-key-file - "$@"
    else
        "$BIN/sign_update" --account HomeNetPulse "$@"
    fi
}

signature=$(sign -p "$DMG")
length=$(stat -f %z "$DMG")
minimum=$(sed -n 's/^ *macOS: *"\{0,1\}\([0-9.]*\)"\{0,1\} *$/\1/p' project.yml | head -1)
APPCAST="$(dirname "$DMG")/appcast.xml"

python3 - "$APPCAST" "$VERSION" "$BUILD" "$signature" "$length" "${minimum:-15.0}" \
    "https://github.com/$REPO/releases/download/v$VERSION/$(basename "$DMG")" \
    "https://github.com/$REPO/releases/tag/v$VERSION" "$NOTES" <<'EOF'
import sys
from email.utils import formatdate
from xml.sax.saxutils import escape, quoteattr

out, version, build, signature, length, minimum, url, page, notes_path = sys.argv[1:]
notes = open(notes_path).read() if notes_path else f'<p><a href="{page}">Release notes</a></p>'
notes = notes.replace("]]>", "]]]]><![CDATA[>")  # keep CDATA intact
open(out, "w").write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>HomeNet Pulse</title>
    <link>{escape(page)}</link>
    <item>
      <title>HomeNet Pulse {escape(version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum)}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{escape(page)}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{notes}]]></description>
      <enclosure url={quoteattr(url)} length={quoteattr(length)} type="application/octet-stream" sparkle:edSignature={quoteattr(signature)}/>
    </item>
  </channel>
</rss>
""")
EOF

# Embed a signature in the feed itself (the app requires it: SURequireSignedFeed).
sign --disable-signing-warning "$APPCAST"
echo "$APPCAST"
