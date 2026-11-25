import Foundation

/// One digital-optical-monitoring reading from cgi-bin/fiberstat.ha (temperature, Tx/Rx power…),
/// with the module's own alarm / warning thresholds.
struct OpticalMetric: Sendable, Equatable, Identifiable {
    enum Status: Int, Sendable, Comparable {
        case ok, warning, alarm
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
        var label: String { switch self { case .ok: "OK"; case .warning: "Warning"; case .alarm: "Alarm" } }
        var health: Health { switch self { case .ok: .good; case .warning: .degraded; case .alarm: .down } }
    }

    var id: String { name }
    var name: String          // as on the page, e.g. "Rx Power"
    var value: Double         // scaled to `unit`
    var unit: String
    var alarmLow: Double?
    var alarmHigh: Double?
    var warnLow: Double?
    var warnHigh: Double?
    /// The module's own flags (1 = raised).
    var alarmLowFlag = false, alarmHighFlag = false, warnLowFlag = false, warnHighFlag = false

    var status: Status {
        if alarmLowFlag || alarmHighFlag { return .alarm }
        if let l = alarmLow, let h = alarmHigh, l < h, value < l || value > h { return .alarm }
        if warnLowFlag || warnHighFlag { return .warning }
        if let l = warnLow, let h = warnHigh, l < h, value < l || value > h { return .warning }
        return .ok
    }

    var displayName: String {
        switch name.lowercased() {
        case "tx power": "Transmit power"
        case "rx power": "Receive power"
        case "tx bias": "Transmit bias"
        case "vcc": "Supply voltage"
        default: name
        }
    }

    var valueText: String { Self.format(value, unit) }

    /// e.g. "OK range −27.9 to −10.0 dBm"
    var rangeText: String? {
        guard let l = warnLow, let h = warnHigh, l < h else { return nil }
        return "normal \(Self.format(l, "")) to \(Self.format(h, unit))".replacingOccurrences(of: "  ", with: " ")
    }

    /// Distance to the nearest warning threshold, e.g. "5.3 dB above the low limit".
    var marginText: String? {
        guard let l = warnLow, let h = warnHigh, l < h, status == .ok, !unit.isEmpty else { return nil }
        let below = value - l, above = h - value
        let u = unit == "dBm" ? "dB" : unit
        return below <= above ? "\(Self.format(below, u)) above the low limit" : "\(Self.format(above, u)) below the high limit"
    }

    static func format(_ v: Double, _ unit: String) -> String {
        let num: String = v.rounded() == v && unit != "dBm" && unit != "dB" ? String(Int(v)) : String(format: "%.1f", v)
        let signed = num.replacingOccurrences(of: "-", with: "−")
        return unit.isEmpty ? signed : (unit == "°C" ? "\(signed) °C" : "\(signed) \(unit)")
    }
}

struct FiberStatus: Sendable, Equatable {
    var info: [StatRow] = []
    var metrics: [OpticalMetric] = []

    func value(_ key: String) -> String? {
        info.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value.nilIfEmpty
    }
    func metric(_ name: String) -> OpticalMetric? {
        metrics.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var linkUp: Bool? { value("Link State").map { $0.lowercased() == "up" } }
    var operationalUp: Bool? { value("Optical WAN Operational Status").map { $0.lowercased() == "up" } }
    var wavelength: String? { value("Wave Length") }
    var module: String? {
        [value("Vendor Name"), value("Vendor PN")].compactMap { $0 }.joined(separator: " ").nilIfEmpty
    }

    var status: OpticalMetric.Status {
        if linkUp == false || operationalUp == false { return .alarm }
        return metrics.map(\.status).max() ?? .ok
    }

    /// "OK · Rx −22.6 dBm · 42 °C"
    var summary: String {
        var parts = [status.label]
        if let rx = metric("Rx Power") { parts.append("Rx \(rx.valueText)") }
        if let t = metric("Temperature") { parts.append(t.valueText) }
        return parts.joined(separator: " · ")
    }
}

enum FiberStatusParser {
    static func parse(_ html: String) -> FiberStatus {
        var status = FiberStatus()
        // Key/value rows (th + td) before the monitoring tables.
        status.info = BroadbandParser.pairs(in: html)
        // "<h1>Rx Power&nbsp;&nbsp;Currently -226</h1>" followed by its threshold table.
        for m in HTML.matches(#"<h1>\s*([^<]*?)(?:&nbsp;|\s)+Currently\s+(-?[0-9.]+)\s*</h1>(.*?)</table>"#, in: html) {
            let name = HTML.stripTags(m[1])
            guard let raw = Double(m[2]) else { continue }
            let (scale, unit) = units(for: name)
            var metric = OpticalMetric(name: name, value: raw * scale, unit: unit)
            for row in HTML.matches(#"<tr[^>]*>\s*<td[^>]*>\s*(Alarm|Warning)\s*</td>\s*<td[^>]*>\s*(\d+)\s*\(Threshold\s*(-?[0-9.]+)\)\s*</td>\s*<td[^>]*>\s*(\d+)\s*\(Threshold\s*(-?[0-9.]+)\)\s*</td>"#, in: m[3]) {
                let lowFlag = row[2] != "0", highFlag = row[4] != "0"
                let low = Double(row[3]).map { $0 * scale }, high = Double(row[5]).map { $0 * scale }
                if row[1].lowercased() == "alarm" {
                    metric.alarmLowFlag = lowFlag; metric.alarmHighFlag = highFlag
                    metric.alarmLow = low; metric.alarmHigh = high
                } else {
                    metric.warnLowFlag = lowFlag; metric.warnHighFlag = highFlag
                    metric.warnLow = low; metric.warnHigh = high
                }
            }
            status.metrics.append(metric)
        }
        return status
    }

    /// The gateway reports optical power in tenths of a dBm; temperature in °C.
    static func units(for name: String) -> (Double, String) {
        switch name.lowercased() {
        case "tx power", "rx power": (0.1, "dBm")
        case "temperature": (1, "°C")
        case "vcc": (1, "V")
        default: (1, "")
        }
    }
}
