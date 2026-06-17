import MapKit
@testable import Pinfold
import Testing

/// Tests for the embedded map's user-location configuration.
///
/// The suite is `@MainActor` because it constructs MapKit views directly.
@MainActor
struct MapUserLocationTests {
    @Test func userLocationEnabled_followsWithHeading() {
        let mapView = RecordingMapView()

        PlacemarkMapRepresentable.configureUserLocation(
            on: mapView, showsUserLocation: true, animated: false
        )

        #expect(mapView.showsUserLocation)
        #expect(mapView.requestedTrackingMode == .followWithHeading)
        #expect(mapView.requestedAnimated == false)
    }

    @Test func userLocationDisabled_clearsHeadingTracking() {
        let mapView = RecordingMapView()
        mapView.showsUserLocation = true

        PlacemarkMapRepresentable.configureUserLocation(
            on: mapView, showsUserLocation: false, animated: true
        )

        #expect(!mapView.showsUserLocation)
        #expect(mapView.requestedTrackingMode == MKUserTrackingMode.none)
        #expect(mapView.requestedAnimated == true)
    }
}

private final class RecordingMapView: MKMapView {
    var requestedTrackingMode: MKUserTrackingMode?
    var requestedAnimated: Bool?

    override func setUserTrackingMode(_ mode: MKUserTrackingMode, animated: Bool) {
        requestedTrackingMode = mode
        requestedAnimated = animated
        super.setUserTrackingMode(mode, animated: false)
    }
}
