import SwiftUI

enum Route: Hashable {
    case internet
    case gateway
    case station(String)
}

struct DashboardView: View {
    @Environment(DashboardModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var showSettings = false
    @State private var path = NavigationPath()
    @State private var inspected: Route?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Mac and iPad show details in a side inspector; iPhone pushes a new screen.
    private var usesInspector: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    /// Show details requested from the menu bar (never toggles closed).
    private func showRequestedRoute() {
        guard let route = model.requestedRoute else { return }
        model.requestedRoute = nil
        if usesInspector {
            withAnimation(.snappy) { inspected = route }
        } else {
            path = NavigationPath([route])
        }
    }

    private func open(_ route: Route) {
        if usesInspector {
            withAnimation(.snappy) { inspected = (inspected == route) ? nil : route }
        } else {
            path.append(route)
        }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { usesInspector && inspected != nil },
                set: { if !$0 { inspected = nil } })
    }

    @ViewBuilder private func destination(_ route: Route, inInspector: Bool) -> some View {
        let close: (() -> Void)? = inInspector ? { withAnimation(.snappy) { inspected = nil } } : nil
        switch route {
        case .internet: InternetDetailView(onClose: close)
        case .gateway: GatewayDetailView(onClose: close)
        case .station(let id):
            if let s = model.baseStations.first(where: { $0.id == id }) { BaseStationDetail(station: s, onClose: close) }
            else { ContentUnavailableView("Base station not found", systemImage: "wifi.router") }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
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
            .navigationDestination(for: Route.self) { destination($0, inInspector: false) }
            .inspector(isPresented: inspectorShown) {
                Group {
                    if let inspected { destination(inspected, inInspector: true) }
                }
                .inspectorColumnWidth(min: 340, ideal: 400, max: 520)
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
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") {
                            #if os(macOS)
                            NSApp.keyWindow?.makeFirstResponder(nil)   // commit a pasted access code before closing
                            #endif
                            DispatchQueue.main.async { showSettings = false }
                        } } }
                }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 620)
                #endif
            }
        }
        .task { model.start() }
        .onAppear { showRequestedRoute() }
        .onChange(of: model.requestedRoute) { showRequestedRoute() }
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
            VStack(alignment: .leading, spacing: 12) {
                MetricGrid(items: settings.pingTargets.map { t in
                    let r = model.internetPings[t]
                    return .init(label: t, value: r?.shortSummary ?? "testing…", tint: r?.tint)
                })
                detailsFooter(.internet)
            }
        }
        .tappableCard { open(.internet) }
        .selectedOutline(inspected == .internet)
        .copyMenu(title: "Internet", items: [.init(label: "WAN IP", value: model.broadband?.wanIPv4)]
                  + settings.pingTargets.map { .init(label: $0, value: model.internetPings[$0]?.shortSummary) })
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
                    .init(label: "Fiber (PON)", value: b?.ponFriendly,
                          tint: b?.ponHealthy.map { $0 ? Color.green : Color.red }),
                    .init(label: "ISP Gateway", value: b?.gatewayIPv4),
                    .init(label: "ISP DNS", value: b?.primaryDNS),
                    .init(label: "Web UI", value: model.routerLatencyMs.map { String(format: "%.0f ms", $0) }),
                ])
                if let err = model.routerError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.leading, Topology.iconSize + 12)
                }
                ViewThatFits(in: .horizontal) {
                    gatewayActions(compact: false)
                    gatewayActions(compact: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .lineLimit(1)
                .padding(.leading, Topology.iconSize + 12)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .tappableCard { open(.gateway) }
        .selectedOutline(inspected == .gateway)
        .copyMenu(title: "Fiber Gateway", items: [
            .init(label: "Gateway Address", value: settings.routerBaseURL?.host()),
            .init(label: "WAN IP", value: b?.wanIPv4),
            .init(label: "ISP Gateway", value: b?.gatewayIPv4),
            .init(label: "Primary DNS", value: b?.primaryDNS),
            .init(label: "Secondary DNS", value: b?.secondaryDNS),
            .init(label: "WAN MAC", value: b?.wanMAC),
            .init(label: "Fiber (PON)", value: b?.ponStatus),
        ])
    }

    private func gatewayActions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.runDevicePings() }
            } label: {
                if model.devicePings.contains(where: \.running) {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Pinging…") }
                } else {
                    Label(compact ? "Ping" : "Ping from Gateway", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            .disabled(model.devicePings.contains(where: \.running) || model.routerReachable != true)
            RebootButton(compact: true)
            Spacer(minLength: 0)
            ManageGatewayButton(compact: compact)
            DetailsButton(sidebar: usesInspector, iconOnly: compact) { open(.gateway) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    static func copyItems(for s: BaseStation) -> [CopyItem] {
        [
            .init(label: "Name", value: s.name),
            .init(label: "IP Address", value: s.ipAddress),
            .init(label: "Ethernet MAC", value: s.ethernetMAC),
            .init(label: "Wireless MAC", value: s.wirelessMAC),
            .init(label: "Wi-Fi Network", value: s.networkName),
            .init(label: "Firmware", value: s.firmware),
            .init(label: "Model", value: s.modelName),
        ]
    }

    static func formatSpeed(_ mbps: String) -> String {
        guard let v = Double(mbps) else { return "\(mbps) Mbps" }
        return v >= 1000 ? String(format: "%g Gbps", v / 1000) : "\(mbps) Mbps"
    }

    // MARK: Router

    @ViewBuilder private var routerNode: some View {
        if let r = model.mainRouter {
            TopologyNode(title: r.name, subtitle: r.ipAddress ?? "resolving…", icon: "wifi.router.fill", health: r.health,
                         connected: model.isConnected(r) ? model.wifi : nil) {
                VStack(alignment: .leading, spacing: 12) {
                    stationMetrics(r)
                    detailsFooter(.station(r.id))
                }
            }
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .tappableCard { open(.station(r.id)) }
                .copyMenu(title: r.name, items: Self.copyItems(for: r))
                .selectedOutline(inspected == .station(r.id))
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
                    Group {
                        HStack(spacing: 12) {
                            NodeIcon(systemName: "wifi.router", health: s.health, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text([s.ipAddress ?? "resolving…", s.ping?.shortSummary].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption.monospacedDigit()).foregroundStyle(s.ping?.tint ?? .secondary).lineLimit(1)
                                Text(s.modelName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                if model.isConnected(s), let wifi = model.wifi {
                                    ConnectedBadge(wifi: wifi, compact: !usesInspector).padding(.top, 2)
                                }
                            }
                            Spacer(minLength: 4)
                            HealthPill(health: s.health).fixedSize()
                            DetailsButton(sidebar: usesInspector, iconOnly: !usesInspector) { open(.station(s.id)) }
                        }
                        .padding(10)
                        .background(Color.insetBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .tappableCard { open(.station(s.id)) }
                    .copyMenu(title: s.name, items: Self.copyItems(for: s))
                    .selectedOutline(inspected == .station(s.id), cornerRadius: 10)
                }
            }
        }
    }

    private func stationMetrics(_ s: BaseStation) -> some View {
        MetricGrid(items: [
            .init(label: "Ping", value: s.ping?.shortSummary, tint: s.ping?.tint),
            .init(label: "Model", value: s.modelName),
            .init(label: "Firmware", value: s.firmware),
            .init(label: "Wi-Fi", value: s.networkName),
            .init(label: "5 GHz", value: s.channel5.map { "Channel \($0)" }),
            .init(label: "2.4 GHz", value: s.channel24.map { "Channel \($0)" }),
        ])
    }

    /// Bottom-right Details button, aligned with the gateway card's action row.
    private func detailsFooter(_ route: Route) -> some View {
        HStack {
            Spacer()
            DetailsButton(sidebar: usesInspector) { open(route) }
        }
        .padding(.leading, Topology.iconSize + 12)
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
    /// Raised card surface: white on iOS grouped backgrounds, subtle grey on macOS.
    static var cardBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color.primary.opacity(0.04)
        #endif
    }
    /// Surface for rows nested inside a card.
    static var insetBackground: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemGroupedBackground)
        #else
        Color(nsColor: .textBackgroundColor)
        #endif
    }
    static var platformGroupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}
