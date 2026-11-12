import Foundation
@testable import Pinfold
import Testing

struct FavoritePinsTests {
    private func hit(
        _ key: String, folder: String = "a", lat: Double? = nil, lon: Double? = nil, hasPoint: Bool = true
    ) -> PlacemarkIndex.Hit {
        PlacemarkIndex.Hit(folderName: folder, key: key, name: key, lat: lat, lon: lon, hasPoint: hasPoint)
    }

    @Test func onlyPointFavoritesBecomePins() {
        let hits = [
            hit("point", lat: 1, lon: 2),
            hit("line", lat: 3, lon: 4, hasPoint: false),
            hit("nocoord", hasPoint: true),
        ]
        let pins = FavoritePins.pins(from: hits)
        #expect(pins.map(\.key) == ["point"])
        #expect(pins.first?.latitude == 1)
    }

    @Test func tintIsStablePerFile() {
        let first = FavoritePins.tintIndex(forFolder: "folder-1")
        #expect(first == FavoritePins.tintIndex(forFolder: "folder-1"))
        #expect((0 ..< FavoritePins.paletteSize).contains(first))
        let pins = FavoritePins.pins(from: [
            hit("x", folder: "folder-1", lat: 0, lon: 0), hit("y", folder: "folder-1", lat: 1, lon: 1),
        ])
        #expect(Set(pins.map(\.tintIndex)).count == 1)
        let spread = Set((0 ..< 40).map { FavoritePins.tintIndex(forFolder: "f\($0)") })
        #expect(spread.count > 1)
    }

    @Test func nearestFirstOrdersByDistance() {
        let hits = [hit("far", lat: 10, lon: 10), hit("near", lat: 0.1, lon: 0.1), hit("mid", lat: 1, lon: 1)]
        let sorted = FavoritePins.nearestFirst(hits, latitude: 0, longitude: 0)
        #expect(sorted.map(\.key) == ["near", "mid", "far"])
    }

    @Test func favoritesWithoutCoordinatesSortLast() {
        let hits = [hit("none"), hit("far", lat: 10, lon: 10), hit("none2"), hit("near", lat: 1, lon: 1)]
        let sorted = FavoritePins.nearestFirst(hits, latitude: 0, longitude: 0)
        #expect(sorted.map(\.key) == ["near", "far", "none", "none2"])
    }
}
