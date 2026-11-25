import Foundation
import Darwin
import Network

/// A device seen on the local network.
struct LANDevice: Identifiable, Sendable, Equatable {
    var id: String { ip }
    var ip: String
    var mac: String?
    var hostName: String?
    /// Friendly kinds from Bonjour, e.g. "AirPlay", "HomeKit", "Printer".
    var services: [String] = []
    var latencyMs: Double?
    var lastSeen = Date()

    /// Phones and computers often use a randomized ("private") Wi-Fi address.
    var isPrivateMAC: Bool {
        guard let first = mac?.split(separator: ":").first, let b = UInt8(first, radix: 16) else { return false }
        return b & 0x02 != 0
    }

    /// From the MAC prefix; nil for private addresses.
    var manufacturer: String? { Manufacturers.name(for: mac) }

    var displayName: String { hostName ?? ip }

    var sortKey: UInt32 {
        var a = in_addr()
        return inet_pton(AF_INET, ip, &a) == 1 ? UInt32(bigEndian: a.s_addr) : .max
    }
}

/// This device's address on the LAN.
struct LocalInterface: Sendable, Equatable {
    var name: String
    var ip: String
    var netmask: String
    var mac: String?
    var hosts: [String]

    var cidr: String {
        var m = in_addr()
        inet_pton(AF_INET, netmask, &m)
        let bits = UInt32(bigEndian: m.s_addr).nonzeroBitCount
        var n = in_addr()
        inet_pton(AF_INET, ip, &n)
        let net = UInt32(bigEndian: n.s_addr) & UInt32(bigEndian: m.s_addr)
        return "\(Pinger.string(from: in_addr(s_addr: net.bigEndian)))/\(bits)"
    }
}

enum LANScanner {
    /// Primary IPv4 interface (prefers en0) and the host addresses on its subnet (capped at a /22).
    static func localInterface() -> LocalInterface? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(name: String, ip: UInt32, mask: UInt32)] = []
        var macs: [String: String] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            if Int32(sa.pointee.sa_family) == AF_INET, let nm = ifa.ifa_netmask {
                let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                // Skip link-local 169.254/16
                if ip >> 16 != 0xA9FE { candidates.append((name, ip, mask)) }
            } else if Int32(sa.pointee.sa_family) == AF_LINK {
                let raw = UnsafeRawPointer(sa)
                let nlen = Int(raw.load(fromByteOffset: 5, as: UInt8.self))
                let alen = Int(raw.load(fromByteOffset: 6, as: UInt8.self))
                if alen == 6 {
                    let bytes = (0..<6).map { raw.load(fromByteOffset: 8 + nlen + $0, as: UInt8.self) }
                    let mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                    // The OS hides the real address from apps as 02:00:00:00:00:00.
                    if mac != "02:00:00:00:00:00" { macs[name] = mac }
                }
            }
        }
        // Only Wi-Fi / Ethernet (en*). Never cellular (pdp_ip*) or VPN (utun*, ipsec*) interfaces:
        // they aren't the home network, and cellular's single-address netmask has no hosts to sweep.
        guard let c = candidates.first(where: { $0.name == "en0" }) ?? candidates.first(where: { $0.name.hasPrefix("en") })
        else { return nil }

        var mask = c.mask
        if mask.nonzeroBitCount < 22 { mask = 0xFFFF_FC00 }   // don't sweep huge networks
        let net = c.ip & mask
        let broadcast = net | ~mask
        guard broadcast > net &+ 1 else { return nil }          // /31 and /32 have no host range
        let hosts = (net + 1 ..< broadcast).map { Pinger.string(from: in_addr(s_addr: $0.bigEndian)) }
        return LocalInterface(name: c.name, ip: Pinger.string(from: in_addr(s_addr: c.ip.bigEndian)),
                              netmask: Pinger.string(from: in_addr(s_addr: c.mask.bigEndian)),
                              mac: macs[c.name], hosts: hosts)
    }

    /// Ping every address (which also fills the ARP cache), then merge ARP entries and look up names.
    static func scan(_ iface: LocalInterface, progress: (@Sendable (Double) -> Void)? = nil) async -> [LANDevice] {
        Manufacturers.preload()
        var found: [String: LANDevice] = [:]
        let hosts = iface.hosts
        let batch = 48
        var done = 0
        for start in stride(from: 0, to: hosts.count, by: batch) {
            let slice = hosts[start ..< min(start + batch, hosts.count)]
            await withTaskGroup(of: PingResult.self) { group in
                for h in slice { group.addTask { await Pinger.ping(h, count: 1, timeout: 0.8) } }
                for await r in group where r.received > 0 {
                    found[r.host] = LANDevice(ip: r.host, latencyMs: r.avgMs)
                }
            }
            done += slice.count
            progress?(Double(done) / Double(hosts.count))
        }

        // Devices that ignore ping still answer ARP; the kernel table has them now (macOS).
        let hostSet = Set(hosts)
        var arp = arpViaLaunchd()
        if arp.isEmpty { arp = arpFromTool() }
        if arp.isEmpty { arp = arpTable() }
        for (ip, mac) in arp where hostSet.contains(ip) {
            found[ip, default: LANDevice(ip: ip)].mac = mac
        }
        // Ourselves
        found[iface.ip, default: LANDevice(ip: iface.ip, latencyMs: 0)].mac = iface.mac

        // Names: ask each device directly over unicast mDNS (friendly names like "Kristen's iPad"),
        // then system Bonjour (only declared types work in the sandbox), then reverse DNS.
        let direct = await withTaskGroup(of: (String, UnicastMDNS.Answer?).self) { group in
            for ip in found.keys {
                group.addTask {
                    // Retry once with a longer wait for slow (sleepy) responders.
                    if let a = await UnicastMDNS.query(ip) { return (ip, a) }
                    return (ip, await UnicastMDNS.query(ip, timeout: 2.5))
                }
            }
            var out: [String: UnicastMDNS.Answer] = [:]
            for await (ip, a) in group { if let a { out[ip] = a } }
            return out
        }
        for (ip, a) in direct {
            if let name = BonjourNamer.bestName(from: a) { found[ip]?.hostName = name }
            found[ip]?.services = BonjourNamer.kinds(for: a.serviceTypes)
        }
        let bonjour = await BonjourNamer.discover(hosts: hostSet)
        for (ip, info) in bonjour {
            if found[ip]?.hostName == nil { found[ip, default: LANDevice(ip: ip)].hostName = info.name }
            for k in info.kinds where !(found[ip]?.services.contains(k) ?? false) { found[ip]?.services.append(k) }
        }
        let unnamed = found.values.filter { $0.hostName == nil }.map(\.ip)
        let names = await withTaskGroup(of: (String, String?).self) { group in
            for ip in unnamed { group.addTask { (ip, await reverseName(ip)) } }
            var out: [String: String] = [:]
            for await (ip, name) in group { if let name { out[ip] = name } }
            return out
        }
        for (ip, name) in names { found[ip]?.hostName = name }
        return found.values.sorted { $0.sortKey < $1.sortKey }
    }

    static func reverseName(_ ip: String, timeout: TimeInterval = 2.5) async -> String? {
        await withCheckedContinuation { cont in
            let once = OnceFlag()
            DispatchQueue.global().async {
                var sin = sockaddr_in()
                sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                sin.sin_family = sa_family_t(AF_INET)
                inet_pton(AF_INET, ip, &sin.sin_addr)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let rc = withUnsafePointer(to: &sin) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                    }
                }
                var name: String?
                if rc == 0 {
                    var n = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    for suffix in [".local.", ".local", "."] where n.hasSuffix(suffix) { n.removeLast(suffix.count) }
                    if !n.isEmpty && n != ip { name = n }
                }
                if once.claim() { cont.resume(returning: name) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// IPv4 → MAC by running `/usr/sbin/arp -an` (macOS, unsandboxed). The kernel only hands the
    /// ARP table to privileged tools, so this is the reliable way for an app to read it.
    static func arpFromTool() -> [String: String] {
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-an"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseArp(String(decoding: data, as: UTF8.self))
        #else
        return [:]
        #endif
    }

    /// macOS hides LAN neighbour (ARP) entries from processes an app launches directly, but not from
    /// a job launchd starts on the app's behalf. Run `arp -an` as a one-off user agent and read its output.
    static func arpViaLaunchd(timeout: TimeInterval = 4) -> [String: String] {
        #if os(macOS)
        let fm = FileManager.default
        let id = UUID().uuidString
        let label = "\(AppInfo.bundleID).arp.\(id)"
        let dir = fm.temporaryDirectory
        let outURL = dir.appendingPathComponent("hnp-arp-\(id).txt")
        let plistURL = dir.appendingPathComponent("hnp-arp-\(id).plist")
        defer { try? fm.removeItem(at: outURL); try? fm.removeItem(at: plistURL) }

        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/sbin/arp", "-an"],
            "StandardOutPath": outURL.path,
            "RunAtLoad": true,
            "KeepAlive": false,
            "LaunchOnlyOnce": true,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
              (try? data.write(to: plistURL)) != nil else { return [:] }

        let domain = "gui/\(getuid())"
        func launchctl(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        launchctl(["bootstrap", domain, plistURL.path])
        defer { launchctl(["bootout", "\(domain)/\(label)"]) }

        // Wait for the output to appear and stop growing.
        let deadline = Date().addingTimeInterval(timeout)
        var lastSize = -1
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            let size = (try? fm.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
            if size > 0 && size == lastSize { break }
            lastSize = size
        }
        let text = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        return parseArp(text)
        #else
        return [:]
        #endif
    }

    /// Parses lines like `? (192.168.1.1) at 88:1f:a1:28:58:6b on en0 ifscope [ethernet]`.
    /// arp drops leading zeros (`0:e:c6:…`), so octets are re-padded.
    static func parseArp(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let ip = HTML.firstMatch(#"\(([0-9.]+)\)"#, in: String(line)),
                  let raw = HTML.firstMatch(#" at ([0-9a-fA-F:]+) "#, in: String(line)) else { continue }
            let octets = raw.split(separator: ":")
            guard octets.count == 6 else { continue }
            let mac = octets.map { $0.count == 1 ? "0" + $0.lowercased() : $0.lowercased() }.joined(separator: ":")
            if mac != "ff:ff:ff:ff:ff:ff" { out[ip] = mac }
        }
        return out
    }

    /// IPv4 → MAC from the kernel ARP cache via sysctl (works only for privileged processes).
    static func arpTable() -> [String: String] {
        #if os(macOS)
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, 0x400 /* RTF_LLINFO */]
        var len = 0
        guard sysctl(&mib, u_int(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, u_int(mib.count), &buf, &len, nil, 0) == 0 else { return [:] }
        var out: [String: String] = [:]
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= len {
                let rtm = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                guard rtm.rtm_msglen > 0 else { break }
                let sa1 = offset + MemoryLayout<rt_msghdr>.size
                let len1 = Int(raw[sa1])
                let sa2 = sa1 + (len1 == 0 ? 4 : (len1 + 3) & ~3)
                if sa2 + 8 <= offset + Int(rtm.rtm_msglen), Int32(raw[sa1 + 1]) == AF_INET {
                    let addr = raw.loadUnaligned(fromByteOffset: sa1 + 4, as: UInt32.self)
                    let nlen = Int(raw[sa2 + 5]), alen = Int(raw[sa2 + 6])
                    if alen == 6 {
                        let mac = (0..<6).map { String(format: "%02x", raw[sa2 + 8 + nlen + $0]) }.joined(separator: ":")
                        if mac != "ff:ff:ff:ff:ff:ff" { out[Pinger.string(from: in_addr(s_addr: addr))] = mac }
                    }
                }
                offset += Int(rtm.rtm_msglen)
            }
        }
        return out
        #else
        return [:]
        #endif
    }
}

/// Finds friendly device names by browsing common Bonjour services and resolving them to IPv4 addresses.
enum BonjourNamer {
    /// Service type → (friendly kind, name priority; lower wins).
    static let serviceTypes: [(type: String, kind: String, priority: Int)] = [
        ("_companion-link._tcp", "Apple device", 0),
        ("_airplay._tcp", "AirPlay", 1),
        ("_raop._tcp", "AirPlay audio", 2),
        ("_googlecast._tcp", "Chromecast", 1),
        ("_hap._tcp", "HomeKit", 1),
        ("_sonos._tcp", "Sonos", 1),
        ("_spotify-connect._tcp", "Spotify Connect", 3),
        ("_ipp._tcp", "Printer", 1),
        ("_printer._tcp", "Printer", 2),
        ("_smb._tcp", "File sharing", 2),
        ("_ssh._tcp", "SSH", 4),
        ("_http._tcp", "Web", 5),
        ("_matter._tcp", "Matter", 3),
        ("_amzn-wplay._tcp", "Amazon", 3),
        ("_airport._tcp", "AirPort", 0),
    ]

    struct Info: Sendable { var name: String; var kinds: [String]; var priority: Int }

    /// Friendly kinds for advertised service types, in priority order, deduplicated.
    static func kinds(for types: [String]) -> [String] {
        var out: [String] = []
        for t in serviceTypes where types.contains(t.type) && !out.contains(t.kind) { out.append(t.kind) }
        return out
    }

    /// Best label from a unicast mDNS answer: a service instance name, else the host name.
    static func bestName(from a: UnicastMDNS.Answer) -> String? {
        for type in UnicastMDNS.namingTypes {
            if let inst = a.instances[type]?.first {
                let clean = cleanName(inst)
                if !isOpaque(clean) && !clean.isEmpty { return clean }
            }
        }
        guard var host = a.hostName else { return nil }
        for suffix in [".local", "."] where host.hasSuffix(suffix) { host.removeLast(suffix.count) }
        // "Kristen-iPad-Mini" → "Kristen iPad Mini"
        if isOpaque(host) { return nil }
        host = cleanName(host.replacingOccurrences(of: "-", with: " "))
        return host.isEmpty ? nil : host
    }

    static func discover(hosts: Set<String>, browseFor seconds: Double = 3.5) async -> [String: Info] {
        // 1. Browse every type at once.
        let instances = await browse(seconds: seconds)
        // 2. Resolve each instance to an IPv4 address (UDP "connections" resolve without sending traffic).
        let resolved = await withTaskGroup(of: (String, String, String, Int)?.self) { group in
            for (endpoint, kind, prio) in instances {
                group.addTask {
                    guard case let .service(name, _, _, _) = endpoint,
                          let ip = await resolveIPv4(endpoint), hosts.contains(ip) else { return nil }
                    let clean = cleanName(name)
                    // Opaque IDs only name a device when nothing better is found.
                    return (ip, isOpaque(clean) ? "\(kind) device" : clean, kind, isOpaque(clean) ? 9 : prio)
                }
            }
            var out: [(String, String, String, Int)] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
        var byIP: [String: Info] = [:]
        for (ip, name, kind, prio) in resolved {
            var info = byIP[ip] ?? Info(name: name, kinds: [], priority: prio)
            if prio < info.priority { info.name = name; info.priority = prio }
            if !info.kinds.contains(kind) { info.kinds.append(kind) }
            byIP[ip] = info
        }
        return byIP
    }

    /// "AA1122BBCC@Living Room" (RAOP) → "Living Room"; drop typographic quirks.
    static func cleanName(_ name: String) -> String {
        var n = name
        if let at = n.firstIndex(of: "@") { n = String(n[n.index(after: at)...]) }
        // Chromecast-style "Model-<32 hex id>" → "Model"
        n = n.replacingOccurrences(of: "-[0-9a-fA-F]{32}$", with: "", options: .regularExpression)
        // "iRobot 381488D5B4AE…" / "hubv2 0d052a83…" → drop trailing hex IDs
        n = n.replacingOccurrences(of: "[ _-][0-9a-fA-F]{12,}$", with: "", options: .regularExpression)
        return n.trimmingCharacters(in: .whitespaces)
    }

    /// Names that are just hex identifiers (e.g. Matter) aren't useful labels.
    static func isOpaque(_ name: String) -> Bool {
        name.range(of: "^[0-9A-Fa-f-]{12,}$", options: .regularExpression) != nil
    }

    static func browse(seconds: Double) async -> [(NWEndpoint, String, Int)] {
        await withCheckedContinuation { cont in
            let queue = DispatchQueue(label: "bonjour-namer")
            let box = ResultBox()
            var browsers: [NWBrowser] = []
            for t in serviceTypes {
                let b = NWBrowser(for: .bonjour(type: t.type, domain: "local."), using: NWParameters())
                b.browseResultsChangedHandler = { newResults, _ in
                    for r in newResults { box.set("\(t.type)|\(r.endpoint)", (r.endpoint, t.kind, t.priority)) }
                }
                b.start(queue: queue)
                browsers.append(b)
            }
            queue.asyncAfter(deadline: .now() + seconds) { [browsers] in
                browsers.forEach { $0.cancel() }
                cont.resume(returning: box.values)
            }
        }
    }

    static func resolveIPv4(_ endpoint: NWEndpoint, timeout: TimeInterval = 3) async -> String? {
        let params = NWParameters.udp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: params)
        return await withCheckedContinuation { cont in
            let once = OnceFlag()
            @Sendable func finish(_ ip: String?) {
                guard once.claim() else { return }
                connection.cancel()
                cont.resume(returning: ip)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint, case let .ipv4(a) = host {
                        finish("\(a)".components(separatedBy: "%").first)
                    } else { finish(nil) }
                case .failed, .cancelled: finish(nil)
                case .waiting: finish(nil)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var dict: [String: (NWEndpoint, String, Int)] = [:]
    func set(_ k: String, _ v: (NWEndpoint, String, Int)) { lock.lock(); dict[k] = v; lock.unlock() }
    var values: [(NWEndpoint, String, Int)] { lock.lock(); defer { lock.unlock() }; return Array(dict.values) }
}
