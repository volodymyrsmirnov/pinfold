import PinfoldCore
import SwiftUI

/// What a place's actions need to know about it: its stable key (the identity favourites, Seen
/// and notes are stored under), name and coordinate. Built from a parsed `KMLPlacemark` (the
/// file's rows and place screen) or from a catalogue search hit (which has no parsed
/// placemark), so the same actions work in both.
struct PlaceRef {
    let key: String
    let name: String?
    let coordinate: Coordinate?

    init(_ placemark: KMLPlacemark) {
        key = placemark.stableKey
        name = placemark.name
        coordinate = placemark.coordinate
    }

    init(_ hit: PlacemarkIndex.Hit) {
        key = hit.key
        name = hit.name.isEmpty ? nil : hit.name
        if let lat = hit.lat, let lon = hit.lon {
            coordinate = Coordinate(longitude: lon, latitude: lat)
        } else {
            coordinate = nil
        }
    }

    /// What Share sends for a place: an Apple Maps link to its coordinate, labelled with its
    /// name, or `nil` when the place has no coordinate. Built with `URLComponents`, so a name
    /// containing `&`, `=` or `+` stays part of the query value.
    var shareURL: URL? {
        guard let coordinate else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        // Apple Maps' `ll` wants `lat,lon` with a `.` decimal separator; pin the locale so a
        // comma-decimal region doesn't corrupt the URL.
        let ll = String(
            format: "%f,%f", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude, coordinate.longitude
        )
        components.queryItems = [URLQueryItem(name: "ll", value: ll), URLQueryItem(name: "q", value: name ?? "")]
        // `URLComponents` leaves `+` unescaped in query values, where it is often read as a
        // space; encode it too.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

/// The actions on one place, built once and used by every surface that offers them: the place
/// screen's "⋯" menu, the long-press menu on a place row (in the file, and in catalogue search
/// results) and on the map's place card, the menu bar (`PlaceCommands`, minus Share), and — as a
/// subset — the row's swipe. Keeping them in one place is what keeps those
/// surfaces identical (same items, same labels, same order, same behaviour).
///
/// Groups, each separated: Share (when the place has a coordinate); then any actions only the
/// caller's screen has (`screenActions` — the place screen's "Show on Map"; a row passes none,
/// since tapping it already opens the place); then Add to Favorites / Mark as Seen (when
/// favourites are available, disabled when the file can't be written); then Copy Coordinates /
/// Copy Name. Share leads, as in the file menus (see "UI action consistency" in CLAUDE.md).
struct PlacemarkActions<ScreenActions: View>: View {
    let place: PlaceRef
    let annotations: PlacemarkAnnotations?
    let screenActions: ScreenActions

    init(
        place: PlaceRef,
        annotations: PlacemarkAnnotations?,
        @ViewBuilder screenActions: () -> ScreenActions = { EmptyView() }
    ) {
        self.place = place
        self.annotations = annotations
        self.screenActions = screenActions()
    }

    var body: some View {
        if let url = place.shareURL {
            Section {
                PlacemarkShareLink(place: place, url: url)
            }
        }
        Section {
            screenActions
        }
        if let annotations {
            Section {
                PlacemarkFavoriteButton(place: place, annotations: annotations, style: .menu)
                PlacemarkSeenButton(place: place, annotations: annotations, style: .menu)
            }
        }
        Section {
            if let coordinate = place.coordinate {
                Button {
                    UIPasteboard.general.string = CoordinateFormatter.string(for: coordinate)
                } label: {
                    Label("Copy Coordinates", systemImage: "doc.on.doc")
                }
            }
            if let name = place.name, !name.isEmpty {
                Button {
                    UIPasteboard.general.string = name
                } label: {
                    Label("Copy Name", systemImage: "character.cursor.ibeam")
                }
            }
        }
    }
}

/// A place row's swipe-right actions: Share first (as on file rows), then the Favorite and Seen
/// toggles with the short labels swipe buttons need. Shared by the file's rows and the
/// catalogue search results.
struct PlacemarkSwipeActions: View {
    let place: PlaceRef
    let annotations: PlacemarkAnnotations?

    var body: some View {
        if let url = place.shareURL {
            PlacemarkShareLink(place: place, url: url)
                .tint(.blue)
        }
        if let annotations {
            PlacemarkFavoriteButton(place: place, annotations: annotations, style: .swipe)
                .tint(.yellow)
            PlacemarkSeenButton(place: place, annotations: annotations, style: .swipe)
                .tint(.indigo)
        }
    }
}

/// Menu labels are full phrases; swipe buttons use the short form.
enum PlaceActionStyle {
    case menu
    case swipe
}

struct PlacemarkFavoriteButton: View {
    let place: PlaceRef
    let annotations: PlacemarkAnnotations
    let style: PlaceActionStyle

    var body: some View {
        let on = annotations.isFavorite(key: place.key)
        Button {
            annotations.toggleFavorite(key: place.key)
        } label: {
            switch style {
            case .menu:
                Label(on ? "Remove from Favorites" : "Add to Favorites", systemImage: on ? "star.slash" : "star")
            case .swipe:
                Label(on ? "Unfavorite" : "Favorite", systemImage: on ? "star.slash" : "star")
            }
        }
        .disabled(!annotations.canEdit)
    }
}

struct PlacemarkSeenButton: View {
    let place: PlaceRef
    let annotations: PlacemarkAnnotations
    let style: PlaceActionStyle

    var body: some View {
        let on = annotations.isVisited(key: place.key)
        Button {
            annotations.toggleVisited(key: place.key)
        } label: {
            switch style {
            case .menu:
                Label(on ? "Mark as Unseen" : "Mark as Seen", systemImage: on ? "eye.slash" : "eye")
            case .swipe:
                Label(on ? "Mark Unseen" : "Mark Seen", systemImage: on ? "eye.slash" : "eye")
            }
        }
        .disabled(!annotations.canEdit)
    }
}

/// Share for a place, as used by its menus and its row's swipe actions.
struct PlacemarkShareLink: View {
    let place: PlaceRef
    let url: URL

    var body: some View {
        ShareLink(item: url, subject: Text(place.name ?? "Placemark")) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}
