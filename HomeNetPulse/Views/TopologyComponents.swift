import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Rounded status capsule, e.g. "● Healthy".
struct HealthPill: View {
    var health: Health
    var text: String?
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(health.color).frame(width: 7, height: 7)
            Text(text ?? health.label)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(health.color.opacity(0.14), in: Capsule())
        .foregroundStyle(health == .unknown ? Color.secondary : health.color)
    }
}

/// Icon in a tinted circle that anchors the connector line.
struct NodeIcon: View {
    var systemName: String
    var health: Health
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(health == .unknown ? Color.secondary : health.color)
            .frame(width: size, height: size)
            .background(Circle().fill(health.color.opacity(0.15)))
            .overlay(Circle().strokeBorder(health.color.opacity(0.45), lineWidth: 1.5))
    }
}

enum Topology {
    static let cardPadding: CGFloat = 16
    static let iconSize: CGFloat = 44
    /// x-position of the icon's centre inside a card; connectors line up with it.
    static var spineX: CGFloat { cardPadding + iconSize / 2 }
}

/// A card in the topology chain.
struct TopologyNode<Content: View, Accessory: View>: View {
    var title: String
    var subtitle: String?
    var icon: String
    var health: Health
    var statusText: String?
    var connected: WiFiStatus? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                NodeIcon(systemName: icon, health: health, size: Topology.iconSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                    if let subtitle {
                        Text(subtitle).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .copyable(subtitle)
                    }
                    if let connected { ConnectedBadge(wifi: connected).padding(.top, 2) }
                }
                Spacer(minLength: 8)
                HealthPill(health: health, text: statusText).fixedSize()
                accessory
            }
            content
        }
        .padding(Topology.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(health == .unknown ? Color.secondary.opacity(0.2) : health.color.opacity(0.35), lineWidth: 1)
        )
    }
}

extension TopologyNode where Accessory == EmptyView {
    init(title: String, subtitle: String?, icon: String, health: Health, statusText: String? = nil,
         connected: WiFiStatus? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, icon: icon, health: health, statusText: statusText,
                  connected: connected, content: content, accessory: { EmptyView() })
    }
}

/// The vertical link between two nodes, coloured by the health of the downstream hop.
struct TopologyConnector: View {
    var health: Health
    var label: String?
    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(health == .unknown ? Color.secondary.opacity(0.35) : health.color.opacity(0.8))
                .frame(width: 3, height: 34)
                .overlay {
                    if health == .down {
                        Image(systemName: "xmark").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(3).background(Circle().fill(.red))
                    }
                }
            if let label {
                Text(label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.leading, Topology.spineX - 1.5)
        .accessibilityElement(children: .combine)
    }
}

/// Compact grid of label/value metrics inside a node.
struct MetricGrid: View {
    struct Item: Identifiable {
        var id: String { label }
        var label: String
        var value: String?
        var tint: Color? = nil
    }
    var items: [Item]
    var body: some View {
        EqualColumns(minColumnWidth: 130, hSpacing: 8, vSpacing: 10) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label.uppercased()).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    Text(item.value ?? "—")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(item.tint ?? .primary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .copyable(item.value, label: item.label)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, Topology.iconSize + 12)
    }
}

extension PingResult {
    var shortSummary: String {
        guard received > 0, let avg = avgMs else { return "no reply" }
        let ms = avg < 10 ? String(format: "%.1f ms", avg) : String(format: "%.0f ms", avg)
        return lossPercent > 0 ? String(format: "%@ · %.0f%% loss", ms, lossPercent) : ms
    }
    var tint: Color? { health == .good ? nil : health.color }
}

/// "Connected · 5 GHz · −37 dBm" with live Wi-Fi bars, shown on the base station this device uses.
struct ConnectedBadge: View {
    var wifi: WiFiStatus
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "wifi", variableValue: Double(wifi.bars) / 4)
                .font(.caption.weight(.semibold))
            Text(compact || wifi.badgeText.isEmpty ? "Connected" : "Connected · \(wifi.badgeText)")
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .fixedSize()
        .help([wifi.channelText, wifi.signalQuality.map { "\($0) signal" }]
            .compactMap { $0 }.joined(separator: " · "))
        .accessibilityLabel("Connected, \(wifi.badgeText)")
    }
}

/// The one "Details" button used on every card and in the menu bar popup, so they all look alike.
struct DetailsButton: View {
    /// Mac/iPad open details in a side inspector (sidebar icon); iPhone pushes (chevron).
    var sidebar: Bool
    var iconOnly = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if iconOnly {
                Image(systemName: sidebar ? "sidebar.trailing" : "chevron.right")
                    .accessibilityLabel("Details")
            } else {
                Label("Details", systemImage: sidebar ? "sidebar.trailing" : "chevron.right")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .lineLimit(1)
        .fixedSize()
    }
}

/// Opens AirPort Utility: the built-in app on Mac; on iPhone/iPad its App Store page, which shows
/// "Open" when it's installed and "Get" when it isn't.
struct ManageAirPortButton: View {
    @Environment(\.openURL) private var openURL
    var compact = false
    var prominent = false

    static let appStoreURL = URL(string: "https://apps.apple.com/app/id427276530")!   // AirPort Utility

    var body: some View {
        let button = Button(action: open) {
            if compact {
                Image(systemName: "slider.horizontal.3").accessibilityLabel("Manage in AirPort Utility")
            } else {
                Label("Manage", systemImage: "slider.horizontal.3")
            }
        }
        .controlSize(.small)
        .lineLimit(1)
        .fixedSize()
        .help("Open AirPort Utility")
        if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    }

    private func open() {
        #if os(macOS)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.airport.airportutility") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            openURL(Self.appStoreURL)
        }
        #else
        openURL(URL(string: "itms-apps://apps.apple.com/app/id427276530") ?? Self.appStoreURL)
        #endif
    }
}

/// Opens the gateway's own web interface in the default browser.
struct ManageGatewayButton: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    var compact = false

    var body: some View {
        Button {
            if let url = settings.routerBaseURL { openURL(url) }
        } label: {
            if compact {
                Image(systemName: "safari").accessibilityLabel("Manage")
            } else {
                Label("Manage", systemImage: "safari")
            }
        }
        .disabled(settings.routerBaseURL == nil)
        .help("Open \(settings.routerBaseURL?.absoluteString ?? "the gateway") in your browser")
    }
}

extension View {
    /// Accent outline marking the card whose details are open in the inspector.
    func selectedOutline(_ selected: Bool, cornerRadius: CGFloat = 16) -> some View {
        overlay {
            if selected {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }
}
