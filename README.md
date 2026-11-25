# HomeNet Pulse

A native SwiftUI app for **macOS and iOS** that keeps an eye on a home network built from Apple AirPort base stations and an AT&T fiber gateway (Arris BGW210/BGW320).

## Features

- **AirPort discovery**: finds base stations over Bonjour (`_airport._tcp`) and gets each one's IPv4 address from its admin port (5009). Shows the model, firmware, Wi-Fi network name, channels and MAC addresses, plus ICMP ping health.
- **Network verification**: tap *Trust This Network* to save your base stations' Ethernet MACs and the gateway's WAN MAC. After that, the app checks that it's on *your* network by matching those MACs.
- **Internet health**: pings a configurable list of targets (default `1.1.1.1` and `8.8.8.8`) and shows latency, loss and jitter.
- **Fiber gateway health**: checks the gateway's web UI response time and ping, and parses `cgi-bin/broadbandstatistics.ha` for line state, link speed, PON status, WAN IP, the ISP gateway, ISP DNS and error/drop counters.
- **Ping from the gateway**: uses `cgi-bin/diag.ha` to have the gateway itself ping the ISP gateway, the ISP DNS servers and your internet targets. That tells you whether a problem is on your Wi-Fi or upstream at the ISP.
- **Reboot**: restarts the gateway through `cgi-bin/restart.ha`, after asking you to confirm. The button is highlighted when the internet is unreachable.
- **Keychain**: the router URL and Device Access Code are stored in the Keychain (this device only).

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) if you change `project.yml`.

```bash
xcodegen generate
open HomeNetPulse.xcodeproj
```

Pick the **HomeNetPulse** scheme, choose *My Mac* or an iPhone, and run. Run the tests with:

```bash
xcodebuild -scheme HomeNetPulse -destination 'platform=macOS' test
```

## Installing on your Mac

```bash
./scripts/install-mac.sh          # latest release
./scripts/install-mac.sh 1.0.2    # a specific version
```

This downloads the notarized DMG from the GitHub release, checks that Gatekeeper accepts it, installs it as `/Applications/HomeNet Pulse.app` and launches it. The app runs from the menu bar. Only notarized releases go into `/Applications`.

## Testing local changes

Debug builds are a separate app, **HomeNet Pulse (Debug)** (`com.kristenadd.HomeNetPulse.debug`), with their own settings, Keychain item and permissions, so testing never touches the installed release.

```bash
./scripts/run-debug-mac.sh   # build and run from the build folder (never copied to /Applications)
./scripts/install-ios.sh     # install the Debug app on paired iPhones/iPads (add --launch to open it)
```

## Installing the Debug app on iPhone and iPad

```bash
./scripts/install-ios.sh
```

Installs **HomeNet Pulse (Debug)** on every paired iPhone and iPad that's available, or only on the device IDs you pass. Add `--launch` to also open it on each device. The release app comes from Firebase App Distribution.

## Releasing

Every push to `main` runs `.github/workflows/release.yml` on one macOS runner. It:

1. works out the next version from the `vX.Y.Z` tags (`scripts/next-version.sh`): patch + 1, or `#minor` / `#major` in a commit message. Raise `MARKETING_VERSION` in `project.yml` to jump ahead. The build number is the Actions run number.
2. registers Firebase testers' iPhones and iPads with Apple (fastlane `sync_devices`).
3. builds the ad-hoc iPhone/iPad `.ipa` (`scripts/release-ios.sh`) and the Developer ID–signed, notarized and stapled Mac DMG (`scripts/release-mac.sh`).
4. tags `vX.Y.Z`, publishes a GitHub release with both files and a SHA-256 list, and uploads the `.ipa` to Firebase App Distribution (project `homenet-pulse`).

Put `[skip release]` in a commit message to push without releasing. Changes to Markdown files and the local-only scripts don't trigger a release. You can also run it by hand from **Actions ▸ Release ▸ Run workflow** and pick the version part to bump and the Firebase groups to invite. There's no in-app auto-update; install new versions from the release page or Firebase.

The signing secrets come from `~/Projects/SigningSecrets` (`./signing-secrets push kristenadd/HomeNetPulse`). To invite Firebase testers automatically on every release, add a tester group in the [Firebase console](https://console.firebase.google.com/project/homenet-pulse/appdistribution) and set the repository variable `FIREBASE_GROUPS` to its alias.

Settings shows the installed version and build at the bottom.

## Notes

- Pings use an unprivileged ICMP datagram socket, so they need no root and no helper tool. On macOS the App Sandbox needs both `network.client` and `network.server` entitlements to receive ICMP replies.
- iOS asks for Local Network permission the first time the app runs. It needs this for Bonjour discovery and for reaching the gateway.
- Gateway login follows the web UI: `hashpassword = md5(accessCode + nonce)`, and the password field is sent as asterisks.
