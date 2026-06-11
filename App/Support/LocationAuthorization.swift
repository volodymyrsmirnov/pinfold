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

    /// The most recent location fix, or `nil` until one arrives (and `nil` when authorization is
    /// denied). Drives the placemark distance subtitles and the "nearest first" sort. A coarse
    /// last-known fix is fine here — distances are shown to the road, not surveyed.
    private(set) var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        isAuthorized = Self.authorized(manager.authorizationStatus)
    }

    /// Requests When-In-Use authorization (no-op if already determined) and, when authorized,
    /// asks for a single location fix. Safe to call repeatedly — e.g. each time a detail view
    /// appears; `requestLocation` coalesces into one delegate callback.
    func request() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if Self.authorized(manager.authorizationStatus) {
            requestOneShotFix()
        }
    }

    /// Requests a single location update (one-shot). The fix lands in `locationManager(_:didUpdateLocations:)`.
    private func requestOneShotFix() {
        manager.requestLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.isAuthorized = Self.authorized(status)
            // Authorization just resolved (e.g. the user granted the prompt) — grab a fix now so
            // distances appear without the caller having to re-request.
            if Self.authorized(status) { self.requestOneShotFix() }
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            self.lastLocation = latest
        }
    }

    /// `requestLocation` reports failures here; we simply keep the last known fix (possibly nil).
    nonisolated func locationManager(_: CLLocationManager, didFailWithError _: any Error) {}

    private static func authorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }
}
