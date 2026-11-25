import SwiftUI

struct SettingsView: View {
    @Environment(DashboardModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var routerURL = ""
    @State private var password = ""
    @State private var newTarget = ""
    @State private var saveMessage: String?

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
                Button("Save to Keychain") {
                    let ok = settings.saveRouterCredentials(url: routerURL, password: password)
                    saveMessage = ok ? "Saved to Keychain." : "Could not save to Keychain."
                    Task { await model.refreshRouter() }
                }
                .disabled(routerURL.isEmpty)
                if let saveMessage { Text(saveMessage).font(.caption).foregroundStyle(.secondary) }
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
    }

    private func addTarget() {
        let t = newTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !settings.pingTargets.contains(t) else { return }
        settings.pingTargets.append(t)
        newTarget = ""
        Task { await model.refreshInternet() }
    }
}
