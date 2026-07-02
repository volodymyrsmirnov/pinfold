import Foundation

// MARK: - MapCameraState

/// A serializable snapshot of an `MKMapCamera`'s framing — `centerCoordinate` (split into
/// latitude/longitude), `centerCoordinateDistance`, `heading`, and `pitch` (the four
/// `MKMapCamera` properties) — plus whether user-location tracking (follow-with-heading)
/// was engaged. Plain `Double`s (no MapKit types) so the store is testable without a map
/// view; `PlacemarkMapRepresentable` owns the conversion.
struct MapCameraState: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    /// `MKMapCamera.centerCoordinateDistance`, in meters.
    var distance: Double
    var heading: Double
    var pitch: Double
    /// Whether user-location tracking (follow-with-heading) was engaged when this state
    /// was saved — remembered per file, like the camera itself.
    var isTracking: Bool

    init(latitude: Double, longitude: Double, distance: Double, heading: Double, pitch: Double, isTracking: Bool) {
        self.latitude = latitude
        self.longitude = longitude
        self.distance = distance
        self.heading = heading
        self.pitch = pitch
        self.isTracking = isTracking
    }

    /// Lenient decode: `isTracking` was added after cameras began persisting, so blobs
    /// written without it must read as `false` instead of failing the whole dictionary.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        distance = try container.decode(Double.self, forKey: .distance)
        heading = try container.decode(Double.self, forKey: .heading)
        pitch = try container.decode(Double.self, forKey: .pitch)
        isTracking = try container.decodeIfPresent(Bool.self, forKey: .isTracking) ?? false
    }
}

// MARK: - MapCameraStore

/// Per-file remembered map cameras, keyed by entry `storageFolderName`, in a single
/// UserDefaults JSON blob. Owned by the map layer (same ownership pattern as the persisted
/// basemap-style key) — deliberately NOT part of `AppSettings` or the resume snapshot, and
/// not gated by the restore toggle: like the basemap style, it persists across sessions.
///
/// Not main-actor-bound: it is called from the `MKMapView` delegate (main thread in
/// practice) and from `RootView`'s bootstrap; `UserDefaults` itself is thread-safe and the
/// read-modify-write races that could theoretically drop a write are harmless here (the
/// value is a convenience cache).
final class MapCameraStore {
    static let defaultsKey = "mapCameraStates"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func camera(forFolderName folderName: String) -> MapCameraState? {
        readAll()[folderName]
    }

    func setCamera(_ camera: MapCameraState, forFolderName folderName: String) {
        var all = readAll()
        all[folderName] = camera
        writeAll(all)
    }

    /// Drops cameras for files no longer in the catalogue — but only once the dictionary
    /// outgrows `cap`; below it, stale entries are harmless bytes. Called from `RootView`'s
    /// bootstrap with the full folder-name set (active AND trashed, so restoring a file
    /// from the trash keeps its camera).
    func pruneIfNeeded(keeping folderNames: Set<String>, cap: Int = 100) {
        let all = readAll()
        guard all.count > cap else { return }
        writeAll(all.filter { folderNames.contains($0.key) })
    }

    private func readAll() -> [String: MapCameraState] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: MapCameraState].self, from: data)
        else { return [:] }
        return decoded
    }

    private func writeAll(_ all: [String: MapCameraState]) {
        defaults.set(try? JSONEncoder().encode(all), forKey: Self.defaultsKey)
    }
}
