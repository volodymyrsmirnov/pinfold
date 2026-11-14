import PinfoldCore
import SwiftUI

/// The actions on one place, built once and used by every menu that offers them: the place
/// screen's "⋯" menu and the long-press menu on a place row. Keeping them in one view is what
/// keeps those menus identical (same items, same labels, same order, same behaviour).
///
/// Groups: Add to Favorites / Mark as Seen (when favourites are available), then Copy
/// Coordinates / Share (when the place has a coordinate) / Copy Name. The place screen puts
/// its own "Show on Map" above these; a row doesn't, since tapping it already opens the place.
struct PlacemarkActions: View {
    let placemark: KMLPlacemark
    let annotations: PlacemarkAnnotations?

    var body: some View {
        if let annotations {
            Section {
                Button {
                    annotations.toggleFavorite(placemark)
                } label: {
                    let on = annotations.isFavorite(placemark)
                    Label(on ? "Remove from Favorites" : "Add to Favorites", systemImage: on ? "star.slash" : "star")
                }
                Button {
                    annotations.toggleVisited(placemark)
                } label: {
                    let on = annotations.isVisited(placemark)
                    Label(on ? "Mark as Unseen" : "Mark as Seen", systemImage: on ? "eye.slash" : "eye")
                }
            }
        }
        Section {
            if let coord = placemark.coordinate {
                Button {
                    UIPasteboard.general.string = CoordinateFormatter.string(for: coord)
                } label: {
                    Label("Copy Coordinates", systemImage: "doc.on.doc")
                }
            }
            if let url = Self.shareURL(for: placemark) {
                PlacemarkShareLink(placemark: placemark, url: url)
            }
            Button {
                UIPasteboard.general.string = placemark.name ?? ""
            } label: {
                Label("Copy Name", systemImage: "character.cursor.ibeam")
            }
        }
    }

    /// What Share sends for a place: an Apple Maps link to its coordinate, labelled with its
    /// name, or `nil` when the place has no coordinate.
    static func shareURL(for placemark: KMLPlacemark) -> URL? {
        guard let coord = placemark.coordinate else { return nil }
        let query = (placemark.name ?? "")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // Apple Maps' `ll` wants `lat,lon` with a `.` decimal separator; pin the locale so a
        // comma-decimal region doesn't corrupt the URL.
        let ll = String(
            format: "%f,%f", locale: Locale(identifier: "en_US_POSIX"), coord.latitude, coord.longitude
        )
        return URL(string: "https://maps.apple.com/?ll=\(ll)&q=\(query)")
    }
}

/// Share for a place, as used by its menus and its row's swipe actions.
struct PlacemarkShareLink: View {
    let placemark: KMLPlacemark
    let url: URL

    var body: some View {
        ShareLink(item: url, subject: Text(placemark.name ?? "Placemark")) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}
