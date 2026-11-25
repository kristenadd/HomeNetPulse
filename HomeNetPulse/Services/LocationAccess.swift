import Foundation
import CoreLocation
import Observation

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
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.status = s }
    }
}
