import Foundation

/// MAC prefix → manufacturer, from the bundled manuf.tsv (Wireshark's copy of the IEEE registry).
enum Manufacturers {
    private static let table: [String: String] = {
        guard let url = Bundle.main.url(forResource: "manuf", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var dict: [String: String] = [:]
        dict.reserveCapacity(60_000)
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            dict[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return dict
    }()

    /// Manufacturer for a MAC like "88:1f:a1:28:58:6b". Randomized (private) addresses have none.
    static func name(for mac: String?) -> String? {
        guard let mac else { return nil }
        let hex = mac.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
        guard hex.count == 12, let first = UInt8(hex.prefix(2), radix: 16), first & 0x02 == 0 else { return nil }
        // Most specific block first: /36 (MA-S), /28 (MA-M), /24 (MA-L)
        for digits in [9, 7, 6] {
            if let n = table[String(hex.prefix(digits))] { return n }
        }
        return nil
    }

    /// Load the table off the main thread ahead of the first lookup.
    static func preload() { _ = table.count }
}
