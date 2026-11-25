import SwiftUI

struct GatewayDetailView: View {
    @Environment(DashboardModel.self) private var model
    @Environment(AppSettings.self) private var settings
    var onClose: (() -> Void)?

    var body: some View {
        let b = model.broadband
        DetailPage(title: "Fiber Gateway") {
            DetailHeader(icon: "fibrechannel", title: "Fiber Gateway",
                         subtitle: settings.routerBaseURL?.host() ?? settings.routerURL,
                         health: model.gatewayHealth,
                         statusText: model.routerReachable == false ? "Unreachable" : nil,
                         summary: { NetworkReport.gateway(model) },
                         onClose: onClose)

            HStack(spacing: 10) {
                ManageGatewayButton()
                    .buttonStyle(.borderedProminent)
                Text("Open the gateway's web interface in your browser")
                    .font(.caption).foregroundStyle(.secondary)
            }

            StatTileGrid {
                StatTile(label: "Line", value: b?.lineState ?? "—",
                         tint: b?.lineState?.lowercased().contains("up") == true ? .green : nil)
                StatTile(label: "Link speed", value: b?.speedMbps.map { DashboardView.formatSpeed($0) } ?? "—")
                StatTile(label: "Ping", value: model.routerPing?.avgMs.map { String(format: "%.0f", $0) } ?? "—",
                         unit: "ms", tint: model.routerPing?.tint)
                StatTile(label: "Web UI", value: model.routerLatencyMs.map { String(format: "%.0f", $0) } ?? "—", unit: "ms")
            }

            if let err = model.routerError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }

            DetailCard(title: "Broadband", systemImage: "network") {
                DetailRow(key: "WAN IPv4", value: b?.wanIPv4)
                DetailRow(key: "ISP gateway", value: b?.gatewayIPv4)
                DetailRow(key: "Primary DNS", value: b?.primaryDNS)
                DetailRow(key: "Secondary DNS", value: b?.secondaryDNS)
                DetailRow(key: "Fiber (PON)", value: b?.ponFriendly,
                          tint: b?.ponHealthy.map { $0 ? Color.green : Color.red })
                if let explain = b?.ponExplanation {
                    VStack(spacing: 0) {
                        Text(explain).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        Divider()
                    }
                }
                DetailRow(key: "WAN MAC", value: b?.wanMAC)
                DetailRow(key: "Receive errors", value: b?.receiveErrors,
                          tint: (Int(b?.receiveErrors ?? "0") ?? 0) > 0 ? .orange : nil)
                DetailRow(key: "Receive drops", value: b?.receiveDrops, last: true)
            } accessory: {
                Spacer(minLength: 8)
                // Full title when there's room (Mac, wide panels), else just "Reboot"; never wraps.
                ViewThatFits(in: .horizontal) {
                    RebootButton(prominent: true).fixedSize()
                    RebootButton(compact: true, prominent: true).fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            if settings.routerPassword.isEmpty || model.rebootStatus != nil {
                Text(model.rebootStatus ?? "Add the Device Access Code in Settings to enable reboot.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SpeedTestSection()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Ping from Gateway", systemImage: "dot.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await model.runDevicePings() }
                    } label: {
                        Text(model.devicePings.contains(where: \.running) ? "Running…" : "Run")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.devicePings.contains(where: \.running) || model.routerReachable != true)
                }
                VStack(spacing: 0) {
                    if model.devicePings.isEmpty {
                        Text("Waiting for broadband stats…").font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach(Array(model.devicePings.enumerated()), id: \.element.id) { i, p in
                        PingResultCard(label: p.label, host: p.host, result: p.result, error: p.error,
                                       running: p.running, rawOutput: p.rawOutput, last: i == model.devicePings.count - 1)
                    }
                }
                .padding(.horizontal, 14)
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("The gateway runs each ping itself, so you can tell a Wi-Fi problem from an ISP problem.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let f = model.fiber {
                FiberOpticsCard(fiber: f)
            }

            if let b, !b.sections.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("All Statistics").font(.headline)
                    ForEach(b.sections) { section in
                        CollapsibleCard(title: section.title, systemImage: "tablecells") {
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { i, row in
                                DetailRow(key: row.key, value: row.value.nilIfEmpty, last: i == section.rows.count - 1)
                            }
                        }
                    }
                }
            }
        }
        .refreshable { await model.refreshRouter() }
    }
}

struct BaseStationDetail: View {
    @Environment(DashboardModel.self) private var model
    var station: BaseStation
    var onClose: (() -> Void)?

    private var isMain: Bool { model.mainRouter?.id == station.id }

    var body: some View {
        DetailPage(title: station.name) {
            DetailHeader(icon: isMain ? "wifi.router.fill" : "wifi.router", title: station.name,
                         subtitle: station.ipAddress ?? "resolving…", health: station.health,
                         summary: { NetworkReport.station(station, model) }, onClose: onClose)

            HStack(spacing: 10) {
                ManageAirPortButton(prominent: true)
                #if os(macOS)
                Text("Open AirPort Utility").font(.caption).foregroundStyle(.secondary)
                #else
                Text("Open AirPort Utility (via the App Store)").font(.caption).foregroundStyle(.secondary)
                #endif
            }

            StatTileGrid {
                StatTile(label: "Avg ping", value: station.ping?.avgMs.map { String(format: "%.1f", $0) } ?? "—",
                         unit: "ms", tint: station.ping?.tint)
                StatTile(label: "Loss", value: station.ping.map { String(format: "%.0f", $0.lossPercent) } ?? "—",
                         unit: "%", tint: (station.ping?.lossPercent ?? 0) > 0 ? .orange : nil)
                StatTile(label: "Jitter", value: station.ping?.jitterMs.map { String(format: "%.1f", $0) } ?? "—", unit: "ms")
                StatTile(label: "Admin port", value: station.adminPortLatencyMs.map { String(format: "%.0f", $0) } ?? "—",
                         unit: station.adminPortLatencyMs == nil ? nil : "ms",
                         tint: station.adminPortError == nil ? nil : .red)
            }

            if let p = station.ping, !p.rttsMs.isEmpty {
                HStack(spacing: 12) {
                    RTTSparkline(rtts: p.rttsMs, lost: p.sent - p.received, tint: p.health.color)
                    if let mn = p.minMs, let mx = p.maxMs {
                        Text(String(format: "min %.1f · max %.1f ms · %d/%d replies", mn, mx, p.received, p.sent))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }

            if model.isConnected(station), let wifi = model.wifi {
                DetailCard(title: "Your Connection", systemImage: "wifi") {
                    DetailRow(key: "Status", value: "Connected", mono: false, tint: .accentColor)
                    DetailRow(key: "Signal", value: [wifi.signalText, wifi.signalQuality].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
                    if let noise = wifi.noise { DetailRow(key: "Noise", value: "\(noise) dBm") }
                    if let snr = wifi.snr { DetailRow(key: "Signal-to-noise", value: "\(snr) dB") }
                    if let band = wifi.band { DetailRow(key: "Band", value: band.rawValue) }
                    if let ch = wifi.channel {
                        DetailRow(key: "Channel", value: [String(ch), wifi.channelWidthMHz.map { "\($0) MHz wide" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    if let rate = wifi.txRateMbps { DetailRow(key: "Link rate", value: String(format: "%.0f Mbps", rate)) }
                    if let ssid = wifi.ssid { DetailRow(key: "Network", value: ssid, mono: false) }
                    if let bssid = wifi.bssid { DetailRow(key: "Access point (BSSID)", value: bssid) }
                    DetailRow(key: "Identified", value: model.connectionMatch?.label, mono: false, last: true)
                }
            }

            DetailCard(title: "Role", systemImage: "point.3.connected.trianglepath.dotted") {
                HStack {
                    Text(isMain ? "Main router" : "Extender").font(.callout.weight(.medium))
                    Spacer()
                    if !isMain {
                        Button("Set as Main Router") { model.setMainRouter(station) }
                            .buttonStyle(.bordered).controlSize(.small)
                    } else if model.settings.mainRouterMAC != nil {
                        Button("Auto-detect") { model.setMainRouter(nil) }
                            .buttonStyle(.bordered).controlSize(.small)
                    } else {
                        Text(model.defaultGateway == station.ipAddress ? "This device's default gateway" : "Auto-detected")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
                if !isMain, let main = model.mainRouter, let backhaul = station.backhaul(to: main) {
                    Divider()
                    DetailRow(key: "Backhaul", value: backhaul.label, mono: false,
                              tint: backhaul == .ethernet ? nil : .orange, last: true)
                    Text(backhaul.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                }
            }

            DetailCard(title: "Wireless", systemImage: "wifi") {
                DetailRow(key: "Network", value: station.networkName, mono: false)
                DetailRow(key: "5 GHz channel", value: station.channel5)
                DetailRow(key: "2.4 GHz channel", value: station.channel24, last: true)
            }

            DetailCard(title: "Device", systemImage: "info.circle") {
                DetailRow(key: "Model", value: station.modelName, mono: false)
                DetailRow(key: "Firmware", value: station.firmware)
                DetailRow(key: "Ethernet MAC", value: station.ethernetMAC)
                DetailRow(key: "Wireless MAC", value: station.wirelessMAC, last: true)
            }

            CollapsibleCard(title: "Bonjour TXT Record", systemImage: "curlybraces") {
                let keys = station.txt.keys.sorted()
                ForEach(Array(keys.enumerated()), id: \.element) { i, k in
                    DetailRow(key: k, value: station.txt[k], last: i == keys.count - 1)
                }
            }
        }
    }
}

struct InternetDetailView: View {
    @Environment(DashboardModel.self) private var model
    @Environment(AppSettings.self) private var settings
    var onClose: (() -> Void)?

    var body: some View {
        let results = settings.pingTargets.compactMap { model.internetPings[$0] }
        let loss = results.isEmpty ? nil : results.map(\.lossPercent).reduce(0, +) / Double(results.count)
        let jitter = results.compactMap(\.jitterMs)
        DetailPage(title: "Internet") {
            DetailHeader(icon: "globe", title: "Internet",
                         subtitle: model.broadband?.wanIPv4.map { "WAN \($0)" },
                         health: model.internetHealth,
                         summary: { NetworkReport.internet(model) }, onClose: onClose)

            StatTileGrid {
                StatTile(label: "Avg latency", value: model.internetLatencyMs.map { String(format: "%.1f", $0) } ?? "—", unit: "ms")
                StatTile(label: "Loss", value: loss.map { String(format: "%.0f", $0) } ?? "—", unit: "%",
                         tint: (loss ?? 0) > 0 ? .orange : nil)
                StatTile(label: "Jitter", value: jitter.isEmpty ? "—" : String(format: "%.1f", jitter.reduce(0, +) / Double(jitter.count)), unit: "ms")
                StatTile(label: "Targets", value: "\(settings.pingTargets.count)")
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Ping from this device", systemImage: "dot.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Run") { Task { await model.refreshInternet() } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                VStack(spacing: 0) {
                    ForEach(Array(settings.pingTargets.enumerated()), id: \.element) { i, t in
                        let r = model.internetPings[t]
                        PingResultCard(label: r?.resolvedAddress.flatMap { $0 == t ? nil : $0 } ?? "Ping target",
                                       host: t, result: r, error: r?.received == 0 ? r?.error : nil,
                                       last: i == settings.pingTargets.count - 1)
                    }
                }
                .padding(.horizontal, 14)
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Change targets in Settings.").font(.caption).foregroundStyle(.secondary)
            }

            DNSSection()

            if let b = model.broadband {
                DetailCard(title: "Connection", systemImage: "network") {
                    DetailRow(key: "WAN IPv4", value: b.wanIPv4)
                    DetailRow(key: "ISP gateway", value: b.gatewayIPv4)
                    DetailRow(key: "Primary DNS", value: b.primaryDNS)
                    DetailRow(key: "Secondary DNS", value: b.secondaryDNS, last: true)
                }
            }
        }
    }
}

/// Run the gateway's built-in speed test and show its history.
struct SpeedTestSection: View {
    @Environment(DashboardModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var confirm = false

    private static let mbps = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))

    var body: some View {
        let latest = model.latestSpeedRun
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Speed Test", systemImage: "speedometer")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    confirm = true
                } label: {
                    if model.speedTestRunning {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Testing…") }
                    } else {
                        Text("Run Speed Test")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.speedTestRunning || settings.routerPassword.isEmpty || model.routerReachable != true)
            }

            StatTileGrid {
                StatTile(label: "Download", value: latest?.download?.mbps?.formatted(Self.mbps) ?? "—", unit: "Mbps",
                         tint: latest?.download?.succeeded == false ? .red : nil)
                StatTile(label: "Upload", value: latest?.upload?.mbps?.formatted(Self.mbps) ?? "—", unit: "Mbps",
                         tint: latest?.upload?.succeeded == false ? .red : nil)
                StatTile(label: "Latency", value: latest?.latencyMs?.formatted(Self.mbps) ?? "—", unit: "ms")
                StatTile(label: "Last tested", value: latest?.time.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
            }

            if model.speedTestRunning {
                Label("The gateway is testing upload, then download. This takes about 30 seconds.", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let err = model.speedTestError {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            } else if settings.routerPassword.isEmpty {
                Text("Add the Device Access Code in Settings to run speed tests.").font(.caption).foregroundStyle(.secondary)
            }

            if model.speedRuns.count > 1 {
                CollapsibleCard(title: "History (\(model.speedRuns.count))", systemImage: "clock.arrow.circlepath") {
                    ForEach(Array(model.speedRuns.enumerated()), id: \.element.id) { i, run in
                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                Text(run.time.map { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? run.timeText)
                                    .font(.callout).lineLimit(1)
                                Spacer()
                                Text(DashboardView.speedSummary(run)).font(.callout.monospacedDigit())
                                    .foregroundStyle(run.succeeded ? Color.primary : .red)
                                if let l = run.latencyMs {
                                    Text("\(Int(l.rounded())) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        .frame(minWidth: 44, alignment: .trailing)
                                }
                            }
                            .padding(.vertical, 9)
                            .copyMenu(title: "Speed test", items: [
                                .init(label: "Time", value: run.timeText),
                                .init(label: "Download", value: run.download?.mbps.map { "\($0) Mbps" }),
                                .init(label: "Upload", value: run.upload?.mbps.map { "\($0) Mbps" }),
                                .init(label: "Latency", value: run.latencyMs.map { "\($0) ms" }),
                            ])
                            if i < model.speedRuns.count - 1 { Divider() }
                        }
                    }
                }
            }
        }
        .task { if model.speedHistory.isEmpty && !settings.routerPassword.isEmpty { await model.loadSpeedHistory() } }
        .confirmationDialog("Run a speed test from the gateway?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Run Speed Test") { Task { await model.runSpeedTest() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("For about 30 seconds the test uses your full connection, so video calls and streaming may stutter. Results are also lower while other devices are busy.")
        }
    }
}

struct DevicesDetailView: View {
    @Environment(DashboardModel.self) private var model
    var onClose: (() -> Void)?
    @State private var search = ""
    @State private var sort: Sort = .address

    enum Sort: String, CaseIterable { case address = "Address", name = "Name", latency = "Latency" }

    private var filtered: [LANDevice] {
        var list = model.lanDevices
        if !search.isEmpty {
            list = list.filter { d in
                [model.displayName(of: d), d.ip, d.mac ?? "", d.manufacturer ?? "", d.services.joined(separator: " ")]
                    .contains { $0.localizedCaseInsensitiveContains(search) }
            }
        }
        switch sort {
        case .address: return list.sorted { $0.sortKey < $1.sortKey }
        case .name: return list.sorted { model.displayName(of: $0).localizedStandardCompare(model.displayName(of: $1)) == .orderedAscending }
        case .latency: return list.sorted { ($0.latencyMs ?? .infinity) < ($1.latencyMs ?? .infinity) }
        }
    }

    var body: some View {
        DetailPage(title: "Devices") {
            DetailHeader(icon: "laptopcomputer.and.iphone", title: "Devices on Network",
                         subtitle: model.lanInterface.map { "\($0.cidr) · \($0.name)" },
                         health: model.lanDevices.isEmpty ? .unknown : .good,
                         statusText: model.lanScanning ? "Scanning…" : "\(model.lanDevices.count) found",
                         summary: { NetworkReport.devices(model) },
                         onClose: onClose)

            HStack(spacing: 10) {
                TextField("Search name, IP, MAC, maker or type", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    Task { await model.scanLAN() }
                } label: {
                    if model.lanScanning { ProgressView().controlSize(.small) } else { Text("Scan") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.lanScanning)
            }
            if model.lanScanning {
                ProgressView(value: model.lanProgress)
            }

            VStack(spacing: 0) {
                if filtered.isEmpty {
                    Text(model.lanScanning ? "Scanning your network…" : "No devices found.")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 14)
                }
                ForEach(Array(filtered.enumerated()), id: \.element.id) { i, d in
                    DeviceRow(device: d, name: model.displayName(of: d), role: model.role(of: d),
                              last: i == filtered.count - 1)
                }
            }
            .padding(.horizontal, 14)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Found by pinging every address on your network, then reading names over Bonjour and, on Mac, hardware addresses from the ARP table. Devices that are asleep may be missing until they wake.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DeviceRow: View {
    var device: LANDevice
    var name: String
    var role: DashboardModel.DeviceRole?
    var last: Bool

    private var icon: String {
        switch role {
        case .thisDevice?: return "person.crop.circle"
        case .mainRouter?, .baseStation?: return "wifi.router"
        case nil: break
        }
        let s = device.services
        if s.contains("Printer") { return "printer" }
        if s.contains("Chromecast") || name.localizedCaseInsensitiveContains("tv") { return "tv" }
        if s.contains("Apple device") { return name.localizedCaseInsensitiveContains("ipad") ? "ipad" : name.localizedCaseInsensitiveContains("mac") ? "laptopcomputer" : "appletv" }
        if s.contains("AirPlay audio") || s.contains("Sonos") || s.contains("Spotify Connect") { return "hifispeaker" }
        if s.contains("HomeKit") || s.contains("Matter") { return "homekit" }
        if s.contains("File sharing") { return "externaldrive.connected.to.line.below" }
        return "questionmark.circle"
    }

    private var roleText: String? {
        switch role {
        case .thisDevice?: "This device"
        case .mainRouter?: "Router"
        case .baseStation?: "Base station"
        case nil: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(device.hostName == nil && role == nil && device.manufacturer == nil ? Color.secondary : .accentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).font(.callout.weight(.medium)).lineLimit(1)
                            .foregroundStyle(device.hostName == nil && role == nil && device.manufacturer == nil ? Color.secondary : .primary)
                        if let roleText {
                            Text(roleText).font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(([device.ip] + device.services).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let mac = device.mac {
                        HStack(spacing: 6) {
                            Text(mac).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .fixedSize()
                            if let maker = device.manufacturer {
                                Text(maker).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                            if device.isPrivateMAC {
                                Text("Private address").font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("A randomized Wi-Fi address, typical for iPhones, iPads and Macs.")
                            }
                        }
                    }
                }
                .layoutPriority(1)   // let names and makers use the free space before the spacer
                Spacer(minLength: 8)
                if let ms = device.latencyMs {
                    Text(ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ms > 100 ? Color.orange : .secondary)
                        .fixedSize()
                } else {
                    Text("no ping").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .copyMenu(title: name, items: [
                .init(label: "Name", value: device.hostName),
                .init(label: "IP Address", value: device.ip),
                .init(label: "MAC Address", value: device.mac),
                .init(label: "Manufacturer", value: device.manufacturer),
                .init(label: "Services", value: device.services.joined(separator: ", ").nilIfEmpty),
            ])
            if !last { Divider() }
        }
    }
}

/// DNS health: each server resolving each configured hostname.
struct DNSSection: View {
    @Environment(DashboardModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("DNS", systemImage: "character.book.closed")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HealthPill(health: model.dnsHealth)
                Spacer()
                Button {
                    Task { await model.refreshDNS() }
                } label: {
                    if model.dnsChecking { ProgressView().controlSize(.small) } else { Text("Run") }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(model.dnsChecking)
            }
            VStack(spacing: 0) {
                if model.dnsResults.isEmpty {
                    Text(model.dnsChecking ? "Checking DNS…" : "Not checked yet.")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                }
                ForEach(Array(model.dnsResults.enumerated()), id: \.element.id) { i, r in
                    DNSServerRow(result: r, last: i == model.dnsResults.count - 1)
                }
            }
            .padding(.horizontal, 14)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Each server is asked directly for \(settings.dnsHostnames.joined(separator: ", ")), so a broken resolver shows up even while cached names still work. “This device” is the DNS server this device is set to use; if only it fails, the router, ISP and public servers show where the problem is. Change the hostnames in Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DNSServerRow: View {
    var result: DNSServerResult
    var last: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.server.label).font(.callout.weight(.medium))
                        Text(result.server.ip).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(result.summary).font(.caption.monospacedDigit())
                        .foregroundStyle(result.health == .good ? Color.secondary : result.health.color)
                        .lineLimit(1)
                    HealthPill(health: result.health).fixedSize()
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(spacing: 6) {
                    ForEach(result.lookups) { l in
                        HStack(spacing: 8) {
                            Image(systemName: l.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(l.ok ? Color.green : .red).font(.caption)
                            Text(l.host).font(.caption.monospaced())
                            Spacer(minLength: 8)
                            Text(l.ok ? (l.addresses.first ?? "") : (l.error ?? "failed"))
                                .font(.caption.monospaced()).foregroundStyle(l.ok ? Color.secondary : .red)
                                .lineLimit(1).copyable(l.addresses.first)
                            if let ms = l.ms, l.ok {
                                Text(ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            if !last { Divider() }
        }
    }
}

/// Optical module readings with a status for each (cgi-bin/fiberstat.ha).
struct FiberOpticsCard: View {
    var fiber: FiberStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Fiber Optics", systemImage: "light.beacon.max")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HealthPill(health: fiber.status.health, text: fiber.status.label)
            }
            VStack(spacing: 0) {
                ForEach(Array(fiber.metrics.enumerated()), id: \.element.id) { i, m in
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.displayName).font(.callout)
                                if let range = m.rangeText {
                                    Text([range, m.marginText].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Values and status never wrap; the caption on the left does.
                            Text(m.valueText).font(.callout.monospacedDigit().weight(.semibold))
                                .lineLimit(1).fixedSize()
                                .copyable(m.valueText, label: m.displayName)
                            HealthPill(health: m.status.health, text: m.status.label).fixedSize()
                        }
                        .padding(.vertical, 9)
                        if i < fiber.metrics.count - 1 { Divider() }
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            DetailCard(title: "Optical Module", systemImage: "cable.connector") {
                DetailRow(key: "Link", value: fiber.value("Link State"), mono: false,
                          tint: fiber.linkUp == false ? .red : nil)
                DetailRow(key: "Optical WAN", value: fiber.value("Optical WAN Operational Status"), mono: false)
                DetailRow(key: "Wavelength", value: fiber.wavelength)
                DetailRow(key: "Module", value: fiber.module, mono: false)
                DetailRow(key: "Serial", value: fiber.value("Vendor SN"), last: true)
            } accessory: {
                if let up = fiber.moduleUp {
                    HealthPill(health: up ? .good : .down, text: up ? "Up" : "Down")
                }
            }
            Text("Readings and limits come from the fiber module itself. Receive power is the most useful: a drop toward the low limit usually means a dirty or bent fiber.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
