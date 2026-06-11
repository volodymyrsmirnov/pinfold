import MapKit

// MARK: - EmbeddedMapStyle

/// The basemap style for the in-app map, surfaced as a picker on the map screen.
enum EmbeddedMapStyle: String, CaseIterable, Identifiable {
    /// Standard vector ("geo") map.
    case standard
    /// Satellite imagery only.
    case satellite
    /// Satellite imagery with roads and labels.
    case hybrid

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .standard: "Map"
        case .satellite: "Satellite"
        case .hybrid: "Hybrid"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "map"
        case .satellite: "globe.americas"
        case .hybrid: "globe.americas.fill"
        }
    }

    /// The MapKit configuration realizing this style.
    var configuration: MKMapConfiguration {
        switch self {
        case .standard: MKStandardMapConfiguration()
        case .satellite: MKImageryMapConfiguration()
        case .hybrid: MKHybridMapConfiguration()
        }
    }
}
