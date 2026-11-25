import Foundation
import CryptoKit

enum RouterError: LocalizedError {
    case invalidURL
    case http(Int)
    case unreachable(String)
    case missingPassword
    case loginFailed
    case unexpectedPage(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The router URL is invalid."
        case .http(let code): "Router returned HTTP \(code)."
        case .unreachable(let msg): "Router unreachable: \(msg)"
        case .missingPassword: "Enter the router's Device Access Code in Settings."
        case .loginFailed: "Login failed — check the Device Access Code."
        case .unexpectedPage(let msg): "Unexpected router page: \(msg)"
        }
    }
}

/// Client for AT&T / Arris fiber gateways (BGW210 / BGW320) at e.g. http://192.168.0.254/.
actor RouterClient {
    nonisolated let baseURL: URL
    private var base: URL { baseURL }
    private let password: String
    private let session: URLSession

    init(base: URL, password: String) {
        self.baseURL = base
        self.password = password
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60    // the gateway is slow: home.ha alone takes ~14 s
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        session = URLSession(configuration: config)
    }

    private func url(_ path: String) -> URL { base.appending(path: path) }

    private func get(_ path: String) async throws -> String {
        try await send(URLRequest(url: url(path)))
    }

    private func post(_ path: String, form: [(String, String)]) async throws -> String {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(url(path).absoluteString, forHTTPHeaderField: "Referer")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        req.httpBody = form.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> String {
        do {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
                throw RouterError.http(http.statusCode)
            }
            return String(decoding: data, as: UTF8.self)
        } catch let e as RouterError {
            throw e
        } catch let e as URLError {
            // Include the code so intermittent failures (timeouts vs refused vs offline) can be told apart.
            throw RouterError.unreachable("\(e.localizedDescription) [URLError \(e.code.rawValue)]")
        } catch {
            throw RouterError.unreachable(error.localizedDescription)
        }
    }

    /// Fetch a page, priming the session cookie first (the gateway rejects cookieless requests).
    private func page(_ path: String) async throws -> String {
        var html = try await get(path)
        if HTML.isLoginPage(html), HTML.nonce(in: html) == nil {
            html = try await get(path)   // first hit only sets SessionID
        }
        return html
    }

    func broadband() async throws -> BroadbandSummary {
        let html = try await page("cgi-bin/broadbandstatistics.ha")
        if HTML.isLoginPage(html) {
            try await login(from: html)
            return BroadbandSummary(sections: BroadbandParser.parse(try await page("cgi-bin/broadbandstatistics.ha")))
        }
        return BroadbandSummary(sections: BroadbandParser.parse(html))
    }

    /// Ask the gateway itself to ping `host` via cgi-bin/diag.ha and parse the result.
    func devicePing(_ host: String, timeout: TimeInterval = 90) async throws -> (PingResult, String) {
        var html = try await page("cgi-bin/diag.ha")
        if HTML.isLoginPage(html) {
            try await login(from: html)
            html = try await page("cgi-bin/diag.ha")
        }
        guard let nonce = HTML.nonce(in: html) else { throw RouterError.unexpectedPage("diag.ha has no form") }
        var output = HTML.textarea(named: "ProgressWindow", in: try await post("cgi-bin/diag.ha", form: [
            ("nonce", nonce), ("WebAddress", host), ("protopref", "IPv4"), ("Ping", "Ping"),
        ])) ?? ""
        let deadline = Date().addingTimeInterval(timeout)
        // The gateway streams results into the ProgressWindow; it shows the final output once
        // ("test done") and then clears it, so keep the last non-empty snapshot.
        while !output.contains("test done") && Date() < deadline {
            try await Task.sleep(for: .seconds(1.5))
            let snapshot = HTML.textarea(named: "ProgressWindow", in: try await get("cgi-bin/diag.ha"))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !snapshot.isEmpty { output = snapshot }
            else if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
        }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (DiagPingParser.parse(text, host: host), text)
    }

    /// Fetch a page that may require the Device Access Code.
    private func authenticatedPage(_ path: String) async throws -> String {
        var html = try await page(path)
        if HTML.isLoginPage(html) {
            try await login(from: html)
            html = try await page(path)
            if HTML.isLoginPage(html) { throw RouterError.loginFailed }
        }
        return html
    }

    /// Optical module readings from cgi-bin/fiberstat.ha (temperature, Tx/Rx power, thresholds).
    func fiberStatus() async throws -> FiberStatus {
        FiberStatusParser.parse(try await authenticatedPage("cgi-bin/fiberstat.ha"))
    }

    /// Speed test history from cgi-bin/speed.ha (newest first).
    func speedTestHistory() async throws -> [SpeedTestEntry] {
        SpeedTestParser.parse(try await authenticatedPage("cgi-bin/speed.ha"))
    }

    /// Run the gateway's own speed test and wait for its results (typically ~30 s).
    func runSpeedTest(timeout: TimeInterval = 180) async throws -> [SpeedTestEntry] {
        let html = try await authenticatedPage("cgi-bin/speed.ha")
        let before = SpeedTestParser.parse(html).first?.id
        guard let nonce = HTML.nonce(in: html) else { throw RouterError.unexpectedPage("speed test form missing") }
        let button = HTML.submitButtons(in: html).first { $0.name == "run" || $0.value.localizedCaseInsensitiveContains("speed") }
            ?? (name: "run", value: "Run Speed Test")
        _ = try await post("cgi-bin/speed.ha", form: [("nonce", nonce), ("hidden", ""), (button.name, button.value)])

        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var lastNewCount = 0
        var lastChange = start
        while Date() < deadline {
            try await Task.sleep(for: .seconds(4))
            let entries = SpeedTestParser.parse(try await authenticatedPage("cgi-bin/speed.ha"))
            // Rows added since we pressed Run (the gateway does upload first, then download).
            let new = entries.prefix { $0.id != before }
            if new.count != lastNewCount { lastNewCount = new.count; lastChange = Date() }
            if new.contains(where: \.isDownload) && new.contains(where: { !$0.isDownload }) {
                return entries
            }
            // One direction finished but the other never showed up.
            if !new.isEmpty && Date().timeIntervalSince(lastChange) > 45 { return entries }
        }
        throw RouterError.unexpectedPage("speed test did not finish within \(Int(timeout)) s")
    }

    /// Log in with the Device Access Code: hashpassword = md5(password + nonce), password masked with '*'.
    private func login(from loginPage: String) async throws {
        guard !password.isEmpty else { throw RouterError.missingPassword }
        var html = loginPage
        if HTML.nonce(in: html) == nil { html = try await page("cgi-bin/login.ha") }
        guard let nonce = HTML.nonce(in: html) else { throw RouterError.unexpectedPage("login form missing") }
        let hash = Insecure.MD5.hash(data: Data((password + nonce).utf8)).map { String(format: "%02x", $0) }.joined()
        let result = try await post("cgi-bin/login.ha", form: [
            ("nonce", nonce),
            ("password", String(repeating: "*", count: password.count)),
            ("hashpassword", hash),
            ("Continue", "Continue"),
        ])
        if HTML.isLoginPage(result) { throw RouterError.loginFailed }
    }

    /// Restart the gateway via cgi-bin/restart.ha (requires the Device Access Code).
    func restart() async throws -> String {
        let html = try await authenticatedPage("cgi-bin/restart.ha")
        guard let form = RestartForm(html: html) else {
            throw RouterError.unexpectedPage("restart button not found")
        }
        do {
            let result = try await post("cgi-bin/restart.ha", form: form.fields)
            return HTML.title(in: result) ?? "Restart requested"
        } catch RouterError.unreachable {
            return "Restart requested — the gateway dropped the connection while rebooting."
        }
    }
}

/// The BGW restart page: a POST form with the page nonce and two submit buttons,
/// `Restart` (name="Restart" value="Restart") and `Cancel`. There is no JavaScript confirmation.
struct RestartForm: Equatable {
    var nonce: String
    var button: String
    var value: String

    init?(html: String) {
        guard let nonce = HTML.nonce(in: html) else { return nil }
        let buttons = HTML.submitButtons(in: html)
        // Prefer the exact Restart button; never the Cancel button.
        guard let b = buttons.first(where: { $0.name == "Restart" })
                ?? buttons.first(where: {
                    !$0.name.localizedCaseInsensitiveContains("cancel")
                        && ($0.name.localizedCaseInsensitiveContains("restart") || $0.value.localizedCaseInsensitiveContains("restart"))
                }) else { return nil }
        self.nonce = nonce
        self.button = b.name
        self.value = b.value
    }

    var fields: [(String, String)] { [("nonce", nonce), (button, value)] }
}
