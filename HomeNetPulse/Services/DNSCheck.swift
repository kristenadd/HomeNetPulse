import Foundation
import Darwin

/// A DNS server to test, e.g. the router or the ISP's resolver.
struct DNSServer: Hashable, Sendable, Identifiable {
    var id: String { ip }
    var label: String
    var ip: String
}

/// One hostname looked up against one server.
struct DNSLookup: Sendable, Equatable, Identifiable {
    var id: String { "\(server)|\(host)" }
    var host: String
    var server: String
    var addresses: [String] = []
    var ms: Double?
    var error: String?
    var ok: Bool { error == nil && !addresses.isEmpty }
}

/// All lookups against one server.
struct DNSServerResult: Sendable, Equatable, Identifiable {
    var id: String { server.ip }
    var server: DNSServer
    var lookups: [DNSLookup]

    var okCount: Int { lookups.filter(\.ok).count }
    var avgMs: Double? {
        let t = lookups.filter(\.ok).compactMap(\.ms)
        return t.isEmpty ? nil : t.reduce(0, +) / Double(t.count)
    }
    var health: Health {
        if lookups.isEmpty { return .unknown }
        if okCount == 0 { return .down }
        if okCount < lookups.count || (avgMs ?? 0) > 300 { return .degraded }
        return .good
    }
    var summary: String {
        guard !lookups.isEmpty else { return "not tested" }
        if okCount == 0 { return lookups.first?.error ?? "no answers" }
        let ms = avgMs.map { $0 < 10 ? String(format: "%.1f ms", $0) : String(format: "%.0f ms", $0) } ?? ""
        return okCount == lookups.count ? ms : "\(okCount)/\(lookups.count) · \(ms)"
    }
}

/// Sends plain DNS queries (UDP port 53) straight to a server, bypassing the OS cache,
/// so a broken resolver shows up even while cached names still work.
enum DNSQuery {
    static func lookup(_ host: String, server: String, timeout: TimeInterval = 2.5) async -> DNSLookup {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: lookupBlocking(host, server: server, timeout: timeout))
            }
        }
    }

    static func check(_ hosts: [String], against server: DNSServer) async -> DNSServerResult {
        let lookups = await withTaskGroup(of: DNSLookup.self) { group in
            for h in hosts { group.addTask { await lookup(h, server: server.ip) } }
            var out: [DNSLookup] = []
            for await r in group { out.append(r) }
            return out
        }
        let order = Dictionary(uniqueKeysWithValues: hosts.enumerated().map { ($1, $0) })
        return DNSServerResult(server: server, lookups: lookups.sorted { (order[$0.host] ?? 0) < (order[$1.host] ?? 0) })
    }

    static func makeQuery(id: UInt16, host: String) -> [UInt8] {
        var p: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00,   // recursion desired
                          0, 1, 0, 0, 0, 0, 0, 0]
        for label in host.split(separator: ".") {
            let b = Array(label.utf8)
            p.append(UInt8(min(b.count, 63))); p += b.prefix(63)
        }
        p += [0, 0, 1, 0, 1]   // root, type A, class IN
        return p
    }

    /// Returns (rcode, IPv4 answers) or nil if the message is malformed.
    static func parseResponse(_ msg: [UInt8], id: UInt16) -> (rcode: Int, addresses: [String])? {
        guard msg.count >= 12, UInt16(msg[0]) << 8 | UInt16(msg[1]) == id else { return nil }
        func u16(_ i: Int) -> Int { i + 1 < msg.count ? Int(msg[i]) << 8 | Int(msg[i + 1]) : 0 }
        let rcode = Int(msg[3] & 0x0F)
        let qd = u16(4), an = u16(6)
        var i = 12
        for _ in 0..<qd {
            guard let (_, next) = UnicastMDNS.readName(msg, at: i) else { return nil }
            i = next + 4
        }
        var addrs: [String] = []
        for _ in 0..<an {
            guard let (_, next) = UnicastMDNS.readName(msg, at: i), next + 10 <= msg.count else { break }
            let type = u16(next), rdlen = u16(next + 8), rdata = next + 10
            if type == 1, rdlen == 4, rdata + 4 <= msg.count {
                addrs.append(msg[rdata..<rdata + 4].map(String.init).joined(separator: "."))
            }
            i = rdata + rdlen
        }
        return (rcode, addrs)
    }

    private static func lookupBlocking(_ host: String, server: String, timeout: TimeInterval) -> DNSLookup {
        var result = DNSLookup(host: host, server: server)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { result.error = "socket failed"; return result }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET, server, &addr.sin_addr) == 1 else { result.error = "bad server address"; return result }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { result.error = "unreachable"; return result }

        let id = UInt16.random(in: 1...UInt16.max)
        let query = makeQuery(id: id, host: host)
        let start = DispatchTime.now()
        guard query.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) > 0 else {
            result.error = "send failed"; return result
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&pfd, 1, ms) > 0 else { break }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 { result.error = errno == ECONNREFUSED ? "refused" : "no response"; return result }
            guard let parsed = parseResponse(Array(buffer[0..<n]), id: id) else { continue }
            result.ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            switch parsed.rcode {
            case 0:
                result.addresses = parsed.addresses
                if parsed.addresses.isEmpty { result.error = "no address" }
            case 2: result.error = "server failure"
            case 3: result.error = "name not found"
            case 5: result.error = "refused"
            default: result.error = "error \(parsed.rcode)"
            }
            return result
        }
        result.error = "timed out"
        return result
    }
}

/// The DNS servers this device is configured to use (system settings, DHCP, VPN…), IPv4 only.
enum SystemDNS {
    static func servers() -> [String] {
        let state = UnsafeMutablePointer<__res_9_state>.allocate(capacity: 1)
        state.initialize(to: __res_9_state())
        defer { res_9_ndestroy(state); state.deinitialize(count: 1); state.deallocate() }
        guard res_9_ninit(state) == 0 else { return [] }
        var list = [res_9_sockaddr_union](repeating: res_9_sockaddr_union(), count: 8)
        let n = Int(res_9_getservers(state, &list, 8))
        var out: [String] = []
        for i in 0..<max(0, n) {
            var s = list[i]
            let family = withUnsafeBytes(of: &s) { $0[1] }
            guard Int32(family) == AF_INET else { continue }
            let addr = withUnsafeBytes(of: &s) { $0.loadUnaligned(fromByteOffset: 4, as: in_addr.self) }
            let ip = Pinger.string(from: addr)
            if !out.contains(ip) { out.append(ip) }
        }
        return out
    }
}
