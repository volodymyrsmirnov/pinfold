import Network
import Observation

/// Whether the device currently has a usable network path. Wraps `NWPathMonitor`; tests use
/// `init(isOnline:)` for a fixed state that starts no monitor.
@MainActor @Observable final class NetworkStatus {
    /// `true` when the current path is satisfied. Optimistic (`true`) until the first update.
    private(set) var isOnline: Bool

    @ObservationIgnored private var monitor: NWPathMonitor?

    /// Live status backed by an `NWPathMonitor`.
    init() {
        isOnline = true
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let online = Self.isOnline(path.status)
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "tech.inkhorn.pinfold.network-status"))
    }

    /// Fixed status, no monitoring (tests / previews).
    init(isOnline: Bool) {
        self.isOnline = isOnline
    }

    /// Fixed status derived from a path status (testable without a real `NWPath`).
    convenience init(pathStatus: NWPath.Status) {
        self.init(isOnline: Self.isOnline(pathStatus))
    }

    nonisolated static func isOnline(_ status: NWPath.Status) -> Bool {
        status == .satisfied
    }

    deinit {
        monitor?.cancel()
    }
}
