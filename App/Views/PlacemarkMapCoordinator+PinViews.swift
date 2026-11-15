import MapKit
import UIKit

/// Icon pins and cluster bubbles: ring-colour lookup and view setup.
extension PlacemarkMapRepresentable.Coordinator {
    /// The selection-ring colour for a pin's base image (its hue, `IconPalette.accentColor`),
    /// analysed once per image.
    func ringColor(for annotation: PlacemarkAnnotation) -> UIColor? {
        let id = ObjectIdentifier(annotation.baseImage)
        if let cached = ringColors[id] {
            return cached.color
        }
        let color = IconPalette.accentColor(for: annotation.baseImage)
        ringColors[id] = (annotation.baseImage, color)
        return color
    }

    /// Applies icon, ring colour and favourite/visited to an icon pin.
    func configureIconPin(_ view: IconPinAnnotationView, for annotation: PlacemarkAnnotation) {
        view.configure(
            icon: annotation.baseImage,
            ringColor: ringColor(for: annotation),
            isFavorite: parent.favoriteKeys.contains(annotation.stableKey),
            isVisited: parent.visitedKeys.contains(annotation.stableKey)
        )
    }

    /// A cluster bubble showing the member count.
    func clusterView(for cluster: MKClusterAnnotation, in mapView: MKMapView) -> MKAnnotationView {
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: ClusterBubbleAnnotationView.reuseID)
            as? ClusterBubbleAnnotationView
            ?? ClusterBubbleAnnotationView(annotation: cluster, reuseIdentifier: ClusterBubbleAnnotationView.reuseID)
        view.annotation = cluster
        view.configure(count: cluster.memberAnnotations.count)
        return view
    }
}
