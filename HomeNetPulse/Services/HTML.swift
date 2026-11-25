import Foundation

/// Minimal, regex-based helpers for the AT&T / Arris gateway's server-rendered pages.
enum HTML {
    static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&lt;": "<", "&gt;": ">", "&#39;": "'", "&apos;": "'"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    static func stripTags(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(noTags)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ pattern: String, in s: String, options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        matches(pattern, in: s).first.flatMap { $0.count > 1 ? $0[1] : nil }
    }

    static func nonce(in s: String) -> String? {
        firstMatch(#"name="nonce"\s+value="([^"]*)""#, in: s)
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        firstMatch(#"\b\#(name)\s*=\s*"([^"]*)""#, in: tag)
    }

    /// All `<input type="submit">` buttons as (name, value).
    static func submitButtons(in s: String) -> [(name: String, value: String)] {
        matches(#"<input\b[^>]*>"#, in: s).compactMap { m in
            let tag = m[0]
            guard attribute("type", in: tag)?.lowercased() == "submit",
                  let name = attribute("name", in: tag) else { return nil }
            return (name, attribute("value", in: tag) ?? name)
        }
    }

    static func textarea(named name: String, in s: String) -> String? {
        firstMatch(#"<textarea[^>]*name="\#(name)"[^>]*>(.*?)</textarea>"#, in: s).map(decodeEntities)
    }

    static func title(in s: String) -> String? {
        firstMatch(#"<h1[^>]*>(.*?)</h1>"#, in: s).map(stripTags) ?? firstMatch(#"<title>(.*?)</title>"#, in: s).map(stripTags)
    }

    static func isLoginPage(_ s: String) -> Bool {
        s.range(of: #"action="/cgi-bin/login.ha""#, options: .regularExpression) != nil
            || s.contains("Access Code Required")
    }
}

/// A labeled group of key/value rows from a gateway status page.
struct StatSection: Identifiable, Sendable, Equatable {
    var id: String { title }
    var title: String
    var rows: [StatRow]
}

struct StatRow: Identifiable, Sendable, Equatable {
    var id: String { key + "|" + value }
    var key: String
    var value: String
}

enum BroadbandParser {
    /// Splits the page into `<h2>` sections and collects `<th>` / `<td>` pairs in each.
    static func parse(_ html: String) -> [StatSection] {
        let body: String = {
            guard let start = html.range(of: "<form", options: .caseInsensitive),
                  let end = html.range(of: "</form>", options: [.caseInsensitive, .backwards]) else { return html }
            return String(html[start.lowerBound..<end.upperBound])
        }()
        let parts = HTML.matches(#"<h2[^>]*>(.*?)</h2>"#, in: body)
        var sections: [StatSection] = []
        var cursor = body.startIndex
        var currentTitle = "Summary"
        for part in parts + [["", ""]] {
            let endIdx = part[0].isEmpty ? body.endIndex : (body.range(of: part[0], range: cursor..<body.endIndex)?.lowerBound ?? body.endIndex)
            let chunk = String(body[cursor..<endIdx])
            let rows = pairs(in: chunk)
            if !rows.isEmpty { sections.append(StatSection(title: currentTitle, rows: rows)) }
            if part[0].isEmpty { break }
            cursor = body.range(of: part[0], range: cursor..<body.endIndex)?.upperBound ?? body.endIndex
            currentTitle = HTML.stripTags(part[1])
        }
        return sections
    }

    static func pairs(in chunk: String) -> [StatRow] {
        HTML.matches(#"<th[^>]*>(.*?)</th>\s*<td[^>]*>(.*?)</td>"#, in: chunk).compactMap { m in
            let key = HTML.stripTags(m[1])
            guard !key.isEmpty else { return nil }
            return StatRow(key: key, value: HTML.stripTags(m[2]))
        }
    }
}

/// Key facts extracted from the broadband statistics page.
struct BroadbandSummary: Sendable, Equatable {
    var sections: [StatSection] = []
    var wanIPv4: String?
    var gatewayIPv4: String?
    var primaryDNS: String?
    var secondaryDNS: String?
    var wanMAC: String?
    var lineState: String?
    var speedMbps: String?
    var ponStatus: String?
    var receiveErrors: String?
    var receiveDrops: String?

    init(sections: [StatSection]) {
        self.sections = sections
        // IPv4 values live in the first ("Primary Broadband") section; IPv6 has its own DNS rows.
        let primary = sections.first { $0.title.localizedCaseInsensitiveContains("Primary") } ?? sections.first
        func value(_ key: String, in section: StatSection?) -> String? {
            section?.rows.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value.nilIfEmpty
        }
        func anywhere(_ key: String) -> String? {
            for s in sections { if let v = value(key, in: s) { return v } }
            return nil
        }
        wanIPv4 = value("Broadband IPv4 Address", in: primary) ?? anywhere("Broadband IPv4 Address")
        gatewayIPv4 = value("Gateway IPv4 Address", in: primary) ?? anywhere("Gateway IPv4 Address")
        primaryDNS = value("Primary DNS", in: primary)
        secondaryDNS = value("Secondary DNS", in: primary)
        wanMAC = value("MAC Address", in: primary).map(BaseStation.normalizeMAC)
        lineState = anywhere("Line State") ?? anywhere("Broadband Connection")
        speedMbps = anywhere("Current Speed (Mbps)")
        ponStatus = anywhere("PON Link Status")
        let ipv4Stats = sections.first { $0.title.localizedCaseInsensitiveContains("IPv4 Statistics") }
        receiveErrors = value("Receive Errors", in: ipv4Stats)
        receiveDrops = value("Receive Drops", in: ipv4Stats)
    }
}

extension BroadbandSummary {
    /// GPON ONU activation state (ITU-T G.984.3), e.g. "O5".
    var ponStateCode: String? { ponStatus.flatMap { HTML.firstMatch(#"\((O[1-7])\)"#, in: $0) } }

    var ponFriendly: String? {
        guard let code = ponStateCode else { return ponStatus }
        let name: String = switch code {
        case "O1": "Initializing"
        case "O2": "Standby"
        case "O3": "Identifying"
        case "O4": "Ranging"
        case "O5": "Connected"
        case "O6": "Signal lost"
        case "O7": "Disabled by ISP"
        default: "Unknown"
        }
        return "\(name) (\(code))"
    }

    var ponExplanation: String? {
        switch ponStateCode {
        case "O1": "The fiber terminal just powered on and is starting up."
        case "O2": "The terminal hears the ISP's equipment and is waiting to register."
        case "O3": "The terminal is sending its serial number to the ISP."
        case "O4": "The ISP is measuring the fiber distance and timing."
        case "O5": "Fully registered with the ISP and carrying traffic. This is the healthy state."
        case "O6": "Intermittent loss of downstream signal. Check the fiber cable and connectors."
        case "O7": "The ISP has stopped this terminal. Contact the ISP."
        default: nil
        }
    }

    var ponHealthy: Bool? { ponStateCode.map { $0 == "O5" } }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Parses busybox-style ping output from the gateway's diag page.
enum DiagPingParser {
    static func parse(_ output: String, host: String) -> PingResult {
        var r = PingResult(host: host, resolvedAddress: nil, sent: 0, received: 0, rttsMs: [])
        r.resolvedAddress = HTML.firstMatch(#"PING [^ ]+ \(([^)]+)\)"#, in: output)
        r.rttsMs = HTML.matches(#"time=([0-9.]+) ?ms"#, in: output).compactMap { Double($0[1]) }
        if let m = HTML.matches(#"(\d+) packets transmitted, (\d+) (?:packets )?received"#, in: output).first {
            r.sent = Int(m[1]) ?? 0
            r.received = Int(m[2]) ?? 0
        } else {
            r.sent = max(r.rttsMs.count, 1)
            r.received = r.rttsMs.count
        }
        if r.received == 0 { r.error = output.isEmpty ? "No output from gateway" : "No replies" }
        return r
    }
}
