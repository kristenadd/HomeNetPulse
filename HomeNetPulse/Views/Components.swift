import SwiftUI

extension Health {
    var color: Color {
        switch self {
        case .good: .green
        case .degraded: .orange
        case .down: .red
        case .unknown: .secondary
        }
    }
    var label: String {
        switch self {
        case .good: "Healthy"
        case .degraded: "Degraded"
        case .down: "Down"
        case .unknown: "Unknown"
        }
    }
    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .down: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

struct HealthBadge: View {
    var health: Health
    var body: some View {
        Label(health.label, systemImage: health.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(health.color)
            .labelStyle(.titleAndIcon)
    }
}

struct PingSummary: View {
    var result: PingResult?
    var body: some View {
        if let r = result {
            if r.received > 0 {
                HStack(spacing: 10) {
                    Text(String(format: "%.1f ms", r.avgMs ?? 0)).monospacedDigit()
                    Text(String(format: "%.0f%% loss", r.lossPercent)).foregroundStyle(r.lossPercent > 0 ? .orange : .secondary)
                    if let j = r.jitterMs {
                        Text(String(format: "±%.1f", j)).foregroundStyle(.secondary)
                    }
                }
                .font(.caption.monospacedDigit())
            } else {
                Text(r.error ?? "No replies").font(.caption).foregroundStyle(.red)
            }
        } else {
            Text("Not tested").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct KeyValueRow: View {
    var key: String
    var value: String?
    var body: some View {
        LabeledContent(key) {
            Text(value ?? "—").textSelection(.enabled).monospacedDigit()
        }
    }
}
