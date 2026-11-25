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
            }

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

            VStack(alignment: .leading, spacing: 10) {
                Label("Recovery", systemImage: "cross.case").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    if model.internetDown {
                        Label("Internet is unreachable from this device.", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.red).font(.callout.weight(.medium))
                    }
                    RebootButton()
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    if settings.routerPassword.isEmpty {
                        Text("Add the Device Access Code in Settings to enable reboot.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let s = model.rebootStatus { Text(s).font(.caption) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                         subtitle: station.ipAddress ?? "resolving…", health: station.health, onClose: onClose)

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
                         health: model.internetHealth, onClose: onClose)

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
                        PingResultCard(label: r?.resolvedAddress.flatMap { $0 == t ? nil : $0 } ?? "Target",
                                       host: t, result: r, error: r?.received == 0 ? r?.error : nil,
                                       last: i == settings.pingTargets.count - 1)
                    }
                }
                .padding(.horizontal, 14)
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Change targets in Settings.").font(.caption).foregroundStyle(.secondary)
            }

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
