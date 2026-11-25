#if os(macOS)
import SwiftUI
import AppKit

/// The icon (and optional latency) shown in the macOS menu bar.
struct MenuBarLabel: View {
    @Environment(DashboardModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let health = model.overallHealth
        HStack(spacing: 4) {
            Image(nsImage: Self.icon(for: health))
            if settings.showLatencyInMenuBar, let ms = model.internetLatencyMs, health != .down {
                Text(String(format: "%.0f ms", ms)).monospacedDigit()
            }
        }
        .task { model.start() }   // keep monitoring even when the main window is closed

        .accessibilityLabel("HomeNet Pulse: \(model.overallSummary)")
    }

    /// Monochrome template icon when healthy (matches the menu bar); coloured when something is wrong.
    static func icon(for health: Health) -> NSImage {
        let name: String = switch health {
        case .good: "wifi.router"
        case .degraded: "exclamationmark.triangle.fill"
        case .down: "wifi.exclamationmark"
        case .unknown: "wifi.router"
        }
        let base = NSImage(systemSymbolName: name, accessibilityDescription: health.label) ?? NSImage()
        let size = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        switch health {
        case .good, .unknown:
            let img = base.withSymbolConfiguration(size) ?? base
            img.isTemplate = true
            return img
        case .degraded, .down:
            let color: NSColor = health == .down ? .systemRed : .systemOrange
            let img = base.withSymbolConfiguration(size.applying(.init(paletteColors: [color]))) ?? base
            img.isTemplate = false
            return img
        }
    }
}

/// The popover shown when the menu bar icon is clicked.
struct MenuBarStatusView: View {
    @Environment(DashboardModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            chain
            if model.internetDown {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Internet is unreachable from this Mac.", systemImage: "wifi.exclamationmark")
                        .font(.callout.weight(.medium)).foregroundStyle(.red)
                    RebootButton().buttonStyle(.bordered)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            footer
        }
        .padding(16)
        .frame(width: 400)
    }

    private var header: some View {
        HStack(spacing: 10) {
            NodeIcon(systemName: model.overallHealth == .down ? "wifi.exclamationmark" : "wifi.router",
                     health: model.overallHealth, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("HomeNet Pulse").font(.headline)
                Text(model.overallSummary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            verificationBadge
        }
    }

    @ViewBuilder private var verificationBadge: some View {
        switch model.verification {
        case .verified:
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green).help("Verified: your network")
        case .mismatch:
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red).help("Not your network")
        case .notConfigured:
            Image(systemName: "questionmark.diamond.fill").foregroundStyle(.orange).help("Network not yet trusted")
        case .checking:
            EmptyView()
        }
    }

    private var chain: some View {
        let b = model.broadband
        return VStack(alignment: .leading, spacing: 0) {
            MenuChainRow(icon: "globe", title: "Internet", health: model.internetHealth,
                         detail: model.internetLatencyMs.map { String(format: "%.0f ms avg", $0) },
                         secondary: model.dnsHealth == .down ? "DNS isn't resolving names"
                            : model.dnsHealth == .degraded ? "DNS partly failing"
                            : settings.pingTargets.joined(separator: ", ") + (model.dnsHealth == .good ? " · DNS OK" : ""),
                         onDetails: { showDetails(.internet) })
            MenuChainConnector(health: model.gatewayHealth == .down ? .down : model.internetHealth)
            MenuChainRow(icon: "fibrechannel", title: "Fiber Gateway", health: model.gatewayHealth,
                         detail: model.routerReachable == false ? "Unreachable" : model.routerPing?.shortSummary,
                         secondary: [b?.lineState.map { "Line \($0)" }, b?.ponFriendly].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                         onDetails: { showDetails(.gateway) })
            MenuChainConnector(health: model.mainRouter?.health ?? .unknown)
            if let r = model.mainRouter {
                MenuChainRow(icon: "wifi.router.fill", title: r.name, health: r.health,
                             detail: r.ping?.shortSummary, secondary: r.ipAddress,
                             connected: model.isConnected(r) ? model.wifi : nil,
                             onDetails: { showDetails(.station(r.id)) })
            } else {
                MenuChainRow(icon: "wifi.router", title: "Router", health: .unknown, detail: nil, secondary: "Searching…")
            }
            ForEach(model.extenders) { e in
                MenuChainConnector(health: e.health)
                MenuChainRow(icon: "wifi.router", title: e.name, health: e.health,
                             detail: e.ping?.shortSummary, secondary: e.ipAddress,
                             connected: model.isConnected(e) ? model.wifi : nil,
                             onDetails: { showDetails(.station(e.id)) })
            }
        }
    }

    /// Open the main window with this item's details showing.
    private func showDetails(_ route: Route) {
        model.requestedRoute = route
        openMainWindow()
    }

    /// Close this popup, then bring up the main window.
    private func openMainWindow() {
        let popup = NSApp.keyWindow
        openWindow(id: "main")
        NSApp.activate()
        popup?.close()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            MenuChainRow(icon: "laptopcomputer.and.iphone", title: "Devices on Network",
                         health: model.lanDevices.isEmpty ? .unknown : .good,
                         detail: model.lanScanning ? "Scanning…" : (model.lanDevices.isEmpty ? nil : "\(model.lanDevices.count)"),
                         secondary: model.lanInterface?.cidr,
                         onDetails: { showDetails(.devices) })
            Divider()
            HStack {
                if let last = model.lastRefresh {
                    Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
                .disabled(model.isRefreshing)
            }
            HStack {
                Button("Open HomeNet Pulse") { openMainWindow() }
                .buttonStyle(.borderedProminent)
                Button("Settings…") {
                    let popup = NSApp.keyWindow
                    openSettings()
                    NSApp.activate()
                    popup?.close()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
    }
}

private struct MenuChainRow: View {
    var icon: String
    var title: String
    var health: Health
    var detail: String?
    var secondary: String?
    var connected: WiFiStatus? = nil
    var onDetails: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            NodeIcon(systemName: icon, health: health, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                if let secondary {
                    Text(secondary).font(.caption).foregroundStyle(.secondary).lineLimit(1).copyable(secondary)
                }
                if let connected {
                    ConnectedBadge(wifi: connected).padding(.top, 2)
                }
            }
            .layoutPriority(1)   // keep the name readable next to the ping / Details button
            Spacer(minLength: 6)
            if hovering, let onDetails {
                DetailsButton(sidebar: true, action: onDetails)
                    .layoutPriority(2)
                    .transition(.opacity)
            } else if let detail {
                Text(detail).font(.caption.monospacedDigit())
                    .foregroundStyle(health == .good || health == .unknown ? Color.secondary : health.color)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Circle().fill(health.color).frame(width: 8, height: 8)
                .help(health.label)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The hover highlight extends slightly past the row without changing its layout width.
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering && onDetails != nil ? Color.primary.opacity(0.06) : .clear)
                .padding(.horizontal, -6)
        }
        .contentShape(Rectangle())
        .onTapGesture { onDetails?() }   // the whole row is clickable
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

private struct MenuChainConnector: View {
    var health: Health
    var body: some View {
        Capsule()
            .fill(health == .unknown ? Color.secondary.opacity(0.35) : health.color.opacity(0.8))
            .frame(width: 2, height: 12)
            .padding(.leading, 13)
            .padding(.vertical, 2)
    }
}
#endif
