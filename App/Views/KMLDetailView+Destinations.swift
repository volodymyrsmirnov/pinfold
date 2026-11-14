import CoreLocation
import PinfoldCore
import SwiftUI

extension KMLDetailView {
    /// Resolves a pushed route into its screen. A `.placemark` whose stableKey no longer
    /// resolves renders empty — unreachable in practice (routes are validated before
    /// pushing) but a safe no-op if the document changes under an open stack.
    @ViewBuilder
    func destinationView(for route: EntryRoute) -> some View {
        if let document {
            switch route {
            case let .placemark(stableKey):
                if let match = document.root.firstPlacemark(withStableKey: stableKey) {
                    PlacemarkDetailView(placemark: match, document: document, entry: entry)
                        .environment(annotations)
                }
            case let .map(focusKey):
                // "Show on Map" (focusKey != nil) plots EVERY coordinate-bearing placemark
                // (the POI page has no search context); the toolbar/restored map (focusKey
                // == nil) plots the live filtered outline — both exactly as before the
                // route refactor.
                if let focusKey {
                    PlacemarkMapView(
                        placemarks: document.root.allPlacemarks.filter { $0.coordinate != nil },
                        document: document,
                        entry: entry,
                        initialFocusKey: focusKey
                    )
                    .environment(annotations)
                } else if let outline {
                    PlacemarkMapView(
                        placemarks: outline.mappablePlacemarks,
                        document: document,
                        entry: entry,
                        initialFocusKey: nil,
                        // A search's results: frame them, not wherever the map was last left.
                        fitsPlacemarks: !outlineQuery.isEmpty
                    )
                    .environment(annotations)
                } else {
                    // A restored `.map` route can be pushed before the first outline build
                    // completes. Creating the map with an empty placemark set would let the
                    // pin-reconcile re-fit override the saved per-file camera once pins land —
                    // hold a placeholder until the outline exists, so the map is created once,
                    // with its real content. (`outline` never goes back to nil after the first
                    // build, so this placeholder can't reappear later.)
                    ProgressView()
                }
            }
        }
    }
}
