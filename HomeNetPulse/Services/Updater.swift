#if os(macOS)
import AppKit
import Combine
import Sparkle

/// Checks for and installs Mac updates with Sparkle. The feed URL, signing key and check interval
/// are in Info.plist (project.yml); each GitHub release carries a signed appcast.xml written by the
/// release workflow. iPhone/iPad builds update through Firebase App Distribution instead.
///
/// The Debug app ("HomeNet Pulse (Debug)") never updates: installing a release over it would put a
/// second copy of the release app ID on this Mac, which confuses macOS permissions.
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    /// Updates are possible at all (false in the Debug app).
    let isAvailable = !AppInfo.isDebugBuild
    /// False while a check or install is already in progress.
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecks = false {
        didSet {
            if isAvailable, updater.automaticallyChecksForUpdates != automaticallyChecks {
                updater.automaticallyChecksForUpdates = automaticallyChecks
            }
        }
    }
    @Published private(set) var lastCheck: Date?

    private var controller: SPUStandardUpdaterController!
    private var updater: SPUUpdater { controller.updater }
    private var observers: Set<AnyCancellable> = []

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: isAvailable, updaterDelegate: nil, userDriverDelegate: self)
        guard isAvailable else { return }
        automaticallyChecks = updater.automaticallyChecksForUpdates
        lastCheck = updater.lastUpdateCheckDate
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observers)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastCheck = $0 }
            .store(in: &observers)
    }

    func checkForUpdates() {
        guard isAvailable else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    // HomeNet Pulse usually runs from the menu bar with no Dock icon, so Sparkle asks how to show
    // updates found by the daily background check. Show Sparkle's window, brought to the front so it
    // doesn't open behind other apps.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        DispatchQueue.main.async { NSApp.activate() }
    }
}
#endif
