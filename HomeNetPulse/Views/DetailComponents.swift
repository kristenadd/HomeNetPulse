import SwiftUI

/// Big header at the top of a detail page.
struct DetailHeader: View {
    var icon: String
    var title: String
    var subtitle: String?
    var health: Health
    var statusText: String?
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            NodeIcon(systemName: icon, health: health, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.bold)).lineLimit(2).copyable(title, label: "Name")
                if let subtitle {
                    Text(subtitle).font(.subheadline.monospaced()).foregroundStyle(.secondary).copyable(subtitle)
                }
                HealthPill(health: health, text: statusText).padding(.top, 2)
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close details")
            }
        }
    }
}

/// A big-number stat, e.g. "12 ms / AVG PING".
struct StatTile: View {
    var label: String
    var value: String
    var unit: String? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint ?? .primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            Text(label.uppercased()).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .copyable(value == "—" ? nil : [value, unit].compactMap { $0 }.joined(separator: " "), label: label.capitalized)
    }
}

struct StatTileGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) { content }
    }
}

/// A titled, rounded group of rows.
struct DetailCard<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Key/value line inside a DetailCard, with a hairline separator below.
struct DetailRow: View {
    var key: String
    var value: String?
    var mono = true
    var tint: Color? = nil
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(key).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value ?? "—")
                    .font(mono ? .callout.monospaced() : .callout)
                    .foregroundStyle(tint ?? .primary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .copyable(value, label: key)
            }
            .font(.callout)
            .padding(.vertical, 9)
            if !last { Divider() }
        }
    }
}

/// Bar sparkline of individual round-trip times.
struct RTTSparkline: View {
    var rtts: [Double]
    var lost: Int = 0
    var tint: Color = .green

    var body: some View {
        let maxV = max(rtts.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(rtts.enumerated()), id: \.offset) { _, v in
                Capsule().fill(tint.gradient)
                    .frame(width: 6, height: max(4, 22 * v / maxV))
            }
            ForEach(0..<max(lost, 0), id: \.self) { _ in
                Capsule().fill(Color.red.opacity(0.6)).frame(width: 6, height: 4)
            }
        }
        .frame(height: 22, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Ping result row: label, host, sparkline and stats, with expandable raw output.
struct PingResultCard: View {
    var label: String
    var host: String
    var result: PingResult?
    var error: String?
    var running = false
    var rawOutput: String?
    var last = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Text(host).font(.callout.monospaced()).copyable(host)
                }
                Spacer(minLength: 8)
                if running {
                    ProgressView().controlSize(.small)
                } else if let r = result {
                    RTTSparkline(rtts: r.rttsMs, lost: r.sent - r.received, tint: r.health.color)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(r.avgMs.map { String(format: "%.1f ms", $0) } ?? "—").font(.callout.monospacedDigit().weight(.semibold))
                        Text(String(format: "%.0f%% loss", r.lossPercent)).font(.caption2.monospacedDigit())
                            .foregroundStyle(r.lossPercent > 0 ? .orange : .secondary)
                    }
                    .frame(minWidth: 64, alignment: .trailing)
                } else {
                    Text(error == nil ? "Not run" : "Failed").font(.caption).foregroundStyle(error == nil ? Color.secondary : .red)
                }
                if rawOutput != nil {
                    Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                        Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Hide output" : "Show output")
                }
            }
            .padding(.vertical, 10)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.bottom, 8)
            }
            if expanded, let rawOutput {
                Text(rawOutput)
                    .font(.caption2.monospaced())
                    .copyable(rawOutput, label: "Output")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.insetBackground, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 10)
            }
            if !last { Divider() }
        }
    }
}

/// Collapsible card (used for the long broadband statistics tables).
struct CollapsibleCard<Content: View>: View {
    var title: String
    var systemImage: String
    var initiallyExpanded = false
    @ViewBuilder var content: Content
    @State private var expanded: Bool?

    var body: some View {
        let isOpen = expanded ?? initiallyExpanded
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { expanded = !isOpen } } label: {
                HStack {
                    Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Scroll container shared by detail pages: readable width on iPhone pushes, natural width in inspectors.
struct DetailPage<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(18)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.platformGroupedBackground)
        #endif
    }
}
