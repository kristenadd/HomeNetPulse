import SwiftUI

@main
struct HomeNetPulseApp: App {
    @State private var settings: AppSettings
    @State private var model: DashboardModel

    init() {
        let s = AppSettings()
        _settings = State(initialValue: s)
        _model = State(initialValue: DashboardModel(settings: s))
    }

    var body: some Scene {
        #if os(macOS)
        // Single main window so "Open HomeNet Pulse" in the menu bar reuses it.
        Window("HomeNet Pulse", id: "main") {
            DashboardView()
                .environment(model)
                .environment(settings)
                .frame(minWidth: 560, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 900)
        MenuBarExtra(isInserted: Binding(get: { settings.showMenuBarIcon },
                                         set: { settings.showMenuBarIcon = $0 })) {
            MenuBarStatusView()
                .environment(model)
                .environment(settings)
        } label: {
            MenuBarLabel()
                .environment(model)
                .environment(settings)
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            DashboardView()
                .environment(model)
                .environment(settings)
        }
        #endif
        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .environment(settings)
                .frame(width: 520, height: 620)
        }
        #endif
    }
}
