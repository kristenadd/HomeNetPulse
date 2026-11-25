import SwiftUI

struct DashboardView: View {
    @Environment(DashboardModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var showSettings = false
    @State private var confirmReboot = false

    var body: some View {
        NavigationStack {
            List {
                verificationSection
                airportSection
                internetSection
                routerSection
                devicePingSection
                broadbandSection
                rebootSection
            }
            .navigationTitle("HomeNet Pulse")
            #if os(macOS)
            .listStyle(.inset(alternatesRowBackgrounds: false))
            #else
            .listStyle(.insetGrouped)
            #endif
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        if model.isRefreshing { ProgressView().controlSize(.small) }
                        else { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                    .keyboardShortcut("r")
                    .disabled(model.isRefreshing)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } }
                        }
                }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 620)
                #endif
            }
            .confirmationDialog("Reboot the fiber gateway?", isPresented: $confirmReboot, titleVisibility: .visible) {
                Button("Reboot Gateway", role: .destructive) { Task { await model.rebootRouter() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(model.internetDown
                     ? "The internet is unreachable. Rebooting takes the whole network offline for a few minutes."
                     : "The internet currently looks reachable. Rebooting takes the whole network offline for a few minutes.")
            }
        }
        .task { model.start() }
    }

    // MARK: Sections

    @ViewBuilder private var verificationSection: some View {
        Section("Network") {
            switch model.verification {
            case .checking:
                Label("Checking network identity…", systemImage: "hourglass")
            case .notConfigured:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Network not yet trusted", systemImage: "questionmark.diamond").foregroundStyle(.orange)
                    Text("Mark this network as yours so HomeNet Pulse can verify it by your base stations' and gateway's MAC addresses.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Trust This Network") { model.trustCurrentNetwork() }
                        .disabled(model.baseStations.isEmpty && model.broadband == nil)
                }
            case .verified(let detail):
                Label { VStack(alignment: .leading) { Text("Verified: your network"); Text(detail).font(.caption).foregroundStyle(.secondary) } }
                    icon: { Image(systemName: "checkmark.shield.fill").foregroundStyle(.green) }
            case .mismatch(let detail):
                Label { VStack(alignment: .leading) { Text("Not your network"); Text(detail).font(.caption).foregroundStyle(.secondary) } }
                    icon: { Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red) }
            }
            if let last = model.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var airportSection: some View {
        Section {
            if model.baseStations.isEmpty {
                Text(model.discoveryError ?? "Searching for AirPort base stations…").foregroundStyle(.secondary)
            }
            ForEach(model.baseStations) { station in
                NavigationLink { BaseStationDetail(station: station) } label: { BaseStationRow(station: station) }
            }
        } header: {
            Text("AirPort Base Stations (\(model.baseStations.count))")
        }
    }

    @ViewBuilder private var internetSection: some View {
        Section {
            ForEach(settings.pingTargets, id: \.self) { target in
                let r = model.internetPings[target]
                HStack {
                    VStack(alignment: .leading) {
                        Text(target).font(.body.monospaced())
                        PingSummary(result: r)
                    }
                    Spacer()
                    HealthBadge(health: r?.health ?? .unknown)
                }
            }
        } header: {
            HStack { Text("Internet"); Spacer(); HealthBadge(health: model.internetHealth) }
        }
    }

    @ViewBuilder private var routerSection: some View {
        Section {
            HStack {
                Text(settings.routerURL).font(.body.monospaced())
                Spacer()
                HealthBadge(health: model.routerReachable == nil ? .unknown : (model.routerReachable! ? (model.routerPing?.health ?? .good) : .down))
            }
            KeyValueRow(key: "Web UI response", value: model.routerLatencyMs.map { String(format: "%.0f ms", $0) })
            LabeledContent("Ping") { PingSummary(result: model.routerPing) }
            if let b = model.broadband {
                KeyValueRow(key: "Line state", value: b.lineState)
                KeyValueRow(key: "Link speed", value: b.speedMbps.map { "\($0) Mbps" })
                KeyValueRow(key: "PON status", value: b.ponStatus)
                KeyValueRow(key: "WAN IPv4", value: b.wanIPv4)
                KeyValueRow(key: "ISP gateway", value: b.gatewayIPv4)
                KeyValueRow(key: "ISP DNS", value: [b.primaryDNS, b.secondaryDNS].compactMap { $0 }.joined(separator: ", ").nilIfEmpty)
                KeyValueRow(key: "Receive errors / drops", value: "\(b.receiveErrors ?? "—") / \(b.receiveDrops ?? "—")")
            }
            if let err = model.routerError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Fiber Gateway")
        }
    }

    @ViewBuilder private var devicePingSection: some View {
        Section {
            ForEach(model.devicePings) { p in
                DisclosureGroup {
                    if let raw = p.rawOutput {
                        Text(raw).font(.caption.monospaced()).textSelection(.enabled)
                    }
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
                        else { HealthBadge(health: p.result?.health ?? .unknown) }
                    }
                }
            }
            Button {
                Task { await model.runDevicePings() }
            } label: {
                Label("Ping from Gateway", systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(model.devicePings.contains(where: \.running) || model.routerReachable != true)
        } header: {
            Text("Gateway Diagnostics (diag.ha)")
        } footer: {
            Text("The gateway pings each host itself, so you can tell whether a problem is on your Wi-Fi or upstream at the ISP.")
        }
    }

    @ViewBuilder private var broadbandSection: some View {
        if let b = model.broadband, !b.sections.isEmpty {
            Section("Broadband Statistics") {
                ForEach(b.sections) { section in
                    DisclosureGroup(section.title) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            KeyValueRow(key: row.key, value: row.value.nilIfEmpty)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var rebootSection: some View {
        Section {
            if model.internetDown {
                Label("Internet is unreachable from this device.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.red)
            }
            Button(role: .destructive) { confirmReboot = true } label: {
                if model.rebooting { ProgressView().controlSize(.small) }
                else { Label("Reboot Fiber Gateway", systemImage: "restart.circle") }
            }
            .disabled(model.rebooting || settings.routerPassword.isEmpty)
            if settings.routerPassword.isEmpty {
                Text("Add the Device Access Code in Settings to enable reboot.").font(.caption).foregroundStyle(.secondary)
            }
            if let s = model.rebootStatus { Text(s).font(.caption) }
        } header: {
            Text("Recovery")
        }
    }
}

struct BaseStationRow: View {
    var station: BaseStation
    var body: some View {
        HStack {
            Image(systemName: "wifi.router").font(.title2).foregroundStyle(station.health.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(station.name).font(.headline)
                Text("\(station.ipAddress ?? "resolving…") · \(station.modelName)")
                    .font(.caption).foregroundStyle(.secondary)
                PingSummary(result: station.ping)
            }
            Spacer()
            HealthBadge(health: station.health)
        }
    }
}

struct BaseStationDetail: View {
    var station: BaseStation
    var body: some View {
        List {
            Section("Status") {
                LabeledContent("Health") { HealthBadge(health: station.health) }
                KeyValueRow(key: "IP address", value: station.ipAddress)
                KeyValueRow(key: "Admin port (5009)", value: station.adminPortLatencyMs.map { String(format: "%.0f ms", $0) } ?? station.adminPortError)
                LabeledContent("Ping") { PingSummary(result: station.ping) }
                if let p = station.ping, let mn = p.minMs, let mx = p.maxMs {
                    KeyValueRow(key: "Min / max", value: String(format: "%.1f / %.1f ms", mn, mx))
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
