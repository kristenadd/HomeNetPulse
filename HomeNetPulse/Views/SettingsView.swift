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

    private func addTarget() {
        let t = newTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !settings.pingTargets.contains(t) else { return }
        settings.pingTargets.append(t)
        newTarget = ""
        Task { await model.refreshInternet() }
    }
}
