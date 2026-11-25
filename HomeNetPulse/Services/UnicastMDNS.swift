import Foundation
import Darwin

/// Minimal unicast mDNS client: asks a device directly (UDP to its port 5353) for its
/// host name and advertised services. Unlike the system Bonjour API, this isn't limited
/// to the service types declared in Info.plist.
enum UnicastMDNS {
    struct Answer: Sendable {
        var hostName: String?
        var serviceTypes: [String] = []          // e.g. "_airplay._tcp"
        var instances: [String: [String]] = [:]  // type → instance names
    }

    /// Service types whose instance names make good device labels, best first.
    static let namingTypes = ["_companion-link._tcp", "_airplay._tcp", "_raop._tcp", "_hap._tcp", "_sonos._tcp",
                              "_ipp._tcp", "_printer._tcp", "_smb._tcp", "_spotify-connect._tcp", "_googlecast._tcp",
                              "_airport._tcp", "_matter._tcp", "_http._tcp"]

    static func query(_ ip: String, timeout: TimeInterval = 1.2) async -> Answer? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: queryBlocking(ip, timeout: timeout))
            }
        }
    }

    private static func queryBlocking(_ ip: String, timeout: TimeInterval) -> Answer? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let reverse = parts.reversed().joined(separator: ".") + ".in-addr.arpa"
        // 1) host name + list of service types
        guard let first = exchange(ip, questions: [reverse, "_services._dns-sd._udp.local"], timeout: timeout) else { return nil }
        var answer = Answer()
        for (owner, target) in first {
            if owner.lowercased() == reverse { answer.hostName = target }
            if owner.lowercased() == "_services._dns-sd._udp.local" {
                let t = target.replacingOccurrences(of: ".local", with: "")
                if !answer.serviceTypes.contains(t) { answer.serviceTypes.append(t) }
            }
        }
        // 2) instance names for the useful types it offers
        let wanted = namingTypes.filter { answer.serviceTypes.contains($0) }
        if !wanted.isEmpty, let second = exchange(ip, questions: wanted.map { "\($0).local" }, timeout: timeout) {
            for (owner, target) in second {
                let type = owner.replacingOccurrences(of: ".local", with: "")
                guard wanted.contains(type) else { continue }
                // "Office TV._airplay._tcp.local" → "Office TV"
                let suffix = "." + owner
                let instance = target.hasSuffix(suffix) ? String(target.dropLast(suffix.count)) : target
                answer.instances[type, default: []].append(instance)
            }
        }
        return answer
    }

    /// Sends one query with several PTR questions and returns all PTR records in the reply.
    private static func exchange(_ ip: String, questions: [String], timeout: TimeInterval) -> [(String, String)]? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(5353).bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }

        let id = UInt16.random(in: 1...UInt16.max)
        var packet: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0, 0,
                               0, UInt8(questions.count), 0, 0, 0, 0, 0, 0]
        for q in questions {
            for label in q.split(separator: ".") {
                let bytes = Array(label.utf8)
                packet.append(UInt8(bytes.count)); packet += bytes
            }
            packet += [0, 0, 12, 0x80, 1]   // root, type PTR, class IN with unicast-response bit
        }
        let sent = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 9000)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&pfd, 1, ms) > 0 else { return nil }
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n >= 12 else { continue }
            let msg = Array(buffer[0..<n])
            guard UInt16(msg[0]) << 8 | UInt16(msg[1]) == id || (msg[0] == 0 && msg[1] == 0) else { continue }
            return parsePTRs(msg)
        }
        return nil
    }

    static func parsePTRs(_ msg: [UInt8]) -> [(String, String)] {
        func u16(_ i: Int) -> Int { i + 1 < msg.count ? Int(msg[i]) << 8 | Int(msg[i + 1]) : 0 }
        let qd = u16(4), an = u16(6), ns = u16(8), ar = u16(10)
        var i = 12
        for _ in 0..<qd {
            guard let (_, next) = readName(msg, at: i) else { return [] }
            i = next + 4
        }
        var out: [(String, String)] = []
        for _ in 0..<(an + ns + ar) {
            guard let (owner, next) = readName(msg, at: i), next + 10 <= msg.count else { break }
            let type = u16(next), rdlen = u16(next + 8)
            let rdata = next + 10
            if type == 12, let (target, _) = readName(msg, at: rdata) { out.append((owner, target)) }
            i = rdata + rdlen
        }
        return out
    }

    /// Reads a (possibly compressed) DNS name; returns it without the trailing dot.
    static func readName(_ msg: [UInt8], at start: Int) -> (String, Int)? {
        var labels: [String] = []
        var i = start, end: Int?, jumps = 0
        while i < msg.count {
            let len = Int(msg[i])
            if len == 0 { if end == nil { end = i + 1 }; break }
            if len & 0xC0 == 0xC0 {
                guard i + 1 < msg.count, jumps < 16 else { return nil }
                if end == nil { end = i + 2 }
                i = (len & 0x3F) << 8 | Int(msg[i + 1]); jumps += 1
                continue
            }
            guard i + 1 + len <= msg.count else { return nil }
            labels.append(String(decoding: msg[(i + 1)...(i + len)], as: UTF8.self))
            i += 1 + len
        }
        guard let end else { return nil }
        return (labels.joined(separator: "."), end)
    }
}
