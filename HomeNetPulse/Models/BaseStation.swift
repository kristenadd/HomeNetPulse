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

    /// How an extender reaches the main router, inferred from the radio channels in Bonjour.
    /// A wireless extender joins the main router's network on one radio, so that radio must share
    /// the router's channel. No shared channel on either band means the link must be Ethernet.
    enum Backhaul: Equatable, Sendable {
        case ethernet
        case possiblyWireless(band: String)

        var label: String {
            switch self {
            case .ethernet: "Ethernet"
            case .possiblyWireless: "Possibly wireless"
            }
        }

        var explanation: String {
            switch self {
            case .ethernet:
                "Neither radio shares a channel with the main router, so it can't be extending wirelessly."
            case .possiblyWireless(let band):
                "Its \(band) radio is on the main router's channel. That's needed to extend wirelessly, but a wired station can match by chance."
            }
        }
    }

    func backhaul(to main: BaseStation) -> Backhaul? {
        guard main.id != id else { return nil }
        let pairs = [("5 GHz", channel5, main.channel5), ("2.4 GHz", channel24, main.channel24)]
        guard pairs.contains(where: { $0.1 != nil && $0.2 != nil }) else { return nil }
        if let match = pairs.first(where: { $0.1 != nil && $0.1 == $0.2 }) { return .possiblyWireless(band: match.0) }
        return .ethernet
    }

    static func normalizeMAC(_ raw: String) -> String {
        raw.replacingOccurrences(of: "-", with: ":").lowercased()
    }
}
