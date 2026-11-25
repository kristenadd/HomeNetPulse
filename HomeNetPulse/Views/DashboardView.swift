import SwiftUI

enum Route: Hashable {
    case gateway
    case station(String)
}

struct DashboardView: View {
    @Environment(DashboardModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    VerificationBanner()
                        .padding(.bottom, 18)
                    internetNode
                    TopologyConnector(health: model.gatewayHealth == .down ? .down : model.internetHealth,
                                      label: ispHopLabel)
                    gatewayNode
                    TopologyConnector(health: model.mainRouter?.health ?? .unknown,
                                      label: model.routerPing.map { "\(settings.routerBaseURL?.host() ?? "gateway") · \($0.shortSummary)" })
                    routerNode
                    if !model.extenders.isEmpty {
                        TopologyConnector(health: model.extendersHealth, label: nil)
                        extendersNode
                    }
                    footer
                }
                .padding(16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Color.platformGroupedBackground)
            .navigationTitle("HomeNet Pulse")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .gateway: GatewayDetailView()
                case .station(let id):
                    if let s = model.baseStations.first(where: { $0.id == id }) { BaseStationDetail(station: s) }
                    else { ContentUnavailableView("Base station not found", systemImage: "wifi.router") }
                }
            }
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.refresh() } } label: {
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
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
                }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 620)
                #endif
            }
        }
        .task { model.start() }
    }

    private var ispHopLabel: String? {
        guard let gw = model.broadband?.gatewayIPv4 else { return nil }
        if let r = model.devicePings.first(where: { $0.host == gw })?.result { return "ISP \(gw) · \(r.shortSummary)" }
        return "ISP gateway \(gw)"
    }

    // MARK: Internet

    private var internetNode: some View {
        TopologyNode(title: "Internet", subtitle: model.broadband?.wanIPv4.map { "WAN \($0)" },
                     icon: "globe", health: model.internetHealth) {
            MetricGrid(items: settings.pingTargets.map { t in
                let r = model.internetPings[t]
                return .init(label: t, value: r?.shortSummary ?? "testing…", tint: r?.tint)
            })
        }
    }

    // MARK: Gateway

    private var gatewayNode: some View {
        let b = model.broadband
        return TopologyNode(title: "Fiber Gateway", subtitle: settings.routerBaseURL?.host() ?? settings.routerURL,
                            icon: "fibrechannel", health: model.gatewayHealth,
                            statusText: model.routerReachable == false ? "Unreachable" : nil) {
            VStack(alignment: .leading, spacing: 12) {
                MetricGrid(items: [
                    .init(label: "Line", value: b?.lineState, tint: b?.lineState?.lowercased().contains("up") == true ? .green : nil),
                    .init(label: "Speed", value: b?.speedMbps.map { Self.formatSpeed($0) }),
                    .init(label: "Fiber (PON)", value: b?.ponStatus),
                    .init(label: "ISP Gateway", value: b?.gatewayIPv4),
                    .init(label: "ISP DNS", value: b?.primaryDNS),
                    .init(label: "Web UI", value: model.routerLatencyMs.map { String(format: "%.0f ms", $0) }),
                ])
                if let err = model.routerError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.leading, Topology.iconSize + 12)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await model.runDevicePings() }
                    } label: {
                        if model.devicePings.contains(where: \.running) {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Pinging…") }
                        } else {
                            Label("Ping from Gateway", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                    .disabled(model.devicePings.contains(where: \.running) || model.routerReachable != true)
                    RebootButton(compact: true)
                    Spacer()
                    NavigationLink(value: Route.gateway) { Label("Details", systemImage: "chevron.right").labelStyle(.titleOnly) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.leading, Topology.iconSize + 12)
            }
        }
    }

    static func formatSpeed(_ mbps: String) -> String {
        guard let v = Double(mbps) else { return "\(mbps) Mbps" }
        return v >= 1000 ? String(format: "%g Gbps", v / 1000) : "\(mbps) Mbps"
    }

    // MARK: Router

    @ViewBuilder private var routerNode: some View {
        if let r = model.mainRouter {
            NavigationLink(value: Route.station(r.id)) {
                TopologyNode(title: r.name, subtitle: r.ipAddress ?? "resolving…", icon: "wifi.router.fill", health: r.health,
                             content: { stationMetrics(r) }, accessory: { chevron })
            }
            .buttonStyle(.plain)
        } else {
            TopologyNode(title: "Router", subtitle: model.discoveryError ?? "Searching for AirPort base stations…",
                         icon: "wifi.router", health: .unknown) { EmptyView() }
        }
    }

    // MARK: Extenders

    private var extendersNode: some View {
        TopologyNode(title: "Other Base Stations", subtitle: "\(model.extenders.count) extender\(model.extenders.count == 1 ? "" : "s")",
                     icon: "point.3.connected.trianglepath.dotted", health: model.extendersHealth) {
            VStack(spacing: 8) {
                ForEach(model.extenders) { s in
                    NavigationLink(value: Route.station(s.id)) {
                        HStack(spacing: 12) {
                            NodeIcon(systemName: "wifi.router", health: s.health, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.subheadline.weight(.semibold))
                                Text("\(s.ipAddress ?? "resolving…") · \(s.modelName)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(s.ping?.shortSummary ?? "—").font(.caption.monospacedDigit()).foregroundStyle(s.ping?.tint ?? .secondary)
                            HealthPill(health: s.health)
                            chevron
                        }
                        .padding(10)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, Topology.iconSize + 12)
        }
    }

    private func stationMetrics(_ s: BaseStation) -> some View {
        MetricGrid(items: [
            .init(label: "Ping", value: s.ping?.shortSummary, tint: s.ping?.tint),
            .init(label: "Model", value: s.modelName),
            .init(label: "Firmware", value: s.firmware),
            .init(label: "Wi-Fi", value: s.networkName),
            .init(label: "Channels", value: [s.channel5.map { "5G \($0)" }, s.channel24.map { "2.4G \($0)" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty),
        ])
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
    }

    private var footer: some View {
        Group {
            if let last = model.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .standard)) · auto-refresh every \(Int(settings.refreshInterval))s")
            } else {
                Text("Checking your network…")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.top, 20)
    }
}

// MARK: - Verification banner

struct VerificationBanner: View {
    @Environment(DashboardModel.self) private var model

    var body: some View {
        let (icon, color, title, detail, showTrust): (String, Color, String, String?, Bool) = {
            switch model.verification {
            case .checking: ("hourglass", .secondary, "Checking network identity…", nil, false)
            case .notConfigured: ("questionmark.diamond.fill", .orange, "Network not yet trusted",
                                  "Trust it to verify by your base stations' and gateway's MAC addresses.", true)
            case .verified(let d): ("checkmark.shield.fill", .green, "Verified: your network", d, false)
            case .mismatch(let d): ("exclamationmark.shield.fill", .red, "Not your network", d, false)
            }
        }()
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if showTrust {
                Button("Trust") { model.trustCurrentNetwork() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.baseStations.isEmpty && model.broadband == nil)
            }
        }
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Reboot

struct RebootButton: View {
    @Environment(DashboardModel.self) private var model
    @Environment(AppSettings.self) private var settings
    var compact = false
    @State private var confirm = false

    var body: some View {
        Button(role: .destructive) { confirm = true } label: {
            if model.rebooting { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Rebooting…") } }
            else { Label(compact ? "Reboot" : "Reboot Fiber Gateway", systemImage: "restart.circle") }
        }
        .tint(model.internetDown ? .red : nil)
        .disabled(model.rebooting || settings.routerPassword.isEmpty)
        .help(settings.routerPassword.isEmpty ? "Add the Device Access Code in Settings to enable reboot." : "Restart the gateway")
        .confirmationDialog("Reboot the fiber gateway?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Reboot Gateway", role: .destructive) { Task { await model.rebootRouter() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.internetDown
                 ? "The internet is unreachable. Rebooting takes the whole network offline for a few minutes."
                 : "The internet currently looks reachable. Rebooting takes the whole network offline for a few minutes.")
        }
    }
}

extension Color {
    static var platformGroupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}
