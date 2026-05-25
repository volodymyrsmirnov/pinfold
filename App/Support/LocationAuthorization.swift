import CoreLocation
import SwiftUI

// MARK: - LocationAuthorization

/// A tiny `@Observable` wrapper around `CLLocationManager` that requests
/// "When In Use" authorization and publishes whether location use is allowed.
///
/// The map sets `MKMapView.showsUserLocation` from `isAuthorized`; when authorization
/// is denied/restricted the map functions normally with no user-location dot.
@MainActor
@Observable
final class LocationAuthorization: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()

    /// `true` when the user has granted When-In-Use or Always authorization.
    private(set) var isAuthorized = false

    override init() {
        super.init()
        manager.delegate = self
        isAuthorized = Self.authorized(manager.authorizationStatus)
    }

    /// Requests When-In-Use authorization. No-op if already determined.
    func request() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.isAuthorized = Self.authorized(status)
        }
    }

    private static func authorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }
}
