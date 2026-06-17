import MapKit
@testable import Pinfold
import PinfoldCore
import SwiftUI
import Testing
import UIKit

/// Tests for the UIKit controls layered over the embedded `MKMapView`.
///
/// The suite is `@MainActor` because it constructs UIKit / MapKit views directly.
@MainActor
struct MapControlsTests {
    @Test func embeddedMapControls_includeCompassBetweenStyleAndTracking() throws {
        let mapView = MKMapView(frame: CGRect(origin: .zero, size: CGSize(width: 320, height: 480)))
        let representable = Self.representable()
        let coordinator = PlacemarkMapRepresentable.Coordinator(representable)

        representable.addControls(to: mapView, coordinator: coordinator)

        let stack = try #require(mapView.allSubviews(ofType: UIStackView.self).first { stack in
            let arranged = stack.arrangedSubviews
            return arranged.contains { $0.containsSubview(ofType: UIButton.self) }
                && arranged.contains { $0.containsSubview(ofType: MKUserTrackingButton.self) }
        })
        #expect(stack.arrangedSubviewControlKinds == [.style, .compass, .tracking])
    }

    private static func representable() -> PlacemarkMapRepresentable {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let document = KMLDocument(
            name: nil,
            descriptionHTML: nil,
            root: KMLContainer(id: "root", name: nil, children: [], placemarks: []),
            styles: [:],
            styleMaps: [:]
        )
        let entry = CatalogEntry(
            id: UUID(),
            displayName: "Map",
            sourceFilename: "map.kml",
            importDate: Date(timeIntervalSince1970: 0),
            pointCount: 0,
            contentSHA256: "sha",
            storageFolderName: "entry"
        )
        return PlacemarkMapRepresentable(
            placemarks: [],
            document: document,
            entry: entry,
            resourceCache: ResourceCache(),
            storage: StorageLocations(root: root),
            showsUserLocation: false,
            clusterPins: false,
            favoriteKeys: [],
            visitedKeys: [],
            selectedKey: .constant(nil)
        )
    }
}

private extension UIView {
    func allSubviews<T: UIView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { subview in
            ((subview as? T).map { [$0] } ?? []) + subview.allSubviews(ofType: type)
        }
    }

    func containsSubview<T: UIView>(ofType type: T.Type) -> Bool {
        if self is T { return true }
        return subviews.contains { $0.containsSubview(ofType: type) }
    }
}

private extension UIStackView {
    enum ControlKind {
        case style
        case compass
        case tracking
        case unknown
    }

    var arrangedSubviewControlKinds: [ControlKind] {
        arrangedSubviews.map { container in
            if container.containsSubview(ofType: MKCompassButton.self) { return .compass }
            if container.containsSubview(ofType: MKUserTrackingButton.self) { return .tracking }
            if container.containsSubview(ofType: UIButton.self) { return .style }
            return .unknown
        }
    }
}
