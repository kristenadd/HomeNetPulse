import Foundation
import Observation

enum NetworkVerification: Equatable {
    case checking
    case notConfigured          // nothing trusted yet
    case verified(String)
    case mismatch(String)
}

struct DevicePing: Identifiable, Equatable {
    var id: String { label + host }
    var label: String
    var host: String
    var result: PingResult?
    var rawOutput: String?
    var error: String?
    var running = false
}

@MainActor @Observable
final class DashboardModel {
    let settings: AppSettings
    private let browser = AirPortBrowser()

    var baseStations: [BaseStation] = []
    var discoveryError: String?
    var internetPings: [String: PingResult] = [:]
    /// DNS check: each server × each hostname.
    var dnsResults: [DNSServerResult] = []
    /// This device's configured DNS servers.
    var systemDNS: [String] = []
    var dnsChecking = false
    var routerReachable: Bool?
    var routerLatencyMs: Double?
    var routerPing: PingResult?
    var broadband: BroadbandSummary?
    var routerError: String?
    var devicePings: [DevicePing] = []
    var isRefreshing = false
    var defaultGateway: String?
    var lastRefresh: Date?
    var rebootStatus: String?
    var rebooting = false
    /// Devices found by sweeping the LAN.
    var lanDevices: [LANDevice] = []
    var lanInterface: LocalInterface?
    var lanScanning = false
    var lanProgress: Double = 0
    var lastLANScan: Date?

    /// Gateway speed test (cgi-bin/speed.ha).
    var speedHistory: [SpeedTestEntry] = []
    var speedTestRunning = false
    var speedTestError: String?
    private var lastSpeedHistoryFetch: Date?
    var speedRuns: [SpeedTestRun] { SpeedTestParser.runs(from: speedHistory) }
    var latestSpeedRun: SpeedTestRun? { speedRuns.first }

    /// This device's Wi-Fi connection and the base station it is associated with.
    var wifi: WiFiStatus?
    var connectedStationID: String?
    var connectionMatch: ConnectionMatch?
    private var wifiTask: Task<Void, Never>?

    /// Set by the menu bar popup to ask the main window to show an item's details.
    var requestedRoute: Route?

    private var autoRefreshTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        browser.onChange = { [weak self] stations in self?.baseStations = stations }
        browser.onError = { [weak self] msg in self?.discoveryError = msg }
    }

    /// Idempotent: the window and the menu bar extra both call this.
    func start() {
        guard autoRefreshTask == nil else { return }
        browser.start()
        if settings.useLocationForWiFi && !LocationAccess.shared.isAuthorized && !LocationAccess.shared.isDenied {
            LocationAccess.shared.request()
        }
        // Wi-Fi association changes faster than the full refresh; poll it cheaply.
        wifiTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshWiFi()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        autoRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))   // let Bonjour populate
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.settings.refreshInterval ?? 60
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        wifiTask?.cancel()
        wifiTask = nil
        browser.stop()
    }

    // MARK: - Derived health

    /// Connectivity only (pings), used for the reboot suggestion.
    var pingHealth: Health {
        let results = settings.pingTargets.compactMap { internetPings[$0] }
        guard !results.isEmpty else { return .unknown }
        if results.allSatisfy({ $0.health == .down }) { return .down }
        return results.map(\.health).max() ?? .unknown
    }

    /// The DNS server that matters most: this device's own, else the router, else the ISP's.
    var primaryDNSResult: DNSServerResult? {
        dnsResults.first { $0.server.label.hasPrefix("This device") }
            ?? dnsResults.first { $0.server.label == "Router" }
            ?? dnsResults.first { $0.server.label.hasPrefix("ISP") }
            ?? dnsResults.first
    }

    var dnsHealth: Health { primaryDNSResult?.health ?? .unknown }

    /// Internet health includes DNS: pings can succeed while names don't resolve.
    var internetHealth: Health {
        let p = pingHealth, d = dnsHealth
        if p == .unknown { return d == .down ? .down : .unknown }
        return max(p, d)
    }

    var internetDown: Bool { pingHealth == .down }

    var gatewayHealth: Health {
        guard let reachable = routerReachable else { return .unknown }
        guard reachable else { return routerPing?.received ?? 0 > 0 ? .degraded : .down }
        if let state = broadband?.lineState?.lowercased(), state.contains("down") { return .down }
        return max(routerPing?.health ?? .good, routerError == nil ? .good : .degraded)
    }

    /// The base station acting as the main router: user choice, else the default gateway, else best guess.
    var mainRouter: BaseStation? {
        if let mac = settings.mainRouterMAC, let s = baseStations.first(where: { $0.ethernetMAC == mac }) { return s }
        if let gw = defaultGateway, let s = baseStations.first(where: { $0.ipAddress == gw }) { return s }
        if let s = baseStations.first(where: { $0.ipAddress?.hasSuffix(".1") == true }) { return s }
        if let s = baseStations.first(where: { $0.txt["raNA"] == "1" }) { return s }
        return baseStations.first
    }

    var extenders: [BaseStation] {
        let main = mainRouter?.id
        return baseStations.filter { $0.id != main }
    }

    var extendersHealth: Health {
        extenders.isEmpty ? .unknown : extenders.map(\.health).max() ?? .unknown
    }

    /// Worst health across the chain, for the menu bar icon.
    var overallHealth: Health {
        var parts: [Health] = [internetHealth, gatewayHealth]
        if let r = mainRouter { parts.append(r.health) }
        parts += extenders.map(\.health)
        let known = parts.filter { $0 != .unknown }
        return known.max() ?? .unknown
    }

    /// One-line explanation of the worst problem, for the menu bar tooltip/header.
    var overallSummary: String {
        if pingHealth == .down { return "Internet is unreachable" }
        if dnsHealth == .down { return "DNS isn't resolving names" }
        if gatewayHealth == .down { return "Fiber gateway is not responding" }
        if let r = mainRouter, r.health == .down { return "\(r.name) is not responding" }
        if let e = extenders.first(where: { $0.health == .down }) { return "\(e.name) is not responding" }
        if overallHealth == .degraded { return "Some links are degraded" }
        if overallHealth == .good { return "Everything looks healthy" }
        return "Checking your network…"
    }

    /// Average latency across internet targets, shown next to the menu bar icon.
    var internetLatencyMs: Double? {
        let avgs = settings.pingTargets.compactMap { internetPings[$0]?.avgMs }
        return avgs.isEmpty ? nil : avgs.reduce(0, +) / Double(avgs.count)
    }

    func scanLAN() async {
        guard !lanScanning, let iface = LANScanner.localInterface() else { return }
        lanScanning = true
        lanProgress = 0
        lanInterface = iface
        defer { lanScanning = false; lanProgress = 1 }
        let devices = await LANScanner.scan(iface) { p in
            Task { @MainActor [weak self] in self?.lanProgress = p }
        }
        lanDevices = devices
        lastLANScan = Date()
    }

    enum DeviceRole: Equatable { case thisDevice, mainRouter, baseStation(String) }

    func role(of device: LANDevice) -> DeviceRole? {
        if device.ip == lanInterface?.ip { return .thisDevice }
        if let r = mainRouter, r.ipAddress == device.ip { return .mainRouter }
        if let s = baseStations.first(where: { $0.ipAddress == device.ip }) { return .baseStation(s.name) }
        return nil
    }

    /// Name to show: Bonjour/DNS name, else what we know about the role.
    func displayName(of device: LANDevice) -> String {
        if let n = device.hostName { return n }
        switch role(of: device) {
        case .thisDevice?:
            #if os(macOS)
            return "This Mac"
            #else
            return "This iPhone"
            #endif
        case .mainRouter?: return mainRouter?.name ?? "Router"
        case .baseStation(let name)?: return name
        case nil: return device.manufacturer.map { "\($0) device" } ?? "Unknown device"
        }
    }

    func refreshWiFi() async {
        let status = await WiFiReader.current()
        wifi = status
        if let status, let (station, how) = ConnectionMatcher.match(status, in: baseStations) {
            connectedStationID = station.id
            connectionMatch = how
        } else {
            connectedStationID = nil
            connectionMatch = nil
        }
    }

    func isConnected(_ station: BaseStation) -> Bool { connectedStationID == station.id }

    func setMainRouter(_ station: BaseStation?) {
        settings.mainRouterMAC = station?.ethernetMAC
    }

    var verification: NetworkVerification {
        let found = Set(baseStations.compactMap(\.ethernetMAC))
        let trusted = settings.trustedBaseStationMACs
        if trusted.isEmpty && settings.trustedRouterMAC == nil {
            return baseStations.isEmpty && lastRefresh == nil ? .checking : .notConfigured
        }
        let matched = found.intersection(trusted)
        let routerMatches = settings.trustedRouterMAC != nil && broadband?.wanMAC == settings.trustedRouterMAC
        if !matched.isEmpty || routerMatches {
            var parts: [String] = []
            if !matched.isEmpty { parts.append("\(matched.count) of \(trusted.count) trusted base station\(trusted.count == 1 ? "" : "s")") }
            if routerMatches { parts.append("fiber gateway MAC matches") }
            return .verified(parts.joined(separator: ", "))
        }
        if lastRefresh == nil { return .checking }
        return .mismatch(found.isEmpty ? "No trusted base stations found on this network" : "Base stations found don't match your trusted network")
    }

    func trustCurrentNetwork() {
        settings.trustedBaseStationMACs = Set(baseStations.compactMap(\.ethernetMAC))
        if let mac = broadband?.wanMAC { settings.trustedRouterMAC = mac }
    }

    func forgetTrustedNetwork() {
        settings.trustedBaseStationMACs = []
        settings.trustedRouterMAC = nil
    }

    // MARK: - Refresh

    /// One client (one URLSession + login cookie) reused across refreshes; rebuilt when the
    /// URL or access code changes. Creating a fresh session every minute meant a new login each time.
    private var cachedClient: (key: String, client: RouterClient)?
    private var routerClient: RouterClient? {
        guard let base = settings.routerBaseURL else { return nil }
        let key = base.absoluteString + "\u{1}" + settings.routerPassword
        if let cached = cachedClient, cached.key == key { return cached.client }
        let client = RouterClient(base: base, password: settings.routerPassword)
        cachedClient = (key, client)
        return client
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }
        defaultGateway = DefaultGateway.ipv4()
        if lastLANScan.map({ Date().timeIntervalSince($0) > 10 * 60 }) ?? true {
            Task { await scanLAN() }   // runs alongside; ~10 s
        }
        async let airports: Void = browser.probeAll()
        async let internet: Void = refreshInternet()
        async let router: Void = refreshRouter()
        _ = await (airports, internet, router)
        // DNS last: it needs the router's address and the ISP's DNS servers found above.
        await refreshDNS()
        await refreshWiFi()
    }

    /// Servers to test: this device's configured DNS, the router, the ISP's and two public resolvers.
    /// When this device's server is one of the others, the rows merge ("This device · Router").
    var dnsServers: [DNSServer] {
        var list: [DNSServer] = []
        if let ip = mainRouter?.ipAddress ?? defaultGateway { list.append(DNSServer(label: "Router", ip: ip)) }
        if let d = broadband?.primaryDNS { list.append(DNSServer(label: "ISP primary", ip: d)) }
        if let d = broadband?.secondaryDNS { list.append(DNSServer(label: "ISP secondary", ip: d)) }
        list.append(DNSServer(label: "Cloudflare", ip: "1.1.1.1"))
        list.append(DNSServer(label: "Google", ip: "8.8.8.8"))
        var seen = Set<String>()
        list = list.filter { seen.insert($0.ip).inserted }
        // This device's own servers go first.
        var device: [DNSServer] = []
        for (i, ip) in systemDNS.enumerated() {
            let base = systemDNS.count > 1 ? "This device \(i + 1)" : "This device"
            if let match = list.firstIndex(where: { $0.ip == ip }) {
                device.append(DNSServer(label: "\(base) · \(list[match].label)", ip: ip))
                list.remove(at: match)
            } else {
                device.append(DNSServer(label: base, ip: ip))
            }
        }
        return device + list
    }

    func refreshDNS() async {
        let hosts = settings.dnsHostnames
        guard !hosts.isEmpty, !dnsChecking else { return }
        dnsChecking = true
        defer { dnsChecking = false }
        systemDNS = SystemDNS.servers()
        let servers = dnsServers
        let results = await withTaskGroup(of: DNSServerResult.self) { group in
            for s in servers { group.addTask { await DNSQuery.check(hosts, against: s) } }
            var out: [DNSServerResult] = []
            for await r in group { out.append(r) }
            return out
        }
        let order = Dictionary(uniqueKeysWithValues: servers.enumerated().map { ($1.ip, $0) })
        dnsResults = results.sorted { (order[$0.server.ip] ?? 0) < (order[$1.server.ip] ?? 0) }
    }

    func refreshInternet() async {
        let targets = settings.pingTargets
        await withTaskGroup(of: PingResult.self) { group in
            for t in targets { group.addTask { await Pinger.ping(t, count: 5) } }
            for await r in group { internetPings[r.host] = r }
        }
        internetPings = internetPings.filter { targets.contains($0.key) }
    }

    func refreshRouter() async {
        guard let client = routerClient, let host = settings.routerBaseURL?.host() else {
            routerError = RouterError.invalidURL.localizedDescription
            return
        }
        async let icmp = Pinger.ping(host, count: 3)
        // broadbandstatistics.ha renders quickly (<1 s) and doubles as the web-UI reachability check.
        var start = Date()
        do {
            // Retry a couple of times before declaring the web UI unreachable: on Wi-Fi a single
            // request to the gateway occasionally fails even though it's fine.
            var attempt = 0
            while true {
                do {
                    start = Date()
                    broadband = try await client.broadband()
                    break
                } catch RouterError.unreachable(let msg) {
                    attempt += 1
                    if attempt >= 3 { throw RouterError.unreachable(msg) }
                    try? await Task.sleep(for: .seconds(attempt == 1 ? 3 : 8))
                }
            }
            routerReachable = true
            routerLatencyMs = Date().timeIntervalSince(start) * 1000
            routerError = nil
        } catch RouterError.unreachable(let msg) {
            routerReachable = false
            routerLatencyMs = nil
            routerError = "Gateway web interface is not responding (\(msg))."
        } catch {
            routerReachable = true
            routerLatencyMs = Date().timeIntervalSince(start) * 1000
            routerError = error.localizedDescription
        }
        routerPing = await icmp
        // Speed history needs a login, so only re-read it occasionally.
        if routerReachable == true, !settings.routerPassword.isEmpty,
           lastSpeedHistoryFetch.map({ Date().timeIntervalSince($0) > 15 * 60 }) ?? true {
            await loadSpeedHistory()
        }
        rebuildDevicePingList()
    }

    private func rebuildDevicePingList() {
        var list: [(String, String)] = []
        if let gw = broadband?.gatewayIPv4 { list.append(("ISP Gateway", gw)) }
        if let d = broadband?.primaryDNS { list.append(("ISP Primary DNS", d)) }
        if let d = broadband?.secondaryDNS { list.append(("ISP Secondary DNS", d)) }
        for t in settings.pingTargets { list.append(("Internet", t)) }
        let existing = Dictionary(devicePings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        devicePings = list.map { label, host in existing[label + host] ?? DevicePing(label: label, host: host) }
    }

    /// Ping from the gateway itself (cgi-bin/diag.ha). Runs sequentially: the gateway handles one test at a time.
    func runDevicePings() async {
        if devicePings.isEmpty { rebuildDevicePingList() }
        guard let client = routerClient else { return }
        for i in devicePings.indices {
            devicePings[i].running = true
            do {
                let (result, raw) = try await client.devicePing(devicePings[i].host)
                devicePings[i].result = result
                devicePings[i].rawOutput = raw
                devicePings[i].error = nil
            } catch {
                devicePings[i].error = error.localizedDescription
            }
            devicePings[i].running = false
        }
    }

    func loadSpeedHistory() async {
        guard let client = routerClient else { return }
        guard !settings.routerPassword.isEmpty else {
            speedTestError = RouterError.missingPassword.localizedDescription
            return
        }
        do {
            speedHistory = try await client.speedTestHistory()
            lastSpeedHistoryFetch = Date()
            speedTestError = nil
        } catch {
            speedTestError = error.localizedDescription
        }
    }

    func runSpeedTest() async {
        guard let client = routerClient, !speedTestRunning else { return }
        guard !settings.routerPassword.isEmpty else {
            speedTestError = RouterError.missingPassword.localizedDescription
            return
        }
        speedTestRunning = true
        speedTestError = nil
        defer { speedTestRunning = false }
        do {
            speedHistory = try await client.runSpeedTest()
            lastSpeedHistoryFetch = Date()
        } catch {
            speedTestError = error.localizedDescription
        }
    }

    func rebootRouter() async {
        guard let client = routerClient else { return }
        rebooting = true
        defer { rebooting = false }
        do {
            _ = try await client.restart()
        } catch {
            rebootStatus = "Reboot failed: \(error.localizedDescription)"
            return
        }
        // Watch the gateway go down and come back (a BGW restart usually takes 3–5 minutes).
        let started = Date()
        rebootStatus = "Restart requested. Waiting for the gateway to go offline…"
        var wentDown = false
        while Date().timeIntervalSince(started) < 15 * 60 {
            try? await Task.sleep(for: .seconds(10))
            let probe = RouterClient(base: client.baseURL, password: "")
            let up = (try? await probe.broadband()) != nil
            let elapsed = Int(Date().timeIntervalSince(started))
            let clock = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
            if !up {
                wentDown = true
                routerReachable = false
                rebootStatus = "Gateway is restarting… (\(clock))"
            } else if wentDown {
                rebootStatus = "Gateway is back online after \(clock)."
                await refresh()
                return
            } else if elapsed > 120 {
                rebootStatus = "The gateway never went offline. The restart may not have started."
                return
            }
        }
        rebootStatus = "The gateway hasn't come back after 15 minutes. Check its lights and power."
    }
}
