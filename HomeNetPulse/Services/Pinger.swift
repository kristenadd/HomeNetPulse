import Foundation
import Darwin

/// Result of pinging a single host a few times.
struct PingResult: Sendable, Equatable {
    var host: String
    var resolvedAddress: String?
    var sent: Int
    var received: Int
    var rttsMs: [Double]
    var error: String?
    var timestamp = Date()

    var lossPercent: Double { sent == 0 ? 100 : Double(sent - received) / Double(sent) * 100 }
    var avgMs: Double? { rttsMs.isEmpty ? nil : rttsMs.reduce(0, +) / Double(rttsMs.count) }
    var minMs: Double? { rttsMs.min() }
    var maxMs: Double? { rttsMs.max() }
    var jitterMs: Double? {
        guard rttsMs.count > 1 else { return nil }
        let diffs = zip(rttsMs.dropFirst(), rttsMs).map { abs($0 - $1) }
        return diffs.reduce(0, +) / Double(diffs.count)
    }

    var health: Health {
        if received == 0 { return .down }
        if lossPercent > 20 || (avgMs ?? 0) > 150 { return .degraded }
        return .good
    }
}

enum Health: Int, Sendable, Comparable {
    case unknown, good, degraded, down
    static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
}

/// Unprivileged ICMP echo using a SOCK_DGRAM/IPPROTO_ICMP socket (works on macOS and iOS, sandboxed, no root).
enum Pinger {
    static func ping(_ host: String, count: Int = 4, timeout: TimeInterval = 1.0, interval: TimeInterval = 0.2) async -> PingResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: pingBlocking(host, count: count, timeout: timeout, interval: interval))
            }
        }
    }

    static func resolveIPv4(_ host: String) -> in_addr? {
        var addr = in_addr()
        if inet_pton(AF_INET, host, &addr) == 1 { return addr }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        return first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }

    static func string(from addr: in_addr) -> String {
        var a = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func pingBlocking(_ host: String, count: Int, timeout: TimeInterval, interval: TimeInterval) -> PingResult {
        var result = PingResult(host: host, resolvedAddress: nil, sent: 0, received: 0, rttsMs: [])
        guard let addr = resolveIPv4(host) else {
            result.error = "Could not resolve \(host)"
            return result
        }
        result.resolvedAddress = string(from: addr)

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else {
            result.error = "ICMP socket failed: \(String(cString: strerror(errno)))"
            return result
        }
        defer { close(fd) }

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_addr = addr

        let identifier = UInt16.random(in: 1...UInt16.max)
        // Random sequence base so concurrent pings (e.g. a LAN sweep) never match each other's replies.
        let seqBase = UInt16.random(in: 0...UInt16.max)
        for seq in 0..<count {
            let packet = makeEchoRequest(id: identifier, seq: seqBase &+ UInt16(seq))
            let start = DispatchTime.now()
            let sent = packet.withUnsafeBytes { buf in
                withUnsafePointer(to: &dest) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            result.sent += 1
            if sent < 0 {
                result.error = "Send failed: \(String(cString: strerror(errno)))"
                continue
            }
            if let rtt = awaitReply(fd: fd, from: addr, seq: seqBase &+ UInt16(seq), start: start, timeout: timeout) {
                result.received += 1
                result.rttsMs.append(rtt)
            }
            if seq < count - 1 { Thread.sleep(forTimeInterval: interval) }
        }
        if result.received > 0 { result.error = nil }
        return result
    }

    private static func awaitReply(fd: Int32, from expected: in_addr, seq: UInt16, start: DispatchTime, timeout: TimeInterval) -> Double? {
        let deadline = start.uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remainingMs = Int32((deadline - now) / 1_000_000)
            let r = poll(&pfd, 1, max(remainingMs, 1))
            if r <= 0 { if r < 0 && errno == EINTR { continue }; return nil }
            var src = sockaddr_in()
            var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &src) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &srcLen) }
            }
            guard n > 0 else { continue }
            // ICMP datagram sockets can see other sockets' echo replies: only accept our host's.
            guard src.sin_addr.s_addr == expected.s_addr else { continue }
            var offset = 0
            // Darwin delivers the IP header on ICMP datagram sockets.
            if buffer[0] >> 4 == 4 { offset = Int(buffer[0] & 0x0F) * 4 }
            guard n >= offset + 8 else { continue }
            let type = buffer[offset]

            let rseq = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
            // The kernel may rewrite the identifier on datagram sockets, so match on sequence.
            if type == 0 && rseq == seq {
                return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            }
        }
    }

    static func makeEchoRequest(id: UInt16, seq: UInt16) -> [UInt8] {
        var p: [UInt8] = [8, 0, 0, 0, UInt8(id >> 8), UInt8(id & 0xFF), UInt8(seq >> 8), UInt8(seq & 0xFF)]
        p += Array("HomeNetPulse-ping-payload-0123456789abcdef".utf8)
        let sum = checksum(p)
        p[2] = UInt8(sum >> 8); p[3] = UInt8(sum & 0xFF)
        return p
    }

    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count { sum += UInt32(data[i]) << 8 | UInt32(data[i + 1]); i += 2 }
        if i < data.count { sum += UInt32(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
