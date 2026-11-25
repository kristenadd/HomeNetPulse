import Foundation

/// Plain-text reports of what the app currently knows, written to be pasted into a chat with an
/// AI assistant (or a support ticket) when diagnosing a network problem. Never includes the
/// gateway's access code.
@MainActor
enum NetworkReport {
    /// Everything: the whole chain from this device out to the internet, plus the LAN devices.
    static func network(_ m: DashboardModel) -> String {
        var r = Report()
        r.title("Home network diagnostic report")
        r.line("Generated", Self.timestamp(Date()))
        r.line("App", "\(AppInfo.displayName) \(Self.appVersion)")
        r.line("Overall", "\(m.overallHealth.label): \(m.overallSummary)")
        r.line("Network verification", Self.verificationText(m.verification))
        r.line("Topology", "This device → Wi-Fi base station → main AirPort router → fiber gateway (\(m.settings.routerBaseURL?.host() ?? "?")) → ISP → internet")
        r.blank()
        thisDevice(m, into: &r)
        internet(m, into: &r)
        gateway(m, into: &r)
        if let main = m.mainRouter { station(main, m, into: &r) }
        for s in m.extenders { station(s, m, into: &r) }
        if m.baseStations.isEmpty {
            r.section("AirPort base stations")
            r.line("Status", m.discoveryError ?? "None found on Bonjour")
        }
        devices(m, into: &r)
        return r.text
    }

    static func internet(_ m: DashboardModel) -> String {
        var r = header("Internet", m); internet(m, into: &r); return r.text
    }

    static func gateway(_ m: DashboardModel) -> String {
        var r = header("Fiber gateway", m); gateway(m, into: &r); return r.text
    }

    static func station(_ s: BaseStation, _ m: DashboardModel) -> String {
        var r = header("AirPort base station \(s.name)", m); station(s, m, into: &r); return r.text
    }

    static func devices(_ m: DashboardModel) -> String {
        var r = header("Devices on the local network", m); devices(m, into: &r); return r.text
    }

    // MARK: Sections

    private static func thisDevice(_ m: DashboardModel, into r: inout Report) {
        r.section("This device")
        #if os(macOS)
        r.line("Platform", "Mac, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #else
        r.line("Platform", "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #endif
        r.line("On local network", m.onLocalNetwork.map { $0 ? "Yes (Wi-Fi or Ethernet)" : "No (cellular or offline)" })
        r.line("IP address", m.lanInterface.map { "\($0.ip) (\($0.cidr), \($0.name))" })
        r.line("Default gateway", m.defaultGateway)
        r.line("Configured DNS servers", m.systemDNS.isEmpty ? nil : m.systemDNS.joined(separator: ", "))
        if let w = m.wifi {
            r.line("Wi-Fi network", w.ssid)
            r.line("Access point (BSSID)", w.bssid)
            r.line("Band / channel", [w.band?.rawValue, w.channel.map { "channel \($0)" }, w.channelWidthMHz.map { "\($0) MHz wide" }]
                .compactMap { $0 }.joined(separator: ", ").nilIfEmpty)
            r.line("Signal", [w.rssi.map { "\($0) dBm" }, w.signalQuality].compactMap { $0 }.joined(separator: " ").nilIfEmpty)
            r.line("Noise", w.noise.map { "\($0) dBm" })
            r.line("Signal-to-noise", w.snr.map { "\($0) dB" })
            r.line("Link rate", w.txRateMbps.map { String(format: "%.0f Mbps", $0) })
            let station = m.baseStations.first { m.isConnected($0) }
            r.line("Connected base station", station.map { s in
                [s.name, m.connectionMatch?.label].compactMap { $0 }.joined(separator: ", ")
            })
        } else {
            r.line("Wi-Fi", "Not connected or not readable")
        }
        r.blank()
    }

    private static func internet(_ m: DashboardModel, into r: inout Report) {
        r.section("Internet")
        r.line("Health", "\(m.internetHealth.label) (pings \(m.pingHealth.label), DNS \(m.dnsHealth.label))")
        r.sub("Pings from this device")
        for target in m.settings.pingTargets {
            r.item(target, m.internetPings[target].map(pingText) ?? "not run yet")
        }
        if !m.dnsResults.isEmpty {
            r.sub("DNS checks (direct queries to each server, bypassing the cache)")
            for d in m.dnsResults {
                r.item("\(d.server.label) \(d.server.ip)", "\(d.health.label), \(d.summary)")
                for l in d.lookups {
                    let result = l.ok
                        ? "\(l.addresses.joined(separator: ", "))" + (l.ms.map { String(format: " in %.0f ms", $0) } ?? "")
                        : "FAILED: \(l.error ?? "no answer")"
                    r.item("  \(l.host)", result)
                }
            }
        }
        r.blank()
    }

    private static func gateway(_ m: DashboardModel, into r: inout Report) {
        r.section("Fiber gateway (ISP-provided)")
        r.line("Address", m.settings.routerBaseURL?.absoluteString)
        r.line("Health", m.gatewayHealth.label)
        r.line("Web interface", m.routerReachable.map { $0 ? "Reachable" + (m.routerLatencyMs.map { String(format: ", %.0f ms", $0) } ?? "") : "Unreachable" })
        r.line("Ping from this device", m.routerPing.map(pingText))
        r.line("Error", m.routerError)
        if let b = m.broadband {
            r.sub("Broadband")
            r.item("Line state", b.lineState)
            r.item("Link speed", b.speedMbps.map { "\($0) Mbps" })
            r.item("Fiber (PON) state", [b.ponFriendly, b.ponExplanation].compactMap { $0 }.joined(separator: ": ").nilIfEmpty)
            r.item("WAN IPv4", b.wanIPv4)
            r.item("ISP gateway", b.gatewayIPv4)
            r.item("ISP primary DNS", b.primaryDNS)
            r.item("ISP secondary DNS", b.secondaryDNS)
            r.item("WAN MAC", b.wanMAC)
            r.item("Receive errors", b.receiveErrors)
            r.item("Receive drops", b.receiveDrops)
        }
        if let run = m.latestSpeedRun {
            r.sub("Latest speed test (run by the gateway)")
            r.item("When", run.time.map(timestamp) ?? run.timeText)
            r.item("Download", run.download.map(speedText))
            r.item("Upload", run.upload.map(speedText))
            r.item("Latency", run.latencyMs.map { String(format: "%.0f ms", $0) })
            if m.speedRuns.count > 1 {
                let older = m.speedRuns.dropFirst().prefix(4).map { run in
                    "\(run.time.map(timestamp) ?? run.timeText): ↓\(run.download?.mbps.map { String(format: "%.0f", $0) } ?? "?") ↑\(run.upload?.mbps.map { String(format: "%.0f", $0) } ?? "?") Mbps"
                }
                r.item("Earlier tests", older.joined(separator: "; "))
            }
        }
        if m.devicePings.contains(where: { $0.result != nil || $0.error != nil }) {
            r.sub("Pings run by the gateway itself")
            for p in m.devicePings {
                r.item("\(p.label) \(p.host)", p.error.map { "FAILED: \($0)" } ?? p.result.map(pingText) ?? "not run")
            }
        }
        if let f = m.fiber {
            r.sub("Fiber optics (\(f.status.label))")
            for metric in f.metrics {
                let range = metric.rangeText.map { ", \($0)" } ?? ""
                r.item(metric.displayName, "\(metric.valueText), \(metric.status.label)\(range)")
            }
            r.sub("Optical module (\(f.moduleUp.map { $0 ? "Up" : "Down" } ?? "unknown"))")
            r.item("Link", f.value("Link State"))
            r.item("Optical WAN", f.value("Optical WAN Operational Status"))
            r.item("Wavelength", f.wavelength)
            r.item("Module", f.module)
        }
        r.blank()
    }

    private static func station(_ s: BaseStation, _ m: DashboardModel, into r: inout Report) {
        let isMain = m.mainRouter?.id == s.id
        r.section("AirPort: \(s.name) (\(isMain ? "main router" : "extender"))")
        r.line("Model", s.modelName)
        r.line("Firmware", s.firmware)
        r.line("Health", s.health.label)
        r.line("IP address", s.ipAddress)
        r.line("Ping", s.ping.map(pingText))
        r.line("Admin port 5009", s.adminPortError.map { "FAILED: \($0)" } ?? s.adminPortLatencyMs.map { String(format: "reachable, %.0f ms", $0) })
        if !isMain, let main = m.mainRouter, let backhaul = s.backhaul(to: main) {
            r.line("Backhaul", "\(backhaul.label). \(backhaul.explanation)")
        }
        r.line("Wi-Fi network", s.networkName)
        r.line("5 GHz channel", s.channel5)
        r.line("2.4 GHz channel", s.channel24)
        r.line("Ethernet MAC", s.ethernetMAC)
        r.line("Wireless MAC", s.wirelessMAC)
        r.line("This device is connected to it", m.isConnected(s) ? "Yes" : "No")
        r.line("Bonjour TXT", s.txt.keys.sorted().map { "\($0)=\(s.txt[$0] ?? "")" }.joined(separator: ", ").nilIfEmpty)
        r.blank()
    }

    private static func devices(_ m: DashboardModel, into r: inout Report) {
        r.section("Devices on the local network")
        guard !m.lanDevices.isEmpty else {
            r.line("Status", m.lanScanning ? "Scan in progress" : "Not scanned yet")
            r.blank()
            return
        }
        r.line("Last scan", m.lastLANScan.map(timestamp))
        r.line("Subnet", m.lanInterface?.cidr)
        r.line("Count", "\(m.lanDevices.count)")
        for d in m.lanDevices {
            let parts = [
                m.displayName(of: d),
                d.mac.map { "MAC \($0)" + (d.isPrivateMAC ? " (private)" : "") },
                d.manufacturer,
                d.latencyMs.map { String(format: "%.0f ms", $0) },
                d.services.isEmpty ? nil : d.services.joined(separator: ", "),
            ].compactMap { $0 }
            r.item(d.ip, parts.joined(separator: " · "))
        }
        r.blank()
    }

    // MARK: Helpers

    private static func header(_ title: String, _ m: DashboardModel) -> Report {
        var r = Report()
        r.title(title)
        r.line("Generated", timestamp(Date()))
        r.line("App", "\(AppInfo.displayName) \(appVersion)")
        r.blank()
        return r
    }

    static func pingText(_ p: PingResult) -> String {
        guard p.received > 0 else { return "no reply (\(p.sent) sent)" + (p.error.map { ", \($0)" } ?? "") }
        var s = "\(p.received)/\(p.sent) replies"
        if let avg = p.avgMs { s += String(format: ", avg %.1f ms", avg) }
        if let lo = p.minMs, let hi = p.maxMs { s += String(format: " (min %.1f, max %.1f)", lo, hi) }
        if let j = p.jitterMs { s += String(format: ", jitter %.1f ms", j) }
        if p.lossPercent > 0 { s += String(format: ", %.0f%% loss", p.lossPercent) }
        return s
    }

    private static func speedText(_ e: SpeedTestEntry) -> String {
        guard e.succeeded else { return "failed (\(e.status))" }
        return e.mbps.map { String(format: "%.0f Mbps", $0) } ?? e.status
    }

    private static func verificationText(_ v: NetworkVerification) -> String {
        switch v {
        case .checking: "Checking"
        case .notConfigured: "Not set up"
        case .verified(let s): "Verified (\(s))"
        case .mismatch(let s): "MISMATCH: \(s)"
        }
    }

    private static func timestamp(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .complete)
    }

    private static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}

/// Builds the indented "Key: value" text. Lines with no value are left out.
private struct Report {
    private(set) var text = ""
    mutating func title(_ s: String) { text += "# \(s)\n" }
    mutating func section(_ s: String) { text += "## \(s)\n" }
    mutating func sub(_ s: String) { text += "### \(s)\n" }
    mutating func blank() { text += "\n" }
    mutating func line(_ key: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        text += "- \(key): \(value)\n"
    }
    mutating func item(_ key: String, _ value: String?) { line(key, value) }
}
