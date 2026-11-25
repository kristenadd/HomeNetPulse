import Foundation
import Network

/// Tracks whether this device is on a Wi-Fi or wired network. HomeNet Pulse only makes sense there:
/// on cellular (or with no network) the gateway, base stations and LAN aren't reachable.
@MainActor
final class LocalNetworkMonitor {
    private let monitor = NWPathMonitor()
    var onChange: ((Bool) -> Void)?
    private(set) var isOnLocalNetwork: Bool?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let local = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in
                guard let self, self.isOnLocalNetwork != local else { return }
                self.isOnLocalNetwork = local
                self.onChange?(local)
            }
        }
        monitor.start(queue: DispatchQueue(label: "local-network-monitor"))
    }
}
