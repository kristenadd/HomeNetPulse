import XCTest
@testable import HomeNetPulse

final class ParserTests: XCTestCase {
    let broadbandHTML = """
    <form method="post" action="/cgi-bin/broadbandstatistics.ha">
    <input type="hidden" name="nonce" value="abc123" />
    <div class="section-header"><h2>Primary Broadband</h2></div>
    <table><tr><th scope="row">Broadband Connection</th><td class="col2"><img src="x.png" /> Up</td></tr>
    <tr><th scope="row">Broadband IPv4 Address</th>
        <td class="col2">172.5.97.208</td></tr>
    <tr><th scope="row">Gateway IPv4 Address</th><td class="col2">172.5.96.1</td></tr>
    <tr><th scope="row">MAC Address</th><td class="col2">10:c4:ca:49:75:80</td></tr>
    <tr><th scope="row">Primary DNS</th><td class="col2">68.94.156.9</td></tr>
    <tr><th scope="row">Secondary DNS</th><td class="col2">68.94.157.9</td></tr></table>
    <div class="section-header"><h2>IPv6</h2></div>
    <table><tr><th scope="row">Primary DNS</th><td class="col2"></td></tr></table>
    <div class="section-header"><h2>IPv4 Statistics</h2></div>
    <table><tr><th>Receive Errors</th><td>0</td></tr><tr><th>Receive Drops</th><td>10</td></tr></table>
    </form>
    """

    func testBroadbandSummary() {
        let s = BroadbandSummary(sections: BroadbandParser.parse(broadbandHTML))
        XCTAssertEqual(s.sections.map(\.title), ["Primary Broadband", "IPv6", "IPv4 Statistics"])
        XCTAssertEqual(s.gatewayIPv4, "172.5.96.1")
        XCTAssertEqual(s.primaryDNS, "68.94.156.9")
        XCTAssertEqual(s.secondaryDNS, "68.94.157.9")
        XCTAssertEqual(s.wanMAC, "10:c4:ca:49:75:80")
        XCTAssertEqual(s.lineState, "Up")
        XCTAssertEqual(s.receiveDrops, "10")
        XCTAssertEqual(HTML.nonce(in: broadbandHTML), "abc123")
    }

    func testConnectionMatching() {
        let main = BaseStation(name: "Main", txt: AirPortBrowser.parseCSV("raMA=88-1F-A1-30-57-6F,raM2=88-1F-A1-30-57-6E,raCh=149,rCh2=6"))
        let tc = BaseStation(name: "TC", txt: AirPortBrowser.parseCSV("raMA=4C-32-75-C6-80-0D,raM2=4C-32-75-C6-80-0C,raCh=112,rCh2=1"))
        // Channel match (no BSSID without Location)
        var w = WiFiStatus(channel: 112, band: .ghz5, rssi: -37)
        XCTAssertEqual(ConnectionMatcher.match(w, in: [main, tc])?.0.name, "TC")
        XCTAssertEqual(ConnectionMatcher.match(w, in: [main, tc])?.1, .channel)
        XCTAssertEqual(w.frequencyMHz, 5560)
        XCTAssertEqual(w.frequencyText, "5 GHz · 5560 MHz")
        // 2.4 GHz channel 6
        w = WiFiStatus(channel: 6, band: .ghz24)
        XCTAssertEqual(ConnectionMatcher.match(w, in: [main, tc])?.0.name, "Main")
        XCTAssertEqual(w.frequencyMHz, 2437)
        // BSSID wins, including a nearby address on the same radio
        w = WiFiStatus(bssid: "88:1f:a1:30:57:70", channel: 112, band: .ghz5)
        XCTAssertEqual(ConnectionMatcher.match(w, in: [main, tc])?.0.name, "Main")
        XCTAssertEqual(ConnectionMatcher.match(w, in: [main, tc])?.1, .bssid)
        // Ambiguous channel → no match
        let other = BaseStation(name: "Other", txt: AirPortBrowser.parseCSV("raCh=112"))
        XCTAssertNil(ConnectionMatcher.match(WiFiStatus(channel: 112, band: .ghz5), in: [tc, other]))
    }

    func testSpeedTestParsing() {
        let html = """
        <form method="post" action="/cgi-bin/speed.ha"><input type="hidden" name="hidden" value="" />
        <table class="grid table100" summary="Table of Speed Test Result History"><thead><tr><th>Test Completion Time</th></tr></thead>
        <tbody>
        <tr class="b"><td scope="row" class="heading" width="47%">
            11/24/2026 20:16:28</td><td>downstream</td><td> 1295.540000</td><td> 28</td><td> 26.000000</td><td> Success</td></tr>
        <tr class="a"><td scope="row" class="heading" width="47%">
            11/24/2026 20:16:15</td><td>upstream</td><td> 1290.290000</td><td> 28</td><td> 16.000000</td><td> Success</td></tr>
        <tr class="b"><td scope="row" class="heading" width="47%">
            11/19/2026 10:46:43</td><td>upstream</td><td> 1271.690000</td><td> 28</td><td> 19.000000</td><td> Success</td></tr>
        <tr class="a"><td scope="row" class="heading" width="47%">
            11/19/2026 10:46:35</td><td>downstream</td><td> 1295.520000</td><td> 28</td><td> 26.000000</td><td> Success</td></tr>
        </tbody></table></form>
        """
        let entries = SpeedTestParser.parse(html)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].mbps, 1295.54)
        XCTAssertTrue(entries[0].isDownload)
        XCTAssertEqual(entries[1].latencyMs, 16)
        let runs = SpeedTestParser.runs(from: entries)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].download?.mbps, 1295.54)
        XCTAssertEqual(runs[0].upload?.mbps, 1290.29)
        XCTAssertEqual(runs[0].latencyMs, 21)
        XCTAssertEqual(DashboardView.speedSummary(runs[0]), "↓1296 ↑1290 Mbps")
    }

    func testArpParsing() {
        let text = """
        ? (192.168.1.1) at 88:1f:a1:28:58:6b on en0 ifscope [ethernet]
        ? (192.168.1.2) at (incomplete) on en0 ifscope [ethernet]
        ? (192.168.1.20) at 0:e:c6:8b:d8:40 on en0 ifscope [ethernet]
        ? (192.168.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        """
        let arp = LANScanner.parseArp(text)
        XCTAssertEqual(arp["192.168.1.1"], "88:1f:a1:28:58:6b")
        XCTAssertEqual(arp["192.168.1.20"], "00:0e:c6:8b:d8:40")
        XCTAssertNil(arp["192.168.1.2"])
        XCTAssertNil(arp["192.168.1.255"])
        XCTAssertTrue(LANDevice(ip: "1", mac: "da:a1:19:00:00:01").isPrivateMAC)
        XCTAssertFalse(LANDevice(ip: "1", mac: "88:1f:a1:28:58:6b").isPrivateMAC)
    }

    func testManufacturerLookup() {
        XCTAssertEqual(Manufacturers.name(for: "88:1f:a1:28:58:6b"), "Apple")
        XCTAssertEqual(Manufacturers.name(for: "e8:9f:80:37:78:90"), "Belkin International")
        XCTAssertEqual(Manufacturers.name(for: "00:1b:c5:00:00:05"), "Converging Systems")   // /36 block
        XCTAssertNil(Manufacturers.name(for: "da:a1:19:00:00:01"))                           // private address
        XCTAssertNil(Manufacturers.name(for: nil))
    }

    func testPONState() {
        var s = BroadbandSummary(sections: [StatSection(title: "GPON Status", rows: [StatRow(key: "PON Link Status", value: "OPERATION (O5)")])])
        XCTAssertEqual(s.ponFriendly, "Connected (O5)")
        XCTAssertEqual(s.ponHealthy, true)
        s.ponStatus = "INTERMITTENT LODS (O6)"
        XCTAssertEqual(s.ponFriendly, "Signal lost (O6)")
        XCTAssertEqual(s.ponHealthy, false)
    }

    func testDiagPing() {
        let out = """
        PING 1.1.1.1 (1.1.1.1): 56 data bytes
        64 bytes from 1.1.1.1: seq=0 ttl=55 time=13.683 ms
        64 bytes from 1.1.1.1: seq=1 ttl=55 time=12.809 ms

        --- 1.1.1.1 ping statistics ---
        5 packets transmitted, 4 packets received, 20% packet loss
        round-trip min/avg/max = 11.705/12.410/13.683 ms
        test done
        """
        let r = DiagPingParser.parse(out, host: "1.1.1.1")
        XCTAssertEqual(r.sent, 5)
        XCTAssertEqual(r.received, 4)
        XCTAssertEqual(r.rttsMs, [13.683, 12.809])
        XCTAssertEqual(r.resolvedAddress, "1.1.1.1")
    }

    func testAirPortTXT() {
        let txt = AirPortBrowser.parseCSV("waMA=88-1F-A1-28-58-6B,raNm=Home-5Ghz,syAP=120,syVs=7.9.1")
        let s = BaseStation(name: "Test", txt: txt)
        XCTAssertEqual(s.ethernetMAC, "88:1f:a1:28:58:6b")
        XCTAssertEqual(s.modelName, "AirPort Extreme (802.11ac)")
        XCTAssertEqual(s.firmware, "7.9.1")
    }

    func testRestartForm() {
        // Mirrors the BGW320 restart.ha form.
        let html = """
        <form method="post" action="/cgi-bin/restart.ha">
        <input type="hidden" name="nonce" value="abc123" />
        <input type="submit" name="Restart" class="cssbtn" value="Restart" />
        <input type="submit" name="Cancel" class="cssbtn" value="Cancel" />
        </form>
        """
        let form = RestartForm(html: html)
        XCTAssertEqual(form?.nonce, "abc123")
        XCTAssertEqual(form?.button, "Restart")
        XCTAssertEqual(form?.fields.map { "\($0.0)=\($0.1)" }, ["nonce=abc123", "Restart=Restart"])
        // A page with only a Cancel button must never produce a restart.
        XCTAssertNil(RestartForm(html: #"<input type="hidden" name="nonce" value="x" /><input type="submit" name="Cancel" value="Cancel Restart" />"#))
    }

    func testSubmitButtons() {
        let html = #"<input type="submit" name="Restart" class="x" value="Restart" /><input type="hidden" name="a" value="b">"#
        XCTAssertEqual(HTML.submitButtons(in: html).map(\.name), ["Restart"])
    }

    func testPingerLocalhost() async {
        let r = await Pinger.ping("127.0.0.1", count: 2, timeout: 1)
        XCTAssertEqual(r.received, 2, r.error ?? "")
    }
}
