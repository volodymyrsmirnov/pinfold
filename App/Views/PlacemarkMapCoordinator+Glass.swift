import MapKit
import UIKit

/// Glass pins and cluster bubbles: tint lookup, the flat-fallback rule and view setup.
extension PlacemarkMapRepresentable.Coordinator {
    /// Above this many placemarks, pins and clusters use the pre-drawn translucent disc
    /// instead of live glass: every live glass view costs a blur pass, and an unclustered
    /// large file can put hundreds on screen at once.
    static let flatGlassThreshold = 300

    /// Whether this file's pins use the flat (pre-drawn) disc instead of live glass.
    var usesFlatGlass: Bool {
        parent.placemarks.count > Self.flatGlassThreshold
    }

    /// The glass tint for a pin's base image, analysed once per image.
    func glassTint(for annotation: PlacemarkAnnotation) -> UIColor? {
        // Teardrop pins carry their colour in the shape; only icon pins are tinted.
        guard annotation.anchor == .center else { return nil }
        let id = ObjectIdentifier(annotation.baseImage)
        if let cached = glassTints[id] {
            return cached.tint
        }
        let tint = IconPalette.glassTint(for: annotation.baseImage)
        glassTints[id] = (annotation.baseImage, tint)
        return tint
    }

    /// Applies icon, tint, favourite/visited and glass/flat to a glass pin.
    func configureGlass(_ view: GlassPinAnnotationView, for annotation: PlacemarkAnnotation) {
        view.configure(
            icon: annotation.baseImage,
            tint: glassTint(for: annotation),
            isFavorite: parent.favoriteKeys.contains(annotation.stableKey),
            isVisited: parent.visitedKeys.contains(annotation.stableKey),
            isFlat: usesFlatGlass
        )
    }

    /// A glass cluster bubble showing the member count, tinted with the members' shared hue.
    func clusterView(for cluster: MKClusterAnnotation, in mapView: MKMapView) -> MKAnnotationView {
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: GlassClusterAnnotationView.reuseID)
            as? GlassClusterAnnotationView
            ?? GlassClusterAnnotationView(annotation: cluster, reuseIdentifier: GlassClusterAnnotationView.reuseID)
        view.annotation = cluster
        let tints = cluster.memberAnnotations.map { member in
            (member as? PlacemarkAnnotation).flatMap(glassTint(for:))
        }
        view.configure(
            count: cluster.memberAnnotations.count,
            tint: GlassClusterAnnotationView.majorityTint(of: tints),
            isFlat: usesFlatGlass
        )
        return view
    }
}
