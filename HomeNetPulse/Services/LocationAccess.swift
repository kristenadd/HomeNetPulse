import Foundation
import CoreLocation
import Observation
#if os(macOS)
import AppKit
#endif

/// Location permission is only used so the OS reveals the Wi-Fi access point address (BSSID).
@MainActor @Observable
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()
    private let manager = CLLocationManager()
    private(set) var status: CLAuthorizationStatus

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool {
        #if os(macOS)
        status == .authorizedAlways || status == .authorized
        #else
        status == .authorizedWhenInUse || status == .authorizedAlways
        #endif
    }

    var isDenied: Bool { status == .denied || status == .restricted }

    func request() {
        status = manager.authorizationStatus
        guard !isAuthorized else { return }
        manager.requestWhenInUseAuthorization()
        // On macOS the permission dialog only appears once the app actually asks for a location.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.requestLocation()
        #if os(macOS)
        NSApp.activate()   // menu-bar apps must be frontmost for the dialog to show
        #endif
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.status = s }
    }

    // The location itself is never used or stored; these only satisfy requestLocation().
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
