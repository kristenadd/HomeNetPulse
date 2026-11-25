import Foundation
import Observation
import Security

/// Non-secret preferences, persisted in UserDefaults.
@MainActor @Observable
final class AppSettings {
    static let defaultTargets = ["1.1.1.1", "8.8.8.8"]
    static let defaultDNSHostnames = ["apple.com", "google.com", "amazon.com"]
    static let defaultRouterURL = "http://192.168.0.254/"

    var pingTargets: [String] { didSet { save() } }
    /// Hostnames resolved against each DNS server to check DNS health.
    var dnsHostnames: [String] { didSet { save() } }
    var refreshInterval: Double { didSet { save() } }
    /// Ethernet MACs (waMA) of base stations that belong to "my" network.
    var trustedBaseStationMACs: Set<String> { didSet { save() } }
    /// WAN MAC of the fiber gateway, captured when the network was trusted.
    var trustedRouterMAC: String? { didSet { save() } }
    /// User override for which base station is the main (NAT) router; nil = auto-detect.
    var mainRouterMAC: String? { didSet { save() } }

    var showMenuBarIcon: Bool { didSet { save() } }
    /// Use Location access to read the Wi-Fi BSSID for an exact base station match.
    var useLocationForWiFi: Bool { didSet { save() } }
    var showLatencyInMenuBar: Bool { didSet { save() } }

    var routerURL: String
    var routerPassword: String

    private let defaults = UserDefaults.standard

    init() {
        Self.migrateFromSandboxContainer()
        pingTargets = defaults.stringArray(forKey: "pingTargets") ?? Self.defaultTargets
        dnsHostnames = defaults.stringArray(forKey: "dnsHostnames") ?? Self.defaultDNSHostnames
        let interval = defaults.double(forKey: "refreshInterval")
        refreshInterval = interval == 0 ? 60 : interval
        trustedBaseStationMACs = Set(defaults.stringArray(forKey: "trustedMACs") ?? [])
        trustedRouterMAC = defaults.string(forKey: "trustedRouterMAC")
        mainRouterMAC = defaults.string(forKey: "mainRouterMAC")
        useLocationForWiFi = defaults.bool(forKey: "useLocationForWiFi")
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") == nil ? true : defaults.bool(forKey: "showMenuBarIcon")
        showLatencyInMenuBar = defaults.object(forKey: "showLatencyInMenuBar") == nil ? true : defaults.bool(forKey: "showLatencyInMenuBar")
        let creds = RouterCredentialStore.load()
        routerURL = creds?.url ?? Self.defaultRouterURL
        routerPassword = creds?.password ?? ""
    }

    /// The app used to be sandboxed; its preferences lived in its container. Copy them once.
    private static func migrateFromSandboxContainer() {
        #if os(macOS)
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromSandbox"),
              let id = Bundle.main.bundleIdentifier else { return }
        let path = NSHomeDirectory() + "/Library/Containers/\(id)/Data/Library/Preferences/\(id).plist"
        if let old = NSDictionary(contentsOfFile: path) as? [String: Any] {
            let keys = ["pingTargets", "dnsHostnames", "refreshInterval", "trustedMACs", "trustedRouterMAC", "mainRouterMAC",
                        "showMenuBarIcon", "showLatencyInMenuBar", "useLocationForWiFi"]
            for k in keys where d.object(forKey: k) == nil {
                if let v = old[k] { d.set(v, forKey: k) }
            }
        }
        d.set(true, forKey: "migratedFromSandbox")
        #endif
    }

    private func save() {
        defaults.set(pingTargets, forKey: "pingTargets")
        defaults.set(dnsHostnames, forKey: "dnsHostnames")
        defaults.set(refreshInterval, forKey: "refreshInterval")
        defaults.set(Array(trustedBaseStationMACs).sorted(), forKey: "trustedMACs")
        defaults.set(trustedRouterMAC, forKey: "trustedRouterMAC")
        defaults.set(mainRouterMAC, forKey: "mainRouterMAC")
        defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon")
        defaults.set(useLocationForWiFi, forKey: "useLocationForWiFi")
        defaults.set(showLatencyInMenuBar, forKey: "showLatencyInMenuBar")
    }

    @discardableResult
    func saveRouterCredentials(url: String, password: String) -> OSStatus {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.lowercased().hasPrefix("http") { trimmed = "http://" + trimmed }
        routerURL = trimmed
        routerPassword = password
        return RouterCredentialStore.save(.init(url: trimmed, password: password))
    }

    var routerBaseURL: URL? {
        guard var comps = URLComponents(string: routerURL) else { return nil }
        comps.path = "/"
        comps.query = nil
        return comps.url
    }
}
