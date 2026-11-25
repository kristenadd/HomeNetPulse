import SwiftUI

struct GatewayDetailView: View {
    @Environment(DashboardModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        List {
            Section("Status") {
                LabeledContent("Health") { HealthPill(health: model.gatewayHealth) }
                KeyValueRow(key: "Address", value: settings.routerURL)
                KeyValueRow(key: "Web UI response", value: model.routerLatencyMs.map { String(format: "%.0f ms", $0) })
                LabeledContent("Ping") { PingSummary(result: model.routerPing) }
                if let err = model.routerError { Text(err).font(.caption).foregroundStyle(.orange) }
            }

            Section {
                ForEach(model.devicePings) { p in
                    DisclosureGroup {
                        if let raw = p.rawOutput { Text(raw).font(.caption.monospaced()).textSelection(.enabled) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(p.label).font(.caption).foregroundStyle(.secondary)
                                Text(p.host).font(.body.monospaced())
                                if let e = p.error { Text(e).font(.caption).foregroundStyle(.red) }
                                else { PingSummary(result: p.result) }
                            }
                            Spacer()
                            if p.running { ProgressView().controlSize(.small) }
                            else { HealthPill(health: p.result?.health ?? .unknown) }
                        }
                    }
                }
                Button {
                    Task { await model.runDevicePings() }
                } label: { Label("Ping from Gateway", systemImage: "dot.radiowaves.left.and.right") }
                .disabled(model.devicePings.contains(where: \.running) || model.routerReachable != true)
            } header: {
                Text("Ping from Gateway")
            } footer: {
                Text("The gateway pings each host itself (diag.ha), so you can tell whether a problem is on your Wi-Fi or upstream at the ISP.")
            }

            if let b = model.broadband {
                ForEach(b.sections) { section in
                    Section(section.title) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            KeyValueRow(key: row.key, value: row.value.nilIfEmpty)
                        }
                    }
                }
            }

            Section("Recovery") {
                if model.internetDown {
                    Label("Internet is unreachable from this device.", systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                }
                RebootButton()
                if settings.routerPassword.isEmpty {
                    Text("Add the Device Access Code in Settings to enable reboot.").font(.caption).foregroundStyle(.secondary)
                }
                if let s = model.rebootStatus { Text(s).font(.caption) }
            }
        }
        .navigationTitle("Fiber Gateway")
        .refreshable { await model.refreshRouter() }
    }
}

struct BaseStationDetail: View {
    @Environment(DashboardModel.self) private var model
    var station: BaseStation

    var body: some View {
        List {
            Section("Status") {
                LabeledContent("Health") { HealthPill(health: station.health) }
                LabeledContent("Role") {
                    Text(model.mainRouter?.id == station.id ? "Main router" : "Extender")
                }
                KeyValueRow(key: "IP address", value: station.ipAddress)
                KeyValueRow(key: "Admin port (5009)", value: station.adminPortLatencyMs.map { String(format: "%.0f ms", $0) } ?? station.adminPortError)
                LabeledContent("Ping") { PingSummary(result: station.ping) }
                if let p = station.ping, let mn = p.minMs, let mx = p.maxMs {
                    KeyValueRow(key: "Min / max", value: String(format: "%.1f / %.1f ms", mn, mx))
                }
                if model.mainRouter?.id != station.id {
                    Button("Set as Main Router") { model.setMainRouter(station) }
                } else if model.settings.mainRouterMAC != nil {
                    Button("Auto-detect Main Router") { model.setMainRouter(nil) }
                }
            }
            Section("Device") {
                KeyValueRow(key: "Model", value: station.modelName)
                KeyValueRow(key: "Firmware", value: station.firmware)
                KeyValueRow(key: "Wi-Fi network", value: station.networkName)
                KeyValueRow(key: "5 GHz channel", value: station.channel5)
                KeyValueRow(key: "2.4 GHz channel", value: station.channel24)
                KeyValueRow(key: "Ethernet MAC", value: station.ethernetMAC)
                KeyValueRow(key: "Wireless MAC", value: station.wirelessMAC)
            }
            Section("Bonjour TXT Record") {
                ForEach(station.txt.keys.sorted(), id: \.self) { k in KeyValueRow(key: k, value: station.txt[k]) }
            }
        }
        .navigationTitle(station.name)
    }
}
