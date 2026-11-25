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
        browser.stop()
    }

    // MARK: - Derived health

    var internetHealth: Health {
        let results = settings.pingTargets.compactMap { internetPings[$0] }
        guard !results.isEmpty else { return .unknown }
        if results.allSatisfy({ $0.health == .down }) { return .down }
        return results.map(\.health).max() ?? .unknown
    }

    var internetDown: Bool { internetHealth == .down }

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
        if internetHealth == .down { return "Internet is unreachable" }
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

    private var routerClient: RouterClient? {
        guard let base = settings.routerBaseURL else { return nil }
        return RouterClient(base: base, password: settings.routerPassword)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }
        defaultGateway = DefaultGateway.ipv4()
        async let airports: Void = browser.probeAll()
        async let internet: Void = refreshInternet()
        async let router: Void = refreshRouter()
        _ = await (airports, internet, router)
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
        let start = Date()
        do {
            broadband = try await client.broadband()
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

    func rebootRouter() async {
        guard let client = routerClient else { return }
        rebooting = true
        defer { rebooting = false }
        do {
            rebootStatus = try await client.restart()
        } catch {
            rebootStatus = "Reboot failed: \(error.localizedDescription)"
        }
    }
}
