import SwiftUI

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
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                NodeIcon(systemName: icon, health: health, size: Topology.iconSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                HealthPill(health: health, text: statusText)
                accessory
            }
            content
        }
        .padding(Topology.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(health == .unknown ? Color.secondary.opacity(0.2) : health.color.opacity(0.35), lineWidth: 1)
        )
    }
}

extension TopologyNode where Accessory == EmptyView {
    init(title: String, subtitle: String?, icon: String, health: Health, statusText: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, icon: icon, health: health, statusText: statusText,
                  content: content, accessory: { EmptyView() })
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .topLeading)], alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label.uppercased()).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    Text(item.value ?? "—")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(item.tint ?? .primary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, Topology.iconSize + 12)
    }
}

extension PingResult {
    var shortSummary: String {
        guard received > 0, let avg = avgMs else { return "no reply" }
        return lossPercent > 0 ? String(format: "%.0f ms · %.0f%% loss", avg, lossPercent) : String(format: "%.0f ms", avg)
    }
    var tint: Color? { health == .good ? nil : health.color }
}
