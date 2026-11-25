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
        WindowGroup {
            DashboardView()
                .environment(model)
                .environment(settings)
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 600)
                #endif
        }
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
