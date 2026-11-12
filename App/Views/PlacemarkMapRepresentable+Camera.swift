import MapKit
import PinfoldCore
import SwiftUI
import UIKit

extension PlacemarkMapRepresentable {
    // MARK: - Fit to pins

    /// Fits the map to the union of all pin coordinates and overlay bounding rects.
    ///
    /// Overlay rects are folded in via `MKMapRect.union` on each overlay's
    /// `boundingMapRect`. Antimeridian handling for *overlays* stays naive (a line that
    /// straddles the 180° seam can over-expand the fit) — `MapRectBuilder`'s wrapped-rect
    /// logic applies only to the point set; overlay coordinates are typically dense enough
    /// that a seam-crossing fit is an acceptable edge case here.
    static func fit(
        coordinates: [Coordinate],
        overlays: [StyledOverlay] = [],
        in mapView: MKMapView,
        animated: Bool
    ) {
        var rect = MapRectBuilder.boundingRect(for: coordinates) ?? .null
        for styled in overlays {
            rect = rect.union(styled.overlay.boundingMapRect)
        }
        guard !rect.isNull else { return }
        if rect.size.width == 0, rect.size.height == 0 {
            // Single pin (or all coincident): use a fixed ~1 km span centered on it.
            let region = MKCoordinateRegion(
                center: MKMapPoint(x: rect.origin.x, y: rect.origin.y).coordinate,
                latitudinalMeters: 1000,
                longitudinalMeters: 1000
            )
            mapView.setRegion(region, animated: animated)
        } else {
            mapView.setVisibleMapRect(rect, edgePadding: edgePadding, animated: animated)
        }
    }

    /// Zooms to a fixed ~1 km region centered on `annotation` and selects it. Selecting
    /// fires the coordinator's `didSelect`, which sets `selectedKey`, highlights the pin,
    /// and surfaces its preview card — so the initial-focus path reuses the exact selection
    /// behavior a tap produces. The 1 km span matches `fit`'s single-pin case.
    static func focus(on annotation: PlacemarkAnnotation, in mapView: MKMapView) {
        let region = MKCoordinateRegion(
            center: annotation.coordinate,
            latitudinalMeters: 1000,
            longitudinalMeters: 1000
        )
        mapView.setRegion(region, animated: false)
        mapView.selectAnnotation(annotation, animated: false)
    }

    /// Applies a persisted camera, unanimated (this is the initial framing).
    static func apply(_ state: MapCameraState, to mapView: MKMapView) {
        let camera = MKMapCamera(
            lookingAtCenter: CLLocationCoordinate2D(latitude: state.latitude, longitude: state.longitude),
            fromDistance: state.distance,
            pitch: CGFloat(state.pitch),
            heading: state.heading
        )
        mapView.setCamera(camera, animated: false)
    }

    /// Snapshots the map's current camera + tracking mode for persistence.
    static func cameraState(of mapView: MKMapView) -> MapCameraState {
        let camera = mapView.camera
        return MapCameraState(
            latitude: camera.centerCoordinate.latitude,
            longitude: camera.centerCoordinate.longitude,
            distance: camera.centerCoordinateDistance,
            heading: camera.heading,
            pitch: Double(camera.pitch),
            isTracking: mapView.userTrackingMode != .none
        )
    }
}
