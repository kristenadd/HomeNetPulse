import SwiftUI

#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI quits a single-`Window` app when that window closes; keep running while the
    /// menu bar status icon is enabled so monitoring continues in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.menuBarIconEnabled
    }

    static var menuBarIconEnabled: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
    }

    /// Show the Dock icon while the main window is open; run as a menu-bar-only app otherwise.
    @MainActor static func mainWindowVisibilityChanged(_ visible: Bool) {
        if visible {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
        } else if menuBarIconEnabled {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
#endif

@main
struct HomeNetPulseApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
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
                .onAppear { AppDelegate.mainWindowVisibilityChanged(true) }
                .onDisappear { AppDelegate.mainWindowVisibilityChanged(false) }
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
