import Foundation

/// One starred point placemark on the Favourites map.
struct FavoritePin: Identifiable, Equatable {
    let folderName: String
    let key: String
    let name: String
    let latitude: Double
    let longitude: Double
    /// Index into the fixed tint palette; stable per file.
    let tintIndex: Int

    var id: String {
        "\(folderName)/\(key)"
    }
}

/// Pure helpers for the Favourites map (D7): resolved hits to pins, a stable per-file tint,
/// and distance ordering. No UI or CoreLocation so it is trivially testable.
enum FavoritePins {
    /// Number of tints in the palette the view maps `tintIndex` onto.
    static let paletteSize = 8

    /// Points only: favourites without a real `<Point>` (lines, polygons, no coordinate) are skipped.
    static func pins(from hits: [PlacemarkIndex.Hit]) -> [FavoritePin] {
        hits.compactMap { hit in
            guard hit.hasPoint, let lat = hit.lat, let lon = hit.lon else { return nil }
            return FavoritePin(
                folderName: hit.folderName, key: hit.key, name: hit.name,
                latitude: lat, longitude: lon, tintIndex: tintIndex(forFolder: hit.folderName)
            )
        }
    }

    /// A deterministic palette slot for a file (FNV-1a over UTF-8; `Hashable` is seeded per launch).
    static func tintIndex(forFolder folderName: String) -> Int {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in folderName.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return Int(hash % UInt64(paletteSize))
    }

    /// Great-circle distance in metres (haversine), or `nil` when the hit has no coordinate.
    static func distance(of hit: PlacemarkIndex.Hit, latitude: Double, longitude: Double) -> Double? {
        guard let lat = hit.lat, let lon = hit.lon else { return nil }
        let rad = Double.pi / 180
        let dLat = (lat - latitude) * rad
        let dLon = (lon - longitude) * rad
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * rad) * cos(lat * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// Hits ordered nearest to farthest from the origin; hits without coordinates keep their
    /// relative order at the end.
    static func nearestFirst(
        _ hits: [PlacemarkIndex.Hit], latitude: Double, longitude: Double
    ) -> [PlacemarkIndex.Hit] {
        let measured = hits.enumerated().map { offset, hit in
            (offset: offset, hit: hit, distance: distance(of: hit, latitude: latitude, longitude: longitude))
        }
        return measured.sorted { lhs, rhs in
            switch (lhs.distance, rhs.distance) {
            case let (l?, r?): l != r ? l < r : lhs.offset < rhs.offset
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.hit)
    }
}
