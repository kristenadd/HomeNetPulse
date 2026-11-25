import Foundation
#if os(macOS)
import CoreWLAN
#else
import NetworkExtension
#endif

/// This device's current Wi-Fi association.
struct WiFiStatus: Sendable, Equatable {
    enum Band: String, Sendable { case ghz24 = "2.4 GHz", ghz5 = "5 GHz", ghz6 = "6 GHz" }

    var ssid: String?
    var bssid: String?          // nil unless Location access is granted
    var channel: Int?
    var band: Band?
    var channelWidthMHz: Int?
    var rssi: Int?              // dBm (macOS)
    var noise: Int?             // dBm (macOS)
    var txRateMbps: Double?     // macOS
    var signalFraction: Double? // 0…1 (iOS)

    var snr: Int? { if let rssi, let noise { rssi - noise } else { nil } }

    var signalQuality: String? {
        if let rssi {
            return switch rssi {
            case (-60)...: "Excellent"
            case (-67)...: "Good"
            case (-75)...: "Fair"
            default: "Poor"
            }
        }
        if let f = signalFraction {
            return f > 0.75 ? "Excellent" : f > 0.5 ? "Good" : f > 0.25 ? "Fair" : "Poor"
        }
        return nil
    }

    /// 0…4 bars for the signal glyph.
    var bars: Int {
        if let rssi { return rssi >= -60 ? 4 : rssi >= -67 ? 3 : rssi >= -75 ? 2 : 1 }
        if let f = signalFraction { return max(1, Int((f * 4).rounded(.up))) }
        return 0
    }

    var signalText: String? {
        if let rssi { return "\(rssi) dBm" }
        if let f = signalFraction { return String(format: "%.0f%%", f * 100) }
        return nil
    }

    /// Centre frequency of the current channel.
    var frequencyMHz: Int? {
        guard let channel else { return nil }
        switch band {
        case .ghz24?: return channel == 14 ? 2484 : 2407 + 5 * channel
        case .ghz5?: return 5000 + 5 * channel
        case .ghz6?: return 5950 + 5 * channel
        case nil: return nil
        }
    }

    /// e.g. "5 GHz · 5560 MHz"
    var frequencyText: String? {
        guard let band else { return nil }
        return [band.rawValue, frequencyMHz.map { "\($0) MHz" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// Short summary for badges: "5 GHz · −37 dBm"
    var badgeText: String {
        [band?.rawValue, signalText].compactMap { $0 }.joined(separator: " · ")
    }

    var channelText: String? {
        guard let channel else { return nil }
        return [band?.rawValue, "channel \(channel)"].compactMap { $0 }.joined(separator: " ")
    }
}

enum WiFiReader {
    #if os(macOS)
    static func current() async -> WiFiStatus? {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn() else { return nil }
        var s = WiFiStatus()
        s.ssid = iface.ssid()
        s.bssid = iface.bssid().map(BaseStation.normalizeMAC)
        if let ch = iface.wlanChannel() {
            s.channel = ch.channelNumber
            s.band = switch ch.channelBand {
            case .band2GHz: .ghz24
            case .band5GHz: .ghz5
            case .band6GHz: .ghz6
            default: nil
            }
            s.channelWidthMHz = switch ch.channelWidth {
            case .width20MHz: 20
            case .width40MHz: 40
            case .width80MHz: 80
            case .width160MHz: 160
            default: nil
            }
        }
        let rssi = iface.rssiValue()
        s.rssi = rssi == 0 ? nil : rssi
        let noise = iface.noiseMeasurement()
        s.noise = noise == 0 ? nil : noise
        let rate = iface.transmitRate()
        s.txRateMbps = rate > 0 ? rate : nil
        // Not associated with any network.
        if s.channel == nil && s.rssi == nil { return nil }
        return s
    }
    #else
    /// Requires the "Access Wi-Fi Information" entitlement and Location permission.
    static func current() async -> WiFiStatus? {
        guard let net = await NEHotspotNetwork.fetchCurrent() else { return nil }
        var s = WiFiStatus()
        s.ssid = net.ssid
        s.bssid = BaseStation.normalizeMAC(net.bssid)
        s.signalFraction = net.signalStrength > 0 ? net.signalStrength : nil
        return s
    }
    #endif
}

/// How the connected base station was identified.
enum ConnectionMatch: Equatable, Sendable {
    case bssid
    case channel

    var label: String {
        switch self {
        case .bssid: "matched by access point address (BSSID)"
        case .channel: "matched by Wi-Fi channel"
        }
    }
}

enum ConnectionMatcher {
    /// AirPorts advertise radio MACs in raMA / raM2; each SSID's BSSID is that MAC or a nearby one.
    static func matches(bssid: String, station: BaseStation) -> Bool {
        let radios = [station.txt["raMA"], station.txt["raM2"]].compactMap { $0.map(BaseStation.normalizeMAC) }
        for radio in radios {
            if radio == bssid { return true }
            let a = radio.split(separator: ":"), b = bssid.split(separator: ":")
            guard a.count == 6, b.count == 6, a.prefix(5) == b.prefix(5),
                  let x = Int(a[5], radix: 16), let y = Int(b[5], radix: 16) else { continue }
            if abs(x - y) <= 3 { return true }
        }
        return false
    }

    static func match(_ wifi: WiFiStatus, in stations: [BaseStation]) -> (BaseStation, ConnectionMatch)? {
        if let bssid = wifi.bssid, let s = stations.first(where: { matches(bssid: bssid, station: $0) }) {
            return (s, .bssid)
        }
        guard let ch = wifi.channel.map(String.init) else { return nil }
        let candidates = stations.filter { s in
            switch wifi.band {
            case .ghz5?: s.channel5 == ch
            case .ghz24?: s.channel24 == ch
            default: s.channel5 == ch || s.channel24 == ch
            }
        }
        // Only trust a channel match when it is unambiguous.
        return candidates.count == 1 ? (candidates[0], .channel) : nil
    }
}
