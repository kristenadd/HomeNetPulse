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
./scripts/install-mac.sh
```

This builds a Release copy, installs it as `/Applications/HomeNet Pulse.app` and launches it. The app runs from the menu bar. Run the script again after pulling changes to update it.

## Installing on iPhone and iPad

```bash
./scripts/install-ios.sh
```

Builds a Release copy and installs and launches it on every paired iPhone and iPad that's available, or only on the device IDs you pass.

## Notes

- Pings use an unprivileged ICMP datagram socket, so they need no root and no helper tool. On macOS the App Sandbox needs both `network.client` and `network.server` entitlements to receive ICMP replies.
- iOS asks for Local Network permission the first time the app runs. It needs this for Bonjour discovery and for reaching the gateway.
- Gateway login follows the web UI: `hashpassword = md5(accessCode + nonce)`, and the password field is sent as asterisks.
