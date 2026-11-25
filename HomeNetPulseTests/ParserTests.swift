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

    func testSubmitButtons() {
        let html = #"<input type="submit" name="Restart" class="x" value="Restart" /><input type="hidden" name="a" value="b">"#
        XCTAssertEqual(HTML.submitButtons(in: html).map(\.name), ["Restart"])
    }

    func testPingerLocalhost() async {
        let r = await Pinger.ping("127.0.0.1", count: 2, timeout: 1)
        XCTAssertEqual(r.received, 2, r.error ?? "")
    }
}
