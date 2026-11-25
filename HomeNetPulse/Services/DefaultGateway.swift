import Foundation
import Darwin

/// Finds this device's IPv4 default gateway, used to work out which AirPort is the main router.
enum DefaultGateway {
    static func ipv4() -> String? {
        #if os(macOS)
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var len = 0
        guard sysctl(&mib, u_int(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, u_int(mib.count), &buf, &len, nil, 0) == 0 else { return nil }
        return buf.withUnsafeBytes { raw -> String? in
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= len {
                let rtm = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                guard rtm.rtm_msglen > 0 else { break }
                var sa = offset + MemoryLayout<rt_msghdr>.size
                var dst: UInt32?
                var gw: UInt32?
                for i in 0..<Int(RTAX_MAX) where rtm.rtm_addrs & (1 << i) != 0 {
                    let saLen = Int(raw[sa])
                    let family = raw[sa + 1]
                    if Int32(family) == AF_INET || saLen == 0 {
                        let addr: UInt32 = saLen >= 8 ? raw.loadUnaligned(fromByteOffset: sa + 4, as: UInt32.self) : 0
                        if i == Int(RTAX_DST) { dst = addr }
                        if i == Int(RTAX_GATEWAY) { gw = addr }
                    }
                    sa += saLen == 0 ? 4 : (saLen + 3) & ~3
                }
                if dst == 0, let gw, gw != 0 {
                    return Pinger.string(from: in_addr(s_addr: gw))
                }
                offset += Int(rtm.rtm_msglen)
            }
            return nil
        }
        #else
        return nil   // routing sysctls aren't available on iOS; fall back to heuristics.
        #endif
    }
}
