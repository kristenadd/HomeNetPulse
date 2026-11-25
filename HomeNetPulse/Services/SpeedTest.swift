import Foundation

/// One row of the gateway's speed test history (cgi-bin/speed.ha).
struct SpeedTestEntry: Sendable, Equatable, Identifiable {
    var id: String { "\(timeText)|\(direction)" }
    var timeText: String
    var time: Date?
    var direction: String          // "downstream" / "upstream"
    var mbps: Double?
    var overhead: String?
    var latencyMs: Double?
    var status: String

    var isDownload: Bool { direction.lowercased().hasPrefix("down") }
    var succeeded: Bool { status.lowercased() == "success" }
}

/// A downstream + upstream pair run together.
struct SpeedTestRun: Sendable, Equatable, Identifiable {
    var id: String { (download?.id ?? "") + (upload?.id ?? "") }
    var download: SpeedTestEntry?
    var upload: SpeedTestEntry?
    var time: Date? { [download?.time, upload?.time].compactMap { $0 }.max() }
    var timeText: String { download?.timeText ?? upload?.timeText ?? "" }
    var latencyMs: Double? {
        let l = [download?.latencyMs, upload?.latencyMs].compactMap { $0 }
        return l.isEmpty ? nil : l.reduce(0, +) / Double(l.count)
    }
    var succeeded: Bool { (download?.succeeded ?? true) && (upload?.succeeded ?? true) }
}

enum SpeedTestParser {
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return f
    }()

    static func parse(_ html: String) -> [SpeedTestEntry] {
        guard let table = HTML.firstMatch(#"(<table[^>]*Speed Test[^>]*>.*?</table>)"#, in: html)
                ?? HTML.firstMatch(#"(<table[^>]*grid[^>]*>.*?</table>)"#, in: html) else { return [] }
        let body = HTML.firstMatch(#"<tbody[^>]*>(.*?)</tbody>"#, in: table) ?? table
        return HTML.matches(#"<tr[^>]*>(.*?)</tr>"#, in: body).compactMap { row in
            let cells = HTML.matches(#"<td[^>]*>(.*?)</td>"#, in: row[1]).map { HTML.stripTags($0[1]) }
            guard cells.count >= 6, !cells[0].isEmpty else { return nil }
            return SpeedTestEntry(timeText: cells[0], time: dateFormatter.date(from: cells[0]),
                                  direction: cells[1], mbps: Double(cells[2]), overhead: cells[3],
                                  latencyMs: Double(cells[4]), status: cells[5])
        }
    }

    /// Pair adjacent up/down entries completed within two minutes of each other, newest first.
    static func runs(from entries: [SpeedTestEntry]) -> [SpeedTestRun] {
        var runs: [SpeedTestRun] = []
        var i = 0
        while i < entries.count {
            let a = entries[i]
            var run = SpeedTestRun()
            if a.isDownload { run.download = a } else { run.upload = a }
            if i + 1 < entries.count {
                let b = entries[i + 1]
                let close = (a.time != nil && b.time != nil) ? abs(a.time!.timeIntervalSince(b.time!)) < 120 : false
                if close && b.isDownload != a.isDownload {
                    if b.isDownload { run.download = b } else { run.upload = b }
                    i += 1
                }
            }
            runs.append(run)
            i += 1
        }
        return runs.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
    }

    /// The page auto-refreshes ("freshen") while a test is running.
    static func isRunning(_ html: String) -> Bool {
        HTML.firstMatch(#"name="hidden"\s+value="([^"]*)""#, in: html) == "freshen"
            || html.localizedCaseInsensitiveContains("in progress")
    }
}
