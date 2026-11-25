import Foundation
import Network

/// Discovers AirPort base stations on the local network with Bonjour and probes them.
@MainActor
final class AirPortBrowser {
    private var browser: NWBrowser?
    private(set) var results: [String: BaseStation] = [:]
    var onChange: (([BaseStation]) -> Void)?
    var onError: ((String) -> Void)?

    func start() {
        stop()
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_airport._tcp", domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in self?.onError?("Bonjour browse failed: \(error.localizedDescription)") }
            }
            if case .waiting(let error) = state {
                Task { @MainActor in self?.onError?("Waiting for local network access: \(error.localizedDescription)") }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] newResults, _ in
            Task { @MainActor in self?.update(newResults) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private func update(_ newResults: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        for result in newResults {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            seen.insert(name)
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata {
                // AirPort TXT records pack everything into one comma-separated entry.
                for (key, value) in record.dictionary {
                    if value.isEmpty, key.contains("=") { txt.merge(Self.parseCSV(key)) { $1 } }
                    else if key.contains(",") || value.contains(",") { txt.merge(Self.parseCSV("\(key)=\(value)")) { $1 } }
                    else { txt[key] = value }
                }
            }
            var station = results[name] ?? BaseStation(name: name, txt: [:])
            station.txt = txt
            station.lastSeen = Date()
            results[name] = station
        }
        for key in results.keys where !seen.contains(key) { results.removeValue(forKey: key) }
        onChange?(sorted)
    }

    var sorted: [BaseStation] { results.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    /// Resolve the IPv4 address by connecting to the AirPort admin port (5009), then ICMP ping it.
    func probeAll(pingCount: Int = 4) async {
        await withTaskGroup(of: BaseStation.self) { group in
            for station in results.values {
                group.addTask { await Self.probe(station, pingCount: pingCount) }
            }
            for await probed in group where results[probed.name] != nil {
                results[probed.name] = probed
            }
        }
        onChange?(sorted)
    }

    nonisolated static func probe(_ station: BaseStation, pingCount: Int) async -> BaseStation {
        var s = station
        let endpoint = NWEndpoint.service(name: station.name, type: "_airport._tcp", domain: "local.", interface: nil)
        let (ip, latency, error) = await connect(to: endpoint)
        s.ipAddress = ip ?? s.ipAddress
        s.adminPortLatencyMs = latency
        s.adminPortError = error
        if let target = s.ipAddress {
            s.ping = await Pinger.ping(target, count: pingCount)
        }
        return s
    }

    nonisolated static func connect(to endpoint: NWEndpoint, timeout: TimeInterval = 4) async -> (String?, Double?, String?) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: params)
        let start = Date()
        return await withCheckedContinuation { cont in
            let once = OnceFlag()
            @Sendable func finish(_ value: (String?, Double?, String?)) {
                guard once.claim() else { return }
                connection.cancel()
                cont.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var ip: String?
                    if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                        switch host {
                        case .ipv4(let a): ip = "\(a)"
                        case .ipv6(let a): ip = "\(a)"
                        case .name(let n, _): ip = n
                        @unknown default: break
                        }
                        ip = ip?.components(separatedBy: "%").first
                    }
                    finish((ip, Date().timeIntervalSince(start) * 1000, nil))
                case .failed(let e): finish((nil, nil, e.localizedDescription))
                case .waiting(let e): finish((nil, nil, e.localizedDescription))
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish((nil, nil, "Timed out")) }
        }
    }

    nonisolated static func parseCSV(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
