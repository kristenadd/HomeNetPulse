import SwiftUI
import Security
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @Environment(DashboardModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var routerURL = ""
    @State private var password = ""
    @State private var newTarget = ""
    @State private var newHostname = ""
    @State private var saveMessage: (ok: Bool, text: String)?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                TextField("Router URL", text: $routerURL, prompt: Text(AppSettings.defaultRouterURL))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Device Access Code", text: $password)
                    .onSubmit(saveCredentials)
                HStack {
                    if let saveMessage {
                        Label(saveMessage.text, systemImage: saveMessage.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(saveMessage.ok ? .green : .red)
                    } else if !settings.routerPassword.isEmpty && password == settings.routerPassword {
                        Label("Access code saved in Keychain", systemImage: "key.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save", action: saveCredentials)
                        .keyboardShortcut("s")
                        .disabled(routerURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Fiber Gateway")
            } footer: {
                Text("The Device Access Code is printed on the gateway's label. It is stored only in this device's Keychain.")
            }

            Section("Internet Ping Targets") {
                ForEach(settings.pingTargets, id: \.self) { t in
                    HStack {
                        Text(t).font(.body.monospaced())
                        Spacer()
                        Button { settings.pingTargets.removeAll { $0 == t } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(t)")
                    }
                }
                HStack {
                    TextField("Add IP or hostname", text: $newTarget)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit(addTarget)
                    Button("Add", action: addTarget).disabled(newTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Reset to 1.1.1.1 and 8.8.8.8") { settings.pingTargets = AppSettings.defaultTargets }
            }

            Section {
                ForEach(settings.dnsHostnames, id: \.self) { h in
                    HStack {
                        Text(h).font(.body.monospaced())
                        Spacer()
                        Button { settings.dnsHostnames.removeAll { $0 == h } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(h)")
                    }
                }
                HStack {
                    TextField("Add hostname", text: $newHostname)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit(addHostname)
                    Button("Add", action: addHostname)
                        .disabled(newHostname.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Reset to apple.com, google.com, amazon.com") { settings.dnsHostnames = AppSettings.defaultDNSHostnames }
            } header: {
                Text("DNS Check")
            } footer: {
                Text("These names are resolved against your router, your ISP's DNS servers and public DNS on every refresh.")
            }

            #if os(macOS)
            Section {
                LaunchAtLoginToggle()
                Toggle("Show status in menu bar", isOn: $settings.showMenuBarIcon)
                Toggle("Show internet latency next to the icon", isOn: $settings.showLatencyInMenuBar)
                    .disabled(!settings.showMenuBarIcon)
            } header: {
                Text("Mac")
            } footer: {
                Text("The icon stays monochrome while everything is healthy and turns orange or red when something needs attention. Monitoring keeps running while the main window is closed.")
            }
            #endif

            Section {
                Toggle(isOn: Binding(get: { settings.useLocationForWiFi },
                                     set: { on in
                                         settings.useLocationForWiFi = on
                                         if on { LocationAccess.shared.request() }
                                         Task { await model.refreshWiFi() }
                                     })) {
                    #if os(macOS)
                    Text("Exact match using Location")
                    #else
                    Text("Detect connected base station")
                    #endif
                }
                if settings.useLocationForWiFi && LocationAccess.shared.isAuthorized {
                    Label("Location allowed", systemImage: "location.fill").font(.caption).foregroundStyle(.green)
                } else if settings.useLocationForWiFi && !LocationAccess.shared.isDenied {
                    HStack {
                        Label("Waiting for Location permission", systemImage: "location").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Ask Again") { LocationAccess.shared.request() }.controlSize(.small)
                    }
                }
                if settings.useLocationForWiFi && LocationAccess.shared.isDenied {
                    Label("Location access is off for HomeNet Pulse. Turn it on in System Settings › Privacy & Security › Location Services.",
                          systemImage: "location.slash")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Wi-Fi Connection")
            } footer: {
                #if os(macOS)
                Text("HomeNet Pulse shows a Connected badge on the base station this Mac uses by matching its Wi-Fi channel. Allowing Location lets macOS reveal the access point address for an exact match. Your location is never stored or sent.")
                #else
                Text("iOS only reveals which access point you're on when Location is allowed. Your location is never stored or sent.")
                #endif
            }

            Section("Refresh") {
                Picker("Auto-refresh every", selection: $settings.refreshInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                }
            }

            Section {
                if settings.trustedBaseStationMACs.isEmpty && settings.trustedRouterMAC == nil {
                    Text("No trusted network yet.").foregroundStyle(.secondary)
                }
                ForEach(settings.trustedBaseStationMACs.sorted(), id: \.self) { KeyValueRow(key: "Base station", value: $0) }
                if let r = settings.trustedRouterMAC { KeyValueRow(key: "Gateway WAN MAC", value: r) }
                Button("Trust Current Network") { model.trustCurrentNetwork() }
                Button("Forget Trusted Network", role: .destructive) { model.forgetTrustedNetwork() }
            } header: {
                Text("Trusted Network")
            } footer: {
                Text("HomeNet Pulse verifies it's on your network by matching these MAC addresses.")
            }

            Section {
                LabeledContent("Version") {
                    Text(Self.versionString).monospacedDigit().copyable(Self.versionString, label: "Version")
                }
            } footer: {
                Text("\(AppInfo.displayName) · \(AppInfo.bundleID)").frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            routerURL = settings.routerURL
            password = settings.routerPassword
        }
        // Never lose a typed access code: save when the sheet / window closes.
        .onDisappear { if hasUnsavedCredentials { performSave() } }
    }

    private var hasUnsavedCredentials: Bool {
        routerURL != settings.routerURL || password != settings.routerPassword
    }

    private func saveCredentials() {
        #if os(macOS)
        // Pasted / password-manager-filled text can sit in the field editor without reaching the
        // binding until editing ends, so end editing first and save on the next run-loop turn.
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
        DispatchQueue.main.async { performSave() }
    }

    private func performSave() {
        guard !routerURL.isEmpty else { return }
        password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = settings.saveRouterCredentials(url: routerURL, password: password)
        saveMessage = status == errSecSuccess
            ? (true, "Saved to Keychain")
            : (false, "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")")
        Task { await model.refreshRouter() }
    }

    /// "1.0.3 (42)" from the bundle: CI stamps the release version and the Actions run number.
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func addHostname() {
        let h = newHostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !h.isEmpty, !settings.dnsHostnames.contains(h) else { return }
        settings.dnsHostnames.append(h)
        newHostname = ""
        Task { await model.refreshDNS() }
    }

    private func addTarget() {
        let t = newTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !settings.pingTargets.contains(t) else { return }
        settings.pingTargets.append(t)
        newTarget = ""
        Task { await model.refreshInternet() }
    }
}
