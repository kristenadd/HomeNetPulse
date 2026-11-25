import Foundation

/// An Apple AirPort base station discovered via Bonjour (`_airport._tcp`).
struct BaseStation: Identifiable, Sendable, Equatable {
    var id: String { name }
    var name: String
    var hostName: String?
    var txt: [String: String]
    var ipAddress: String?
    var adminPortLatencyMs: Double?
    var adminPortError: String?
    var ping: PingResult?
    var lastSeen = Date()

    /// Ethernet MAC address, normalized to `aa:bb:cc:dd:ee:ff`.
    var ethernetMAC: String? { txt["waMA"].map(Self.normalizeMAC) }
    var wirelessMAC: String? { txt["raMA"].map(Self.normalizeMAC) }
    var firmware: String? { txt["syVs"] }
    var networkName: String? { txt["raNm"] }
    var channel5: String? { txt["raCh"] }
    var channel24: String? { txt["rCh2"] }
    var modelCode: String? { txt["syAP"] }
    var statusFlags: String? { txt["syFl"] }

    var modelName: String {
        switch modelCode {
        case "102": "AirPort Express (802.11g)"
        case "104": "AirPort Extreme (802.11g)"
        case "108": "AirPort Extreme (802.11n)"
        case "109": "Time Capsule (802.11n)"
        case "113": "Time Capsule (802.11n)"
        case "114": "AirPort Extreme (802.11n)"
        case "115": "AirPort Express (802.11n)"
        case "116": "Time Capsule (802.11n)"
        case "117": "AirPort Extreme (802.11n)"
        case "119": "AirPort Time Capsule (802.11ac)"
        case "120": "AirPort Extreme (802.11ac)"
        case let code?: "AirPort (model \(code))"
        case nil: "AirPort"
        }
    }

    var health: Health {
        if let ping, ping.received > 0 { return ping.health }
        if adminPortLatencyMs != nil { return .degraded }   // admin port reachable but ICMP failing
        if ping != nil || adminPortError != nil { return .down }
        return .unknown
    }

    static func normalizeMAC(_ raw: String) -> String {
        raw.replacingOccurrences(of: "-", with: ":").lowercased()
    }
}
