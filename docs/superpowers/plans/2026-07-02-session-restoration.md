# Session Restoration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the app to its pre-termination state (selected file, navigation stack, list scroll, transient list state) and remember each file's map camera across sessions.

**Architecture:** Refactor the detail column to value-based navigation (`NavigationStack(path:)` over a `Codable` `EntryRoute` enum), persist the path + per-file UI state in UserDefaults via `AppSettings` on `scenePhase → .inactive`, and replay it at the end of `RootView.bootstrap()` through a one-shot `RestoreBundle` that also subsumes the existing deep-link plumbing. Map cameras live in a separate per-file `MapCameraStore`.

**Tech Stack:** SwiftUI (iOS 26), MapKit (`MKMapView` representable), UserDefaults, Swift Testing (`@Test`/`#expect`), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-02-session-restoration-design.md` — read it before starting.

## Global Constraints

- Min target **iOS 26**; build/test ONLY via `scripts/build.sh` and `scripts/test.sh` (iPhone 17 simulator, iOS 26.5, signing disabled). Parser package unaffected by this plan.
- After ADDING any file under `App/` or `AppTests/`, the scripts run `xcodegen generate` automatically — never edit `Pinfold.xcodeproj` (generated, gitignored).
- `swiftlint lint` must stay at **0 errors** (warnings are a known backlog). A PostToolUse hook runs `swiftformat` on every edited `.swift` file — let it own comma/spacing style.
- Do NOT add explicit `Sendable` to internal all-value-type structs (SwiftFormat's `redundantSendable` strips it; conformance is implicit).
- Keep view `body`s and captured closures small; put logic in named private methods (Swift SIL `ClosureLifetimeFixup` pathology — see comments in `FavoritesView.swift`).
- All work on branch `feature/session-restoration`; commit after every task; merge to `main` with `--no-ff` at the end (Task 10).
- Every commit message ends with the trailer line: `Claude-Session: https://claude.ai/code/session_01EYocFdaGHNVorJBtCaFNz9`
- Tests: `@Suite(.serialized) @MainActor` for suites sharing `@MainActor` state; inject fresh `UserDefaults(suiteName:)` per test (see `AppTests/AppSettingsTests.swift` for the pattern); never touch real Application Support or iCloud.
- UI state is **per-device**: everything this plan persists goes to local UserDefaults, never `metadata.json` (which syncs).

---

### Task 1: Branch + `EntryRoute` model

**Files:**
- Create: `App/Model/EntryRoute.swift`
- Test: `AppTests/EntryRouteTests.swift`

**Interfaces:**
- Consumes: nothing (pure model).
- Produces:
  - `enum EntryRoute: Hashable, Codable { case placemark(stableKey: String); case map(focusKey: String?) }`
  - `EntryRoute.encodeForResume(_ routes: [EntryRoute]) -> Data?`
  - `EntryRoute.decodeForResume(_ data: Data?) -> [EntryRoute]` (empty array on nil/corrupt/version mismatch)
  - `EntryRoute.validatedForRestore(_ routes: [EntryRoute], resolves: (String) -> Bool) -> [EntryRoute]`
  - `struct RestoreBundle: Equatable` with fields `entryFolderName: String?`, `routes: [EntryRoute]`, `searchText: String`, `collapsedFolderIDs: Set<String>`, `nearestFirst: Bool`, `scrollAnchorRowID: String?`

- [ ] **Step 1: Create the branch**

```bash
git checkout -b feature/session-restoration
```

- [ ] **Step 2: Write the failing tests**

Create `AppTests/EntryRouteTests.swift`:

```swift
import Foundation
import Testing
@testable import Pinfold

/// Tests for `EntryRoute` — the Codable navigation-route values persisted across launches —
/// and `RestoreBundle` plumbing helpers. Decoding is deliberately forgiving: anything that
/// isn't a valid, current-version payload yields an empty route list (the file then opens
/// at its placemark list, per the session-restoration spec's failure table).
struct EntryRouteTests {
    @Test func routes_roundTripThroughResumeData() {
        let routes: [EntryRoute] = [
            .placemark(stableKey: "h:Cafe|1.5|2.5"),
            .map(focusKey: "h:Cafe|1.5|2.5"),
            .map(focusKey: nil),
        ]
        let data = EntryRoute.encodeForResume(routes)
        #expect(data != nil)
        #expect(EntryRoute.decodeForResume(data) == routes)
    }

    @Test func decode_nilData_isEmpty() {
        #expect(EntryRoute.decodeForResume(nil).isEmpty)
    }

    @Test func decode_corruptData_isEmpty() {
        #expect(EntryRoute.decodeForResume(Data("not json".utf8)).isEmpty)
    }

    @Test func decode_foreignVersion_isEmpty() {
        let foreign = Data(#"{"version":99,"routes":[]}"#.utf8)
        #expect(EntryRoute.decodeForResume(foreign).isEmpty)
    }

    @Test func validate_keepsValidPrefix_truncatesAtFirstStaleKey() {
        let routes: [EntryRoute] = [
            .placemark(stableKey: "good"),
            .placemark(stableKey: "stale"),
            .placemark(stableKey: "good"),
        ]
        let valid = EntryRoute.validatedForRestore(routes) { $0 == "good" }
        #expect(valid == [.placemark(stableKey: "good")])
    }

    @Test func validate_dropsMapFocusKey() {
        // A restored map route must NOT re-focus its pin: the saved per-file camera
        // encodes where the user actually was and wins over a focus zoom (spec).
        let valid = EntryRoute.validatedForRestore([.map(focusKey: "any")]) { _ in true }
        #expect(valid == [.map(focusKey: nil)])
    }

    @Test func validate_emptyIn_emptyOut() {
        #expect(EntryRoute.validatedForRestore([]) { _ in true }.isEmpty)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `scripts/test.sh -only-testing:PinfoldTests/EntryRouteTests`
Expected: BUILD FAILURE — `cannot find 'EntryRoute' in scope` (the type doesn't exist yet).

- [ ] **Step 4: Write the implementation**

Create `App/Model/EntryRoute.swift`:

```swift
import Foundation

// MARK: - EntryRoute

/// A screen reachable inside an open file, as a self-contained durable value — the unit of
/// the detail column's `NavigationStack(path:)`.
///
/// Routes carry placemark `stableKey`s (the same durable identifier Spotlight, favorites,
/// and App Intents use), never live `KMLPlacemark`s, so a persisted route resolves — or
/// silently fails — against a re-parsed document exactly like existing deep links.
enum EntryRoute: Hashable, Codable {
    /// The placemark (POI) page.
    case placemark(stableKey: String)
    /// The full-file map. `focusKey` non-nil = "Show on Map" from a POI page (open zoomed
    /// to that pin); nil = the list's toolbar map button (fit-all / saved camera).
    case map(focusKey: String?)
}

extension EntryRoute {
    /// Envelope for the persisted route array. The version tag lets a future app change the
    /// route schema and have old payloads silently discarded instead of half-decoded.
    private struct ResumeEnvelope: Codable {
        static let currentVersion = 1
        var version: Int
        var routes: [EntryRoute]
    }

    /// Encodes routes for UserDefaults persistence. `nil` only on encoder failure
    /// (practically unreachable for this payload).
    static func encodeForResume(_ routes: [EntryRoute]) -> Data? {
        try? JSONEncoder().encode(ResumeEnvelope(version: ResumeEnvelope.currentVersion, routes: routes))
    }

    /// Decodes a persisted route array. Anything invalid — nil, corrupt bytes, or a foreign
    /// version — yields `[]`: the restored file then opens at its placemark list (spec's
    /// failure table), never a half-restored stack.
    static func decodeForResume(_ data: Data?) -> [EntryRoute] {
        guard let data,
              let envelope = try? JSONDecoder().decode(ResumeEnvelope.self, from: data),
              envelope.version == ResumeEnvelope.currentVersion
        else { return [] }
        return envelope.routes
    }

    /// Validates persisted routes against the freshly parsed document, keeping the longest
    /// valid prefix (a stack must not contain a hole). `resolves` reports whether a
    /// placemark `stableKey` still exists in the document.
    ///
    /// A restored `.map` route drops its `focusKey`: the saved per-file camera already
    /// encodes where the user actually was and must win over a re-focus zoom. (The pin's
    /// selection preview card is consequently not restored — accepted in the spec.)
    static func validatedForRestore(
        _ routes: [EntryRoute], resolves: (String) -> Bool
    ) -> [EntryRoute] {
        var valid: [EntryRoute] = []
        for route in routes {
            switch route {
            case let .placemark(stableKey):
                guard resolves(stableKey) else { return valid }
                valid.append(route)
            case .map:
                valid.append(.map(focusKey: nil))
            }
        }
        return valid
    }
}

// MARK: - RestoreBundle

/// A one-shot navigation payload handed to `KMLDetailView` when a selection is driven
/// programmatically — by a deep link (Spotlight, App Intent, a "Places"/favorites hit) or
/// by session restore. Consumed once via `onConsumeRestore`, like the `initialPlacemarkKey`
/// mechanism it replaces.
///
/// `entryFolderName` distinguishes the two producers: non-nil marks a session-restore
/// bundle (routes AND the transient list state are applied, and `RootView` only hands it to
/// the matching entry); nil marks a deep-link bundle (routes only — a live deep link must
/// never clobber the open file's search/sort/collapse state).
struct RestoreBundle: Equatable {
    var entryFolderName: String?
    var routes: [EntryRoute] = []
    var searchText: String = ""
    var collapsedFolderIDs: Set<String> = []
    var nearestFirst: Bool = false
    var scrollAnchorRowID: String?
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test.sh -only-testing:PinfoldTests/EntryRouteTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add App/Model/EntryRoute.swift AppTests/EntryRouteTests.swift
git commit -m "feat(app): add Codable EntryRoute navigation values and RestoreBundle

Claude-Session: https://claude.ai/code/session_01EYocFdaGHNVorJBtCaFNz9"
```

---

### Task 2: `AppSettings` resume keys

**Files:**
- Modify: `App/Model/AppSettings.swift` (whole file shown below)
- Test: `AppTests/AppSettingsTests.swift` (append a new suite)

**Interfaces:**
- Consumes: nothing new.
- Produces on `AppSettings`:
  - `var restoreSessionEnabled: Bool` (default **true**; setting `false` clears all resume state)
  - `var resumeEntryFolderName: String?` (writing a **different** value — including nil — clears the per-file slice below; re-writing the same value preserves it)
  - `var resumeRoutes: Data?`, `var resumeSearchText: String?`, `var resumeCollapsedFolderIDs: [String]?`, `var resumeNearestFirst: Bool`, `var resumeScrollAnchorRowID: String?`

- [ ] **Step 1: Write the failing tests**

Append to `AppTests/AppSettingsTests.swift` (after the existing `SettingsTests` suite, as a second suite in the same file):

```swift
/// Tests for the session-restoration slice of `AppSettings`. The cross-property couplings
/// (different folder clears the per-file slice; disabling the toggle clears everything) are
/// the risky part: in an `@Observable` class property observers DO fire for assignments
/// inside `init`, so without the bootstrap guard, initializing the folder name from disk
/// would wipe the very state being loaded.
@Suite(.serialized) @MainActor struct SettingsResumeTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "SettingsResumeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func restoreSessionEnabled_defaultsTrue() {
        #expect(AppSettings(defaults: makeDefaults()).restoreSessionEnabled == true)
    }

    @Test func restoreSessionEnabled_persistsFalse() {
        let defaults = makeDefaults()
        AppSettings(defaults: defaults).restoreSessionEnabled = false
        #expect(AppSettings(defaults: defaults).restoreSessionEnabled == false)
    }

    @Test func resumeSlice_roundTrips() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.resumeEntryFolderName = "folder-a"
        settings.resumeRoutes = Data([1, 2, 3])
        settings.resumeSearchText = "cafe"
        settings.resumeCollapsedFolderIDs = ["0", "0/1"]
        settings.resumeNearestFirst = true
        settings.resumeScrollAnchorRowID = "0/1/p2"

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.resumeEntryFolderName == "folder-a")
        #expect(fresh.resumeRoutes == Data([1, 2, 3]))
        #expect(fresh.resumeSearchText == "cafe")
        #expect(fresh.resumeCollapsedFolderIDs == ["0", "0/1"])
        #expect(fresh.resumeNearestFirst == true)
        #expect(fresh.resumeScrollAnchorRowID == "0/1/p2")
    }

    @Test func differentFolder_clearsPerFileSlice() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.resumeEntryFolderName = "folder-a"
        settings.resumeScrollAnchorRowID = "p1"
        settings.resumeSearchText = "x"
        settings.resumeRoutes = Data([9])

        settings.resumeEntryFolderName = "folder-b"
        #expect(settings.resumeScrollAnchorRowID == nil)
        #expect(settings.resumeSearchText == nil)
        #expect(settings.resumeRoutes == nil)
    }

    @Test func nilFolder_clearsPerFileSlice() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.resumeEntryFolderName = "folder-a"
        settings.resumeScrollAnchorRowID = "p1"

        settings.resumeEntryFolderName = nil
        #expect(settings.resumeScrollAnchorRowID == nil)
    }

    @Test func sameFolder_preservesPerFileSlice() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.resumeEntryFolderName = "folder-a"
        settings.resumeScrollAnchorRowID = "p1"

        settings.resumeEntryFolderName = "folder-a"
        #expect(settings.resumeScrollAnchorRowID == "p1")
    }

    @Test func disablingToggle_clearsEverything() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.resumeEntryFolderName = "folder-a"
        settings.resumeRoutes = Data([1])
        settings.resumeScrollAnchorRowID = "p1"

        settings.restoreSessionEnabled = false
        #expect(settings.resumeEntryFolderName == nil)
        #expect(settings.resumeRoutes == nil)
        #expect(settings.resumeScrollAnchorRowID == nil)
        #expect(AppSettings(defaults: defaults).resumeEntryFolderName == nil)
    }

    /// Regression test for the `@Observable` init gotcha: observers fire inside `init`, so
    /// without the bootstrap guard the init assignment of the folder name would trip the
    /// clear-on-different-folder coupling and delete the anchor being loaded.
    @Test func initWithSavedFolderAndAnchor_preservesAnchor() {
        let defaults = makeDefaults()
        let seed = AppSettings(defaults: defaults)
        seed.resumeEntryFolderName = "folder-a"
        seed.resumeScrollAnchorRowID = "0/p3"

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.resumeScrollAnchorRowID == "0/p3")
        #expect(fresh.resumeEntryFolderName == "folder-a")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh -only-testing:PinfoldTests/SettingsResumeTests`
Expected: BUILD FAILURE — `value of type 'AppSettings' has no member 'restoreSessionEnabled'`.

- [ ] **Step 3: Write the implementation**

Replace the whole of `App/Model/AppSettings.swift` with:

```swift
import Foundation
import Observation

/// App preferences, backed by `UserDefaults`.
///
/// Replaces the SwiftData `AppSettings` model. Values are stored in observable properties
/// (so SwiftUI views update) and mirrored to `UserDefaults` on every change (so the value
/// survives across `Settings` instances and app launches). Reading through `UserDefaults`
/// is what fixes the old "toggle shows stale state / only applies on app install" bug,
/// where the preference lived in an un-synchronising key-value store.
///
/// The sync preference is intentionally **per-device** (local `UserDefaults`): each device
/// decides whether to participate in iCloud sync. The session-restoration slice is likewise
/// per-device — it is UI state and must never sync.
@MainActor @Observable final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// Guards cross-property `didSet` side effects during `init`. In an `@Observable`
    /// class, property observers DO fire for assignments inside `init` (the macro rewrites
    /// stored properties into computed accessors), so without this flag the init assignment
    /// of `resumeEntryFolderName` would trip the clear-on-different-folder coupling and
    /// delete the saved per-file slice before it is ever read. Cleared LAST in `init`.
    @ObservationIgnored private var isBootstrapping = true

    private enum Key {
        static let enabledMapAppIDs = "settings.enabledMapAppIDs"
        static let defaultMapAppID = "settings.defaultMapAppID"
        static let clusterMapPins = "settings.clusterMapPins"
        static let syncEnabled = "settings.syncEnabled"
        static let entrySort = "settings.entrySort"
        static let restoreSessionEnabled = "settings.restoreSessionEnabled"
        static let resumeEntryFolderName = "settings.resumeEntryFolderName"
        static let resumeRoutes = "settings.resumeRoutes"
        static let resumeSearchText = "settings.resumeSearchText"
        static let resumeCollapsedFolderIDs = "settings.resumeCollapsedFolderIDs"
        static let resumeNearestFirst = "settings.resumeNearestFirst"
        static let resumeScrollAnchorRowID = "settings.resumeScrollAnchorRowID"
    }

    /// Identifiers of the map apps the user has explicitly enabled. Empty means "all
    /// installed apps are enabled" (see `MapAppService.availableApps`).
    var enabledMapAppIDs: [String] {
        didSet { defaults.set(enabledMapAppIDs, forKey: Key.enabledMapAppIDs) }
    }

    /// Identifier of the default map app, or `nil` to always show the picker sheet.
    var defaultMapAppID: String? {
        didSet { defaults.set(defaultMapAppID, forKey: Key.defaultMapAppID) }
    }

    /// Whether the in-app map clusters nearby pins.
    var clusterMapPins: Bool {
        didSet { defaults.set(clusterMapPins, forKey: Key.clusterMapPins) }
    }

    /// Whether this device participates in iCloud Drive sync. Off by default (opt-in).
    var syncEnabled: Bool {
        didSet { defaults.set(syncEnabled, forKey: Key.syncEnabled) }
    }

    /// How the catalogue's active list is ordered (presentation-level; see `EntrySort`).
    /// Stored as the case's raw-value string; defaults to `.dateDesc` (newest first).
    var entrySort: EntrySort {
        didSet { defaults.set(entrySort.rawValue, forKey: Key.entrySort) }
    }

    // MARK: - Session restoration

    /// Whether the app reopens the file/screen/position from the previous session on
    /// launch. ON by default (`bool(forKey:)` defaults to false, so read via `object`).
    /// Turning it off clears all saved session state.
    var restoreSessionEnabled: Bool {
        didSet {
            defaults.set(restoreSessionEnabled, forKey: Key.restoreSessionEnabled)
            guard !isBootstrapping, !restoreSessionEnabled else { return }
            resumeEntryFolderName = nil // cascades: clears the per-file slice too
        }
    }

    /// The `storageFolderName` of the entry selected when the app last deactivated, or
    /// `nil` when nothing was selected. Writing a DIFFERENT value (including nil) clears
    /// the per-file slice below — a scroll anchor, search query, or route stack is
    /// meaningless in another file; re-writing the same value preserves it.
    var resumeEntryFolderName: String? {
        didSet {
            defaults.set(resumeEntryFolderName, forKey: Key.resumeEntryFolderName)
            guard !isBootstrapping, resumeEntryFolderName != oldValue else { return }
            resumeRoutes = nil
            resumeSearchText = nil
            resumeCollapsedFolderIDs = nil
            resumeNearestFirst = false
            resumeScrollAnchorRowID = nil
        }
    }

    /// The JSON-encoded `[EntryRoute]` (versioned envelope; see `EntryRoute.encodeForResume`).
    var resumeRoutes: Data? {
        didSet { defaults.set(resumeRoutes, forKey: Key.resumeRoutes) }
    }

    /// The placemark list's search text at deactivation. `nil` = nothing saved.
    var resumeSearchText: String? {
        didSet { defaults.set(resumeSearchText, forKey: Key.resumeSearchText) }
    }

    /// Collapsed folder ids (positional tree paths) at deactivation. `nil` = nothing saved.
    var resumeCollapsedFolderIDs: [String]? {
        didSet { defaults.set(resumeCollapsedFolderIDs, forKey: Key.resumeCollapsedFolderIDs) }
    }

    /// Whether the nearest-first sort was active at deactivation.
    var resumeNearestFirst: Bool {
        didSet { defaults.set(resumeNearestFirst, forKey: Key.resumeNearestFirst) }
    }

    /// The topmost visible outline row id at deactivation (the scroll anchor).
    var resumeScrollAnchorRowID: String? {
        didSet { defaults.set(resumeScrollAnchorRowID, forKey: Key.resumeScrollAnchorRowID) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // NOTE: in an @Observable class these assignments DO fire didSet (macro-rewritten
        // computed properties) — `isBootstrapping` suppresses the cross-property couplings
        // until every stored value has been loaded.
        enabledMapAppIDs = defaults.stringArray(forKey: Key.enabledMapAppIDs) ?? []
        defaultMapAppID = defaults.string(forKey: Key.defaultMapAppID)
        clusterMapPins = defaults.bool(forKey: Key.clusterMapPins)
        syncEnabled = defaults.bool(forKey: Key.syncEnabled)
        entrySort = defaults.string(forKey: Key.entrySort)
            .flatMap(EntrySort.init(rawValue:)) ?? .dateDesc
        restoreSessionEnabled = defaults.object(forKey: Key.restoreSessionEnabled) as? Bool ?? true
        resumeEntryFolderName = defaults.string(forKey: Key.resumeEntryFolderName)
        resumeRoutes = defaults.data(forKey: Key.resumeRoutes)
        resumeSearchText = defaults.string(forKey: Key.resumeSearchText)
        resumeCollapsedFolderIDs = defaults.stringArray(forKey: Key.resumeCollapsedFolderIDs)
        resumeNearestFirst = defaults.bool(forKey: Key.resumeNearestFirst)
        resumeScrollAnchorRowID = defaults.string(forKey: Key.resumeScrollAnchorRowID)
        isBootstrapping = false
    }
}
```

Note: the old init comment claimed "Initial assignments do not trigger `didSet`" — that is wrong for `@Observable` classes (verified previously; see the regression test) and the replacement documents the correct behavior.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh -only-testing:PinfoldTests/SettingsResumeTests -only-testing:PinfoldTests/SettingsTests`
Expected: PASS (both suites — the old `SettingsTests` must still pass).

- [ ] **Step 5: Commit**

```bash
git add App/Model/AppSettings.swift AppTests/AppSettingsTests.swift
git commit -m "feat(app): persist session-restoration state in AppSettings

Claude-Session: https://claude.ai/code/session_01EYocFdaGHNVorJBtCaFNz9"
```

---

### Task 3: `MapCameraStore`

**Files:**
- Create: `App/Model/MapCameraStore.swift`
- Test: `AppTests/MapCameraStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct MapCameraState: Codable, Equatable { var latitude, longitude, distance, heading, pitch: Double }`
  - `final class MapCameraStore` with `init(defaults: UserDefaults = .standard)`, `func camera(forFolderName: String) -> MapCameraState?`, `func setCamera(_ camera: MapCameraState, forFolderName: String)`, `func pruneIfNeeded(keeping: Set<String>, cap: Int = 100)`

- [ ] **Step 1: Write the failing tests**

Create `AppTests/MapCameraStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Pinfold

/// Tests for `MapCameraStore` — the per-file remembered map camera (center/zoom/heading/
/// pitch), keyed by entry `storageFolderName`. Deliberately OUTSIDE the resume snapshot and
/// not gated by the restore toggle: it persists across sessions like the basemap style.
struct MapCameraStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "MapCameraStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let sample = MapCameraState(
        latitude: 48.85, longitude: 2.35, distance: 1200, heading: 90, pitch: 0
    )

    @Test func missingFolder_returnsNil() {
        #expect(MapCameraStore(defaults: makeDefaults()).camera(forFolderName: "nope") == nil)
    }

    @Test func camera_roundTripsPerFolder() {
        let defaults = makeDefaults()
        let store = MapCameraStore(defaults: defaults)
        store.setCamera(sample, forFolderName: "folder-a")

        // A fresh store on the same defaults sees it (persistence, not in-memory cache).
        #expect(MapCameraStore(defaults: defaults).camera(forFolderName: "folder-a") == sample)
        #expect(MapCameraStore(defaults: defaults).camera(forFolderName: "folder-b") == nil)
    }

    @Test func setCamera_overwrites() {
        let store = MapCameraStore(defaults: makeDefaults())
        store.setCamera(sample, forFolderName: "folder-a")
        let moved = MapCameraState(latitude: 1, longitude: 2, distance: 3, heading: 4, pitch: 5)
        store.setCamera(moved, forFolderName: "folder-a")
        #expect(store.camera(forFolderName: "folder-a") == moved)
    }

    @Test func corruptBlob_readsAsEmpty() {
        let defaults = makeDefaults()
        defaults.set(Data("garbage".utf8), forKey: "mapCameraStates")
        let store = MapCameraStore(defaults: defaults)
        #expect(store.camera(forFolderName: "folder-a") == nil)
        // And writing through the corrupt blob works (it is simply replaced).
        store.setCamera(sample, forFolderName: "folder-a")
        #expect(store.camera(forFolderName: "folder-a") == sample)
    }

    @Test func prune_belowCap_keepsStaleKeys() {
        let store = MapCameraStore(defaults: makeDefaults())
        store.setCamera(sample, forFolderName: "gone")
        store.pruneIfNeeded(keeping: ["still-here"], cap: 100)
        // Below the cap, stale entries are harmless bytes and are kept.
        #expect(store.camera(forFolderName: "gone") == sample)
    }

    @Test func prune_aboveCap_dropsOnlyAbsentKeys() {
        let store = MapCameraStore(defaults: makeDefaults())
        for index in 0 ..< 5 {
            store.setCamera(sample, forFolderName: "folder-\(index)")
        }
        store.pruneIfNeeded(keeping: ["folder-0", "folder-1"], cap: 3)
        #expect(store.camera(forFolderName: "folder-0") == sample)
        #expect(store.camera(forFolderName: "folder-1") == sample)
        #expect(store.camera(forFolderName: "folder-4") == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh -only-testing:PinfoldTests/MapCameraStoreTests`
Expected: BUILD FAILURE — `cannot find 'MapCameraState' in scope`.

- [ ] **Step 3: Write the implementation**

Create `App/Model/MapCameraStore.swift`:

```swift
import Foundation

// MARK: - MapCameraState

/// A serializable snapshot of an `MKMapCamera` — the four properties that fully describe
/// the embedded map's framing. Plain `Double`s (no MapKit types) so the store is testable
/// without a map view; `PlacemarkMapRepresentable` owns the conversion.
struct MapCameraState: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    /// `MKMapCamera.centerCoordinateDistance`, in meters.
    var distance: Double
    var heading: Double
    var pitch: Double
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh -only-testing:PinfoldTests/MapCameraStoreTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add App/Model/MapCameraStore.swift AppTests/MapCameraStoreTests.swift
git commit -m "feat(app): add per-file MapCameraStore

Claude-Session: https://claude.ai/code/session_01EYocFdaGHNVorJBtCaFNz9"
```

---

### Task 4: `RowFrameBox` (scroll-anchor geometry)

**Files:**
- Create: `App/Support/RowFrameBox.swift`
- Test: `AppTests/RowFrameBoxTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `final class RowFrameBox` with `var frames: [String: CGRect]`, `var listFrame: CGRect?`, `var restoredTopOffset: CGFloat?`, `func anchorRowID() -> String?`, `func reset()`
  - It is deliberately **not** `@Observable`: rows write frames every scroll frame, and those writes must not invalidate the view tree.

- [ ] **Step 1: Write the failing tests**

Create `AppTests/RowFrameBoxTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import Pinfold

/// Tests for `RowFrameBox.anchorRowID()` — pure geometry: pick the realized row whose top
/// is nearest the list's content top (offset by the calibrated restore landing position),
/// skipping rows scrolled fully above it.
struct RowFrameBoxTests {
    private func makeBox(listTop: CGFloat = 100) -> RowFrameBox {
        let box = RowFrameBox()
        box.listFrame = CGRect(x: 0, y: listTop, width: 400, height: 600)
        return box
    }

    @Test func noListFrame_returnsNil() {
        let box = RowFrameBox()
        box.frames["p0"] = CGRect(x: 0, y: 0, width: 400, height: 50)
        #expect(box.anchorRowID() == nil)
    }

    @Test func noRows_returnsNil() {
        #expect(makeBox().anchorRowID() == nil)
    }

    @Test func picksRowNearestListTop() {
        let box = makeBox(listTop: 100)
        box.frames["above"] = CGRect(x: 0, y: 0, width: 400, height: 50) // fully scrolled off
        box.frames["top"] = CGRect(x: 0, y: 95, width: 400, height: 50) // straddles the top
        box.frames["below"] = CGRect(x: 0, y: 145, width: 400, height: 50)
        #expect(box.anchorRowID() == "top")
    }

    @Test func fullyScrolledOffRows_areIgnored() {
        let box = makeBox(listTop: 100)
        box.frames["gone"] = CGRect(x: 0, y: 20, width: 400, height: 50) // maxY 70 < top
        box.frames["visible"] = CGRect(x: 0, y: 200, width: 400, height: 50)
        #expect(box.anchorRowID() == "visible")
    }

    @Test func calibrationOffset_shiftsReference() {
        let box = makeBox(listTop: 100)
        box.restoredTopOffset = 40 // restore landed rows at listTop + 40
        box.frames["a"] = CGRect(x: 0, y: 105, width: 400, height: 50)
        box.frames["b"] = CGRect(x: 0, y: 141, width: 400, height: 50) // nearest to 140
        #expect(box.anchorRowID() == "b")
    }

    @Test func reset_clearsFramesAndCalibration() {
        let box = makeBox()
        box.frames["a"] = .zero
        box.restoredTopOffset = 12
        box.reset()
        #expect(box.frames.isEmpty)
        #expect(box.restoredTopOffset == nil)
        #expect(box.anchorRowID() == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh -only-testing:PinfoldTests/RowFrameBoxTests`
Expected: BUILD FAILURE — `cannot find 'RowFrameBox' in scope`.

- [ ] **Step 3: Write the implementation**

Create `App/Support/RowFrameBox.swift`:

```swift
import CoreGraphics
import Foundation

/// Live geometry of the placemark list's realized rows, for scroll-anchor capture/restore.
///
/// Deliberately a plain (non-`@Observable`) class held in `@State`: rows write their frames
/// on every scroll frame via `onGeometryChange`, and those writes must NOT invalidate the
/// view tree. NOT the iOS 18 scroll-instrumentation APIs (`scrollPosition` /
/// `onScrollVisibilityChange`): those do not support `List` (UICollectionView-backed;
/// `ScrollView` only) and silently never fire — verified in a previous implementation
/// attempt that recorded nothing under real scrolling.
///
/// Rows remove themselves in `onDisappear` as `List` derealizes them, so `frames` only
/// holds (approximately) the realized rows — stale frames of far-offscreen rows cannot
/// masquerade as the anchor. All frames are in the GLOBAL coordinate space, compared
/// against the list's own global frame.
final class RowFrameBox {
    /// Row id (`PlacemarkOutline.Row.id`, a positional tree path) → last-known global frame.
    var frames: [String: CGRect] = [:]
    /// The `List`'s own global frame.
    var listFrame: CGRect?
    /// Where a successful scroll restore actually landed the anchor row's top, relative to
    /// the list's top (the list's content-top inset, e.g. under the large title). Recorded
    /// by the restore path and used to calibrate `anchorRowID()`'s reference line so
    /// save→restore round-trips don't creep by one row per cycle.
    var restoredTopOffset: CGFloat?

    /// The id of the row to anchor scroll restoration on: the realized row whose top is
    /// nearest the reference line (list top + calibration), excluding rows scrolled fully
    /// above it. `nil` when geometry hasn't been observed yet.
    func anchorRowID() -> String? {
        guard let listFrame else { return nil }
        let referenceY = listFrame.minY + (restoredTopOffset ?? 0)
        return frames
            .filter { $0.value.maxY > referenceY + 1 }
            .min { abs($0.value.minY - referenceY) < abs($1.value.minY - referenceY) }?
            .key
    }

    /// Clears everything (a different document's rows are unrelated geometry).
    func reset() {
        frames.removeAll()
        listFrame = nil
        restoredTopOffset = nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh -only-testing:PinfoldTests/RowFrameBoxTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add App/Support/RowFrameBox.swift AppTests/RowFrameBoxTests.swift
git commit -m "feat(app): add RowFrameBox scroll-anchor geometry

Claude-Session: https://claude.ai/code/session_01EYocFdaGHNVorJBtCaFNz9"
```

---

### Task 5: Value-based navigation refactor

Converts every push to `EntryRoute` values on a shared path, and unifies the deep-link plumbing into `RestoreBundle`. **No persistence yet** (Task 6). The app must behave identically to today after this task.

**Files:**
- Modify: `App/Intents/AppDependencies.swift` (NavigationRouter gains `path`)
- Modify: `App/Views/RootView.swift` (NavigationStack(path:), router injection, RestoreBundle hand-off)
- Modify: `App/Views/KMLDetailView.swift` (single destination table, value links, initialRestore)
- Modify: `App/Views/PlacemarkDetailView.swift` (Show on Map → path append)
- Modify: `App/Views/PlacemarkMapView.swift` (preview card → path append)

**Interfaces:**
- Consumes: `EntryRoute`, `RestoreBundle` (Task 1).
- Produces:
  - `NavigationRouter.path: [EntryRoute]`
  - `KMLDetailView(entry:initialRestore:onConsumeRestore:)` — replaces `initialPlacemarkKey`/`onConsumePlacemarkKey`
  - `NavigationRouter` reachable via `@Environment(NavigationRouter.self)` everywhere the service bundle is injected

- [ ] **Step 1: Add the path to `NavigationRouter`**

In `App/Intents/AppDependencies.swift`, replace the `NavigationRouter` class with:

```swift
/// A one-shot deep-link sink for routing into the catalogue from outside the view tree (App
/// Intents, and any future programmatic navigation) — and the owner of the detail column's
/// navigation path.
///
/// `RootView` observes `pendingEntryFolderName` via `.onChange`: when an intent sets it, the
/// root resolves the folder name to an active entry and selects it (reusing the existing
/// selection plumbing). Consume-once: `RootView` clears it back to `nil` after handling, so the
/// same folder name set twice still re-fires the `.onChange`.
///
/// `path` backs `RootView`'s detail `NavigationStack(path:)`. It lives here — not as view
/// `@State` — so any view inside the open file (list rows aside, which use
/// `NavigationLink(value:)`) can push by appending a route, and so session restore can set
/// the whole stack in one assignment. Routes are per-document: `RootView` clears the path
/// whenever the selected entry changes.
@MainActor @Observable
final class NavigationRouter {
    /// The folder name of an entry an external trigger wants opened, or `nil` when idle.
    var pendingEntryFolderName: String?

    /// The detail column's navigation stack, as durable route values.
    var path: [EntryRoute] = []

    /// Requests that the entry with `folderName` be opened. Observed by `RootView`.
    func openEntry(folderName: String) {
        pendingEntryFolderName = folderName
    }
}
```

- [ ] **Step 2: Rewire `RootView`**

In `App/Views/RootView.swift`:

2a. Add state for the pending restore bundle, after the `pendingPlacemarkKey` declaration:

```swift
    /// A one-shot session-restore payload built by `restoreSessionIfNeeded()` (Task 6) and
    /// handed to `KMLDetailView` when the restored entry's view is created. `entryFolderName`
    /// guards the hand-off: only the matching entry receives it (a user could out-race a slow
    /// parse by selecting another file). Deep links win: `activeRestore` prefers
    /// `pendingPlacemarkKey`, and every deep-link site clears this.
    @State private var pendingRestore: RestoreBundle?
```

2b. Add the bundle-priority helper next to `selectedEntry`:

```swift
    /// The one-shot bundle for the CURRENT detail view, or nil. A live deep link (Spotlight,
    /// App Intent, a Places/favorites hit — all funnelled through `pendingPlacemarkKey`)
    /// outranks session restore; a restore bundle is only handed to the entry it was saved
    /// for (folder-name match).
    private var activeRestore: RestoreBundle? {
        if let pendingPlacemarkKey {
            return RestoreBundle(routes: [.placemark(stableKey: pendingPlacemarkKey)])
        }
        if let pendingRestore, pendingRestore.entryFolderName == selectedEntry?.storageFolderName {
            return pendingRestore
        }
        return nil
    }
```

2c. Replace the detail column's `NavigationStack { ... }` block (keeping the trailing `.modifier(AppEnvironmentBundle(...))` — but see 2e for its new `router:` parameter):

```swift
            @Bindable var router = router
            NavigationStack(path: $router.path) {
                if let selectedEntry {
                    KMLDetailView(
                        entry: selectedEntry,
                        initialRestore: activeRestore,
                        // Consumed once by the detail view; clearing here ensures a later
                        // normal selection of the same file doesn't re-push.
                        onConsumeRestore: {
                            pendingPlacemarkKey = nil
                            pendingRestore = nil
                        }
                    )
                    .id(selectedEntry.id)
                } else {
                    ContentUnavailableView(
                        "No File Selected",
                        systemImage: "sidebar.leading",
                        description: Text("Select a file from the catalogue to view its placemarks.")
                    )
                }
            }
```

(`@Bindable var router = router` is a body-local statement, the same pattern `SettingsView` uses for `settings`. Keep the existing comment block above the stack about why the detail column owns its own NavigationStack.)

2d. Clear the path when the selection changes. Add alongside the other `.onChange` modifiers on the `NavigationSplitView`:

```swift
        // Routes are per-document: switching (or clearing) the selected file invalidates
        // the stack, matching the pre-refactor behavior where the pushed screens reset.
        .onChange(of: selectedEntryID) { _, _ in
            router.path = []
        }
```

2e. Extend `AppEnvironmentBundle` (bottom of the file) with the router, so every view in both injection sites can append routes:

```swift
private struct AppEnvironmentBundle: ViewModifier {
    let catalog: Catalog
    let settings: AppSettings
    let mapAppService: MapAppService
    let migrationAlert: MigrationAlertState
    let importFailureLog: ImportFailureLog
    let resourceCache: ResourceCache
    let router: NavigationRouter

    func body(content: Content) -> some View {
        content
            .environment(catalog)
            .environment(settings)
            .environment(mapAppService)
            .environment(migrationAlert)
            .environment(importFailureLog)
            .environment(router)
            .environment(\.resourceCache, resourceCache)
            .environment(\.storageLocations, catalog.storage)
    }
}
```

Update BOTH `.modifier(AppEnvironmentBundle(...))` call sites to pass `router: router`.

2f. Deep-link sites clear any pending restore (a stale bundle must never leak into a deep-linked file). In `openEntry(folderName:)` and `handleSpotlightActivity(_:)`, add `pendingRestore = nil` beside the existing `pendingPlacemarkKey` writes:

```swift
    private func openEntry(folderName: String) {
        guard let entry = catalog.active.first(where: { $0.storageFolderName == folderName }) else {
            Self.routingLogger.info(
                "Deep link to missing/trashed entry '\(folderName, privacy: .public)' — ignored."
            )
            return
        }
        pendingPlacemarkKey = nil
        pendingRestore = nil
        selectedEntryID = entry.id
    }
```

and in `handleSpotlightActivity`, before `selectedEntryID = entry.id`:

```swift
        pendingPlacemarkKey = parsed.placemarkKey
        pendingRestore = nil
        selectedEntryID = entry.id
```

- [ ] **Step 3: Refactor `KMLDetailView`**

3a. Replace the `initialPlacemarkKey` / `onConsumePlacemarkKey` properties with:

```swift
    /// A one-shot navigation payload: routes to push (and, for session restore, the
    /// transient list state to seed) once the document is parsed. Supplied by `RootView` for
    /// deep links (a single `.placemark` route) and session restore (the saved stack).
    /// `nil` for a normal selection. Consumed once via `onConsumeRestore` (then the owner
    /// clears its one-shot source so re-selecting the file normally doesn't re-push).
    var initialRestore: RestoreBundle?

    /// Called once after `initialRestore` has been consumed, so the owner can clear its
    /// one-shot source. Defaults to a no-op for callers that don't plumb it.
    var onConsumeRestore: () -> Void = {}
```

3b. Add the router to the environment section (optional, like the other services that can be absent in previews):

```swift
    @Environment(NavigationRouter.self) private var router: NavigationRouter?
```

3c. Delete the `deepLinkTarget` state property and the whole `PlacemarkRoute` struct.

3d. In the load `.task(id: entry.id)`, replace the reset line `deepLinkTarget = nil` with nothing (the path is owned by the router and cleared by `RootView` on selection change), and replace the post-`loadDocument()` deep-link block:

```swift
            // Old block to REMOVE:
            if let initialPlacemarkKey, !initialPlacemarkKey.isEmpty, let document,
               let match = document.root.firstPlacemark(withStableKey: initialPlacemarkKey)
            {
                deepLinkTarget = PlacemarkRoute(placemark: match)
            }
            if initialPlacemarkKey != nil {
                onConsumePlacemarkKey()
            }
```

with:

```swift
            // One-shot navigation payload: seed the transient list state (session restore
            // only — a deep link must not clobber it), validate the saved routes against the
            // freshly parsed document, and set the stack. Seeding happens BEFORE the
            // immediate outline trigger fires, so the first outline is built once, in the
            // right shape. Consume whether or not routes resolved, so a stale payload
            // doesn't leak into another file.
            applyInitialRestore()
```

and add the method after `loadDocument()`:

```swift
    /// Applies the one-shot `initialRestore` payload against the freshly loaded document.
    /// See the load `.task` for sequencing; kept out of the closure to keep its SIL small.
    private func applyInitialRestore() {
        guard let initialRestore, let document else {
            if initialRestore != nil { onConsumeRestore() }
            return
        }
        if initialRestore.entryFolderName != nil {
            // Session restore: seed the saved transient state. (Deep-link bundles have a
            // nil folder name and leave the fresh defaults alone.)
            searchText = initialRestore.searchText
            collapsedFolderIDs = initialRestore.collapsedFolderIDs
            nearestFirst = initialRestore.nearestFirst
            pendingScrollRowID = initialRestore.scrollAnchorRowID
        }
        let valid = EntryRoute.validatedForRestore(initialRestore.routes) {
            document.root.firstPlacemark(withStableKey: $0) != nil
        }
        router?.path = valid
        onConsumeRestore()
    }
```

`pendingScrollRowID` doesn't exist until Task 7 — for THIS task, declare it already (it is inert until Task 7 wires it up):

```swift
    /// The outline row id to scroll to once rows are built — a one-shot from session
    /// restore, consumed by the verified-retry scroll task (see `applyPendingScroll`).
    @State private var pendingScrollRowID: String?
```

3e. Replace the second consume path `.onChange(of: initialPlacemarkKey)` with:

```swift
        // Second consume path: a deep link into the file that is ALREADY open. The view
        // keeps its identity (`.id(entry.id)` unchanged) so the load `.task` does NOT
        // refire — but SwiftUI re-evaluates the body with the new `initialRestore` param,
        // and this `.onChange` observes the nil→bundle transition and pushes against the
        // already-loaded document. Routes only — never the transient list state (this path
        // is only reachable for deep links; restore bundles arrive with a fresh identity).
        // The `let document` guard covers the mid-load race: not ready yet → no-op WITHOUT
        // consuming; the in-flight load task applies it instead.
        .onChange(of: initialRestore) { _, newValue in
            guard let newValue, !newValue.routes.isEmpty, let document else { return }
            let valid = EntryRoute.validatedForRestore(newValue.routes) {
                document.root.firstPlacemark(withStableKey: $0) != nil
            }
            guard !valid.isEmpty else { return }
            router?.path.append(contentsOf: valid)
            onConsumeRestore()
        }
```

3f. Replace `.navigationDestination(item: $deepLinkTarget) { route in ... }` with the single destination table:

```swift
        // THE destination table: every EntryRoute pushed anywhere in this file's stack —
        // list rows, the toolbar map, the POI page's "Show on Map", the map's preview card,
        // deep links, session restore — resolves here, the one place that has the parsed
        // `document`, `outline`, and `annotations`. Registered on the stack root's content,
        // so pushed views need no registration of their own. Re-injecting `annotations` is
        // needed ONCE here (a pushed destination resolves its environment from the stack
        // root, not from this view's body-level injection below).
        .navigationDestination(for: EntryRoute.self) { route in
            destinationView(for: route)
        }
```

and add the builder method (near `contentList`):

```swift
    /// Resolves a pushed route into its screen. A `.placemark` whose stableKey no longer
    /// resolves renders empty — unreachable in practice (routes are validated before
    /// pushing) but a safe no-op if the document changes under an open stack.
    @ViewBuilder
    private func destinationView(for route: EntryRoute) -> some View {
        if let document {
            switch route {
            case let .placemark(stableKey):
                if let match = document.root.firstPlacemark(withStableKey: stableKey) {
                    PlacemarkDetailView(placemark: match, document: document, entry: entry)
                        .environment(annotations)
                }
            case let .map(focusKey):
                PlacemarkMapView(
                    // "Show on Map" (focusKey != nil) plots EVERY coordinate-bearing
                    // placemark (the POI page has no search context); the toolbar/restored
                    // map (focusKey == nil) plots the live filtered outline — both exactly
                    // as before the route refactor.
                    placemarks: focusKey != nil
                        ? document.root.allPlacemarks.filter { $0.coordinate != nil }
                        : (outline?.mappablePlacemarks ?? []),
                    document: document,
                    entry: entry,
                    initialFocusKey: focusKey
                )
                .environment(annotations)
            }
        }
    }
```

3g. Replace the toolbar map `NavigationLink { ... } label: { ... }` with a value link:

```swift
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: EntryRoute.map(focusKey: nil)) {
                    Image(systemName: "map")
                }
                .accessibilityLabel("Map")
                .disabled((outline?.mappablePlacemarks.isEmpty ?? true))
            }
```

3h. In `placemarkLink`, replace the `NavigationLink(destination:)` (and its `.environment(annotations)` re-injection, which the destination table now owns) with a value link — the `.swipeActions`/`.contextMenu` chains stay untouched:

```swift
        NavigationLink(value: EntryRoute.placemark(stableKey: placemark.stableKey)) {
            PlacemarkRow(
                placemark: placemark,
                document: document,
                entry: entry,
                distance: PlacemarkDistance.format(from: location, to: placemark.coordinate)
            )
        }
```

Known accepted edge (document it in the comment above `placemarkLink`): two occurrences of the same POI share a `stableKey` (it hashes `name|lat|lon`), so both rows now push the FIRST occurrence's page — the same first-match semantics every existing deep link (Spotlight, favorites) already has.

3i. Update the doc comment of the `body`-level `.environment(annotations)` at the end of `body`: the per-push-site re-injection list it describes ("the list row, the deep-link destination, the toolbar map, and the POI page's Show on Map") is obsolete — the destination table re-injects once. Keep the injection itself (this view's own body still reads it).

- [ ] **Step 4: Refactor `PlacemarkDetailView` ("Show on Map")**

4a. Add the router environment beside the other `@Environment` properties:

```swift
    @Environment(NavigationRouter.self) private var router: NavigationRouter?
```

4b. Delete the `showOnMap` state property and the whole `.navigationDestination(isPresented: $showOnMap) { ... }` modifier.

4c. In `toolbarMenu`, replace the `showOnMap = true` button action:

```swift
                    Button {
                        router?.path.append(.map(focusKey: placemark.stableKey))
                    } label: {
                        Label("Show on Map", systemImage: "map")
                    }
```

- [ ] **Step 5: Refactor `PlacemarkMapView` (preview card push)**

5a. Add the router environment beside the others:

```swift
    @Environment(NavigationRouter.self) private var router: NavigationRouter?
```

5b. Delete the `placemarkToOpenKey` state property and the whole `.navigationDestination(item: $placemarkToOpenKey) { ... }` modifier.

5c. Replace the preview card's `onOpen` closure:

```swift
                PlacemarkPreviewCard(placemark: placemark, document: document, entry: entry) {
                    router?.path.append(.placemark(stableKey: placemark.stableKey))
                }
```

- [ ] **Step 6: Build and run the full test suite**

Run: `scripts/build.sh && scripts/test.sh`
Expected: build succeeds; all suites pass (nothing in `AppTests` exercises the removed one-shot API — if a compile error reveals a forgotten call site, fix it the same way as `RootView`).

Run: `swiftlint lint | grep -c "error:" || true`
Expected: `0`.

- [ ] **Step 7: Manual smoke test (behavior must be UNCHANGED)**

Build and install on the simulator, then verify by hand: open a file → tap a placemark row (POI page opens) → back → toolbar map (map opens, fits pins) → tap a pin → preview card → POI page pushes → its "Show on Map" pushes a focused map → back-chain pops cleanly through every level. On iPad width (or the Mac run destination) verify a favorites hit still deep-links to the POI page.

- [ ] **Step 8: Commit**

```bash
git add -A App/
git commit -m "refactor(app): value-based navigation with Codable EntryRoute path

Claude-Session: https://claude.ai/code/session_01EYocFdaGHNVorJBtCaFNz9"
```

---

### Task 6: Save + restore wiring

**Files:**
- Modify: `App/Views/RootView.swift` (scenePhase save, selection recording, `restoreSessionIfNeeded()`)
- Modify: `App/Views/KMLDetailView.swift` (transient-slice save on deactivation)
- Test: `AppTests/RestoreResolutionTests.swift` (create)

**Interfaces:**
- Consumes: `AppSettings` resume keys (Task 2), `EntryRoute.encodeForResume/decodeForResume` (Task 1), `RestoreBundle` (Task 1), `NavigationRouter.path` (Task 5).
- Produces: the full save/restore loop, minus scroll (Task 7) and camera (Task 8).

- [ ] **Step 1: Write the failing resolution test**

Create `AppTests/RestoreResolutionTests.swift`:

```swift
import Foundation
import Testing
@testable import Pinfold

/// Integration test for the restore guard's entry resolution: the saved folder name must
/// resolve only against ACTIVE entries (a trashed or deleted entry silently lands the user
/// on the catalogue). Uses the temporary-root pattern so no real storage is touched.
@Suite(.serialized) @MainActor struct RestoreResolutionTests {
    @Test func folderName_resolvesOnlyActiveEntries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreResolutionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageLocations(root: root)
        let catalog = Catalog(storage: storage, cache: ResourceCache())

        // Import one entry through the real pipeline, then reload the catalogue from disk.
        let kml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document>
        <Placemark><name>Spot</name><Point><coordinates>2.0,48.0,0</coordinates></Point></Placemark>
        </Document></kml>
        """
        let result = try ImportService.prepare(data: Data(kml.utf8), sourceFilename: "restore.kml")
        try ImportService.commit(result, storage: storage, cache: ResourceCache())
        await catalog.reload()

        let entry = try #require(catalog.active.first)
        let folderName = entry.storageFolderName

        // Present + active → resolves.
        #expect(catalog.active.first { $0.storageFolderName == folderName } != nil)

        // Trashed → no longer resolves via `active`.
        await catalog.moveToTrash(entry)
        #expect(catalog.active.first { $0.storageFolderName == folderName } == nil)

        // Missing entirely → no longer resolves.
        #expect(catalog.active.first { $0.storageFolderName == "no-such-folder" } == nil)
    }
}
```

- [ ] **Step 2: Run it to verify state**

Run: `scripts/test.sh -only-testing:PinfoldTests/RestoreResolutionTests`
Expected: PASS immediately if the API names matched (this test pins existing behavior the restore guard depends on — it is a characterization test, not TDD of new code). If it fails to compile, fix the API call per the note above.

- [ ] **Step 3: Wire saving + restoring in `RootView`**

3a. Replace the existing scenePhase `.onChange` with a two-way switch:

```swift
        // Save the resume snapshot on the way OUT (`.inactive` is always passed through
        // before backgrounding — and before iOS's snapshot passes — and also fires on the
        // app-switcher path, covering swipe-kill). Pick up synced/shared files on the way IN.
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive:
                saveResumeState()
            case .active:
                Task { await drainInbox(); await drainDocumentsInbox(); await catalog.reload() }
            default:
                break
            }
        }
```

3b. Extend the selection `.onChange` from Task 5 (step 2d) to also record the folder immediately — crash-safety: a hard crash later in the session loses at most the in-file details, never the file:

```swift
        .onChange(of: selectedEntryID) { _, _ in
            router.path = []
            if settings.restoreSessionEnabled {
                settings.resumeEntryFolderName = selectedEntry?.storageFolderName
            }
        }
```

3c. Add the save/restore methods (after `bootstrap()`):

```swift
    /// Writes the selection + route-stack half of the resume snapshot. `KMLDetailView`
    /// owns the other half (transient list state + scroll anchor — only it can read live
    /// row geometry); both fire on the same `.inactive` transition, and the same-folder
    /// preserve rule in `AppSettings` makes their order irrelevant.
    private func saveResumeState() {
        guard settings.restoreSessionEnabled else { return }
        settings.resumeEntryFolderName = selectedEntry?.storageFolderName
        settings.resumeRoutes = EntryRoute.encodeForResume(router.path)
    }

    /// Rebuilds the last session's selection at launch. Restore only when nothing else has
    /// routed yet — a live deep link (Spotlight tap, App Intent, "Open in Pinfold") that
    /// already drove a selection or set a pending key wins over restore. A saved folder
    /// that no longer resolves (deleted, trashed, storage root switched) clears the stale
    /// state and lands on the catalogue — silent, like every deep-link miss.
    private func restoreSessionIfNeeded() {
        guard settings.restoreSessionEnabled,
              selectedEntryID == nil,
              pendingPlacemarkKey == nil,
              let folderName = settings.resumeEntryFolderName
        else { return }
        guard let entry = catalog.active.first(where: { $0.storageFolderName == folderName }) else {
            settings.resumeEntryFolderName = nil
            return
        }
        pendingRestore = RestoreBundle(
            entryFolderName: folderName,
            routes: EntryRoute.decodeForResume(settings.resumeRoutes),
            searchText: settings.resumeSearchText ?? "",
            collapsedFolderIDs: Set(settings.resumeCollapsedFolderIDs ?? []),
            nearestFirst: settings.resumeNearestFirst,
            scrollAnchorRowID: settings.resumeScrollAnchorRowID
        )
        selectedEntryID = entry.id
    }
```

3d. Call it at the end of `bootstrap()`:

```swift
    private func bootstrap() async {
        AppDependencies.shared.catalog = catalog
        AppDependencies.shared.router = router
        await applyStorage(migrate: false)
        await drainInbox()
        await drainDocumentsInbox()
        await catalog.reload()
        restoreSessionIfNeeded()
    }
```

3e. Suppress restore for URL-driven launches. "Open in Pinfold" imports a file but does
NOT drive a selection, so the selection-based guards in `restoreSessionIfNeeded()` can't
see it — without this, a cold launch by opening a KML would restore the *previous* file on
top of the import. Add the flag beside `pendingRestore`:

```swift
    /// Set when the app is (re)activated by a URL ("Open in Pinfold" / share-extension
    /// launch). An import doesn't drive a selection, so the selection-based restore guards
    /// can't see it — this flag keeps session restore from reopening the previous file on
    /// top of a fresh import.
    @State private var suppressRestore = false
```

set it first thing in `handleOpenURL(_:)`:

```swift
    private func handleOpenURL(_ url: URL) async {
        suppressRestore = true
        pendingRestore = nil
        if url.isFileURL {
            await importFile(at: url)
        }
        await drainDocumentsInbox()
        await drainInbox()
    }
```

and add `!suppressRestore` to `restoreSessionIfNeeded()`'s guard:

```swift
        guard settings.restoreSessionEnabled,
              !suppressRestore,
              selectedEntryID == nil,
              pendingPlacemarkKey == nil,
              let folderName = settings.resumeEntryFolderName
        else { return }
```

(`bootstrap()`'s `.task` and `onOpenURL` ordering isn't guaranteed; if restore wins the
race the deep-link-style clearing still limits the damage, and the imported file is at the
top of the catalogue either way.)

- [ ] **Step 4: Save the transient slice in `KMLDetailView`**

4a. Add the environment reads beside the existing `@Environment(\.storageLocations)`:

```swift
    @Environment(AppSettings.self) private var settings: AppSettings?
    @Environment(\.scenePhase) private var scenePhase
```

(`AppSettings` optional — same absent-in-previews pattern as the other services.)

4b. Add the save hook to `body`'s modifier chain (next to the other `.onChange`s):

```swift
        // The per-file half of the resume snapshot (RootView writes selection + routes on
        // the same transition). `.inactive` always precedes backgrounding, BEFORE iOS's
        // snapshot passes can re-lay the list out under us.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .inactive else { return }
            saveResumeSlice()
        }
```

4c. Add the method (near `applyInitialRestore()`):

```swift
    /// Writes the transient list state + scroll anchor to the resume slice. The scroll
    /// anchor is computed from live row geometry (Task 7 wires `rowFrames`; until then
    /// `anchorRowID()` returns nil and only the transient state is saved).
    private func saveResumeSlice() {
        guard let settings, settings.restoreSessionEnabled, document != nil else { return }
        settings.resumeSearchText = searchText
        settings.resumeCollapsedFolderIDs = Array(collapsedFolderIDs)
        settings.resumeNearestFirst = nearestFirst
        settings.resumeScrollAnchorRowID = rowFrames.anchorRowID()
    }
```

`rowFrames` doesn't exist until Task 7 — declare it NOW (inert until then) with the other `@State`:

```swift
    /// Live row geometry for scroll-anchor capture/restore. A plain class (not @Observable):
    /// per-frame writes must not invalidate the view tree. See `RowFrameBox`.
    @State private var rowFrames = RowFrameBox()
```

- [ ] **Step 5: Build + full tests**

Run: `scripts/build.sh && scripts/test.sh`
Expected: build succeeds, all suites pass. `swiftlint lint` still 0 errors.

- [ ] **Step 6: Manual verification of the core loop**

On the simulator (`scripts/build.sh`, install, launch — bundle id `tech.inkhorn.pinfold`):
1. Open a file, push a POI page. Home-swipe to background (fires `.inactive`), then `xcrun simctl terminate booted tech.inkhorn.pinfold`. Relaunch → the same file opens with the POI page pushed; back pops to its list.
2. From the POI page push "Show on Map", background, terminate, relaunch → file → POI → map restores (three-deep literal stack).
3. Go back to the catalogue (deselect), background, terminate, relaunch → lands on the catalogue.
4. Type a search query + collapse a folder, background, terminate, relaunch → query and collapse state restored.

- [ ] **Step 7: Commit**

```bash
git add -A App/ AppTests/
git commit -m "feat(app): save and restore session (selection, route stack, list state)

Claude-Session: https://claude.ai/code/session_01EYocFdaGHNVorJBtCaFNz9"
```

---

### Task 7: List scroll capture + restore

**Files:**
- Modify: `App/Views/KMLDetailView.swift` (geometry instrumentation, ScrollViewReader, verified-retry restore)

**Interfaces:**
- Consumes: `RowFrameBox` (Task 4), `pendingScrollRowID` + `rowFrames` state (declared in Tasks 5/6).
- Produces: working scroll persistence; no new public API.

- [ ] **Step 1: Instrument rows and the list**

1a. In `contentList(_:)`, wrap the `List` in a `ScrollViewReader` and instrument the list frame + restore task. The existing `List { ... }.listStyle(.insetGrouped)` becomes:

```swift
        return ScrollViewReader { proxy in
            List {
                searchSection
                if let outline {
                    if outline.rows.isEmpty, !query.isEmpty {
                        Section {
                            Text("No placemarks match \u{201C}\(query)\u{201D}.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    } else {
                        Section {
                            ForEach(outline.rows) { row in
                                outlineRow(row, document: document, location: location)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                rowFrames.listFrame = frame
            }
            // Appearance-bound AND change-bound: fires on appear (covers pop-back — the
            // "one more attempt when the list becomes visible again" case) and whenever the
            // outline is rebuilt (covers the fast-launch race where rows land before the
            // List attaches, and the nearest-first re-sort when the location fix arrives).
            .task(id: outline?.rows.count) {
                await applyPendingScroll(using: proxy)
            }
        }
```

(`return` is needed because the function body has `let` statements — it already does.)

1b. In `outlineRow(_:document:location:)`, add geometry tracking to BOTH row kinds by appending to each branch's modifier chain (after `.listRowInsets(...)`):

```swift
        case let .folder(name, id):
            folderRow(name: name, id: id)
                .listRowInsets(EdgeInsets(top: 6, leading: leadingInset(row.depth), bottom: 6, trailing: 16))
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    rowFrames.frames[row.id] = frame
                }
                .onDisappear { rowFrames.frames[row.id] = nil }
        case let .placemark(placemark):
            placemarkLink(placemark, document: document, location: location)
                .listRowInsets(EdgeInsets(top: 6, leading: leadingInset(row.depth), bottom: 6, trailing: 16))
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    rowFrames.frames[row.id] = frame
                }
                .onDisappear { rowFrames.frames[row.id] = nil }
```

(`onDisappear` keeps the box ≈ realized rows only, so a stale far-offscreen frame can't masquerade as the save-time anchor. `ForEach(outline.rows)` already ids rows by `row.id`, which is what `proxy.scrollTo` targets.)

1c. In the load `.task(id: entry.id)` reset block (the lines that nil out `document`/`outline`/etc. for a genuinely new entry), add:

```swift
            pendingScrollRowID = nil
            rowFrames.reset()
```

- [ ] **Step 2: Implement the verified-retry restore**

Add near `applyInitialRestore()`:

```swift
    /// Applies the one-shot scroll anchor with a verified retry. `ScrollViewReader
    /// .scrollTo` right after a `List`'s data lands is flaky (the collection view may not
    /// have realized the target yet), so the target row's live geometry is checked and the
    /// scroll re-issued — bounded — until it took. The successful landing offset is stored
    /// in `rowFrames.restoredTopOffset` to calibrate the save-side anchor reference.
    ///
    /// An anchor that doesn't resolve in the current outline is dropped — EXCEPT while a
    /// nearest-first restore is still waiting for its location fix (the anchor was recorded
    /// against the flat nearest outline, whose row ids only exist after the re-sort; the
    /// outline rebuild on fix arrival re-fires this task via its `rows.count` id).
    private func applyPendingScroll(using proxy: ScrollViewProxy) async {
        guard let target = pendingScrollRowID, let outline else { return }
        guard outline.rows.contains(where: { $0.id == target }) else {
            if !(nearestFirst && locationAuth.lastLocation == nil) {
                pendingScrollRowID = nil
            }
            return
        }
        for _ in 0 ..< 8 {
            proxy.scrollTo(target, anchor: .top)
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            guard let frame = rowFrames.frames[target],
                  let listTop = rowFrames.listFrame?.minY else { continue }
            let offset = frame.minY - listTop
            // Settled with the row's top in the list's top region → done. The window
            // tolerates the inset-grouped content-top padding; the exact landing offset is
            // recorded so the save side anchors against the same reference line.
            if offset >= -4, offset < 120 {
                rowFrames.restoredTopOffset = offset
                pendingScrollRowID = nil
                return
            }
        }
    }
```

- [ ] **Step 3: Build + full tests + lint**

Run: `scripts/build.sh && scripts/test.sh`
Expected: green. `swiftlint lint`: 0 errors.

- [ ] **Step 4: Manual verification**

On the simulator with a large fixture (import a KML with 100+ placemarks — `AppTests/Fixtures/` has samples; add one via the Files app or drag onto the simulator):
1. Open the file, scroll deep into the list, background, terminate, relaunch → the list restores to the same topmost row (±1 row is the documented approximation).
2. Scroll, push a POI page, background, terminate, relaunch → POI page restores; pop → the list underneath is at (or near) the saved position — if the covered-scroll attempt failed, the pop itself retriggers the task and lands it.
3. Switch to nearest-first sort (grant location; the simulator's Features → Location → Apple sets a fix), scroll, kill, relaunch → after the fix arrives the flat list re-sorts and the anchor lands.

- [ ] **Step 5: Commit**

```bash
git add App/Views/KMLDetailView.swift
git commit -m "feat(app): restore placemark-list scroll position across launches

Claude-Session: https://claude.ai/code/session_01EYocFdaGHNVorJBtCaFNz9"
```

---

### Task 8: Per-file map camera

**Files:**
- Modify: `App/Views/PlacemarkMapRepresentable.swift` (apply/save camera)
- Modify: `App/Views/PlacemarkMapSupport.swift` (fit-all button in the control column)
- Modify: `App/Views/RootView.swift` (prune at bootstrap)

**Interfaces:**
- Consumes: `MapCameraStore` / `MapCameraState` (Task 3).
- Produces: camera persistence per `entry.storageFolderName`; a fit-all control; no new public API beyond `Coordinator.fitAllPins()`.

- [ ] **Step 1: Apply the saved camera on first layout**

In `App/Views/PlacemarkMapRepresentable.swift`:

1a. Add a store property after `static let styleDefaultsKey`:

```swift
    /// Per-file remembered camera. Stateless wrapper over UserDefaults, so constructing it
    /// per representable value is free.
    let cameraStore = MapCameraStore()
```

1b. Add two flags to `Coordinator` (near `lastShowsUserLocation`):

```swift
        /// Set once the first-layout framing (focus / saved camera / fit-all) has been
        /// applied; region changes before that are layout noise and must not be saved.
        var didInitialFrame = false
        /// One-shot suppression for the region-settle callback of a programmatic framing
        /// (initial framing, reconcile re-fit) so it doesn't overwrite the saved camera.
        /// The fit-all BUTTON deliberately does not set it: its settle callback saving the
        /// fit-all framing is what makes the button a natural "reset".
        var suppressCameraSave = false
```

1c. Replace the `mapView.onFirstLayout` closure in `makeUIView` — priority is **focus deep link → saved camera → fit all pins** (spec):

```swift
        let coordinates = placemarks.compactMap(\.coordinate)
        let focusKey = initialFocusKey
        let savedCamera = cameraStore.camera(forFolderName: entry.storageFolderName)
        mapView.onFirstLayout = { [weak mapView, weak coordinator = context.coordinator] in
            guard let mapView, let coordinator else { return }
            coordinator.suppressCameraSave = true
            // Initial-focus deep link ("Show on Embedded Map"): if the carried key resolves
            // to a realized pin, zoom to it and select it (surfacing its preview card).
            // Otherwise a remembered per-file camera wins over the fit-all default.
            if let focusKey, let annotation = coordinator.annotationsByKey[focusKey] {
                Self.focus(on: annotation, in: mapView)
            } else if let savedCamera {
                Self.apply(savedCamera, to: mapView)
            } else {
                Self.fit(coordinates: coordinates, overlays: overlays, in: mapView, animated: false)
            }
            coordinator.didInitialFrame = true
        }
```

1d. Add the conversion helpers next to `focus(on:in:)`:

```swift
    /// Applies a persisted camera, unanimated (this is the initial framing).
    static func apply(_ state: MapCameraState, to mapView: MKMapView) {
        let camera = MKMapCamera(
            lookingAtCenter: CLLocationCoordinate2D(latitude: state.latitude, longitude: state.longitude),
            fromDistance: state.distance,
            pitch: CGFloat(state.pitch),
            heading: state.heading
        )
        mapView.setCamera(camera, animated: false)
    }

    /// Snapshots the map's current camera for persistence.
    static func cameraState(of mapView: MKMapView) -> MapCameraState {
        let camera = mapView.camera
        return MapCameraState(
            latitude: camera.centerCoordinate.latitude,
            longitude: camera.centerCoordinate.longitude,
            distance: camera.centerCoordinateDistance,
            heading: camera.heading,
            pitch: Double(camera.pitch)
        )
    }
```

1e. In `updateUIView`, suppress the save for the reconcile re-fit — immediately before the existing `Self.fit(...)` call at the end of the `desiredKeys != coordinator.lastDesiredKeys` block:

```swift
            // Re-fit to the new pin + overlay set (mirrors the first-layout fit). It is
            // programmatic: its settle callback must not overwrite the remembered camera.
            coordinator.suppressCameraSave = true
            let allOverlays = coordinator.overlaysByKey.values.flatMap(\.self)
            Self.fit(
                coordinates: placemarks.compactMap(\.coordinate),
                overlays: allOverlays, in: mapView, animated: true
            )
```

- [ ] **Step 2: Save on gesture settle**

Add the delegate method to `Coordinator` (a good spot: after the basemap-style section):

```swift
        // MARK: Camera persistence

        /// Fires once per settled gesture or animation — the per-file camera save point.
        /// User-tracking pans settle through here too and are saved deliberately: "where
        /// the map was following me" IS where the user was.
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated _: Bool) {
            if suppressCameraSave {
                suppressCameraSave = false
                return
            }
            guard didInitialFrame else { return }
            parent.cameraStore.setCamera(
                PlacemarkMapRepresentable.cameraState(of: mapView),
                forFolderName: parent.entry.storageFolderName
            )
        }
```

- [ ] **Step 3: Fit-all button in the control column**

In `App/Views/PlacemarkMapSupport.swift`:

3a. Add the action to the coordinator — in `PlacemarkMapRepresentable.swift`, inside `Coordinator` (after `selectStyle`):

```swift
        /// Fits all pins + overlays (the pre-camera-persistence default framing). Wired to
        /// the control column's fit-all button. Deliberately does NOT suppress the settle
        /// save: the resulting framing is persisted, making this the "reset" for the
        /// remembered camera.
        func fitAllPins() {
            guard let mapView else { return }
            let overlays = overlaysByKey.values.flatMap(\.self)
            PlacemarkMapRepresentable.fit(
                coordinates: parent.placemarks.compactMap(\.coordinate),
                overlays: overlays, in: mapView, animated: true
            )
        }
```

3b. In `addControls(to:coordinator:)`, add a fit-all button between the style and tracking containers. Insert after the `styleContainer` constraint block:

```swift
        // Fit-all-pins button: restores the default framing (and, by design, overwrites
        // the remembered per-file camera with it — see Coordinator.fitAllPins).
        let fitButton = UIButton(configuration: .plain())
        fitButton.translatesAutoresizingMaskIntoConstraints = false
        fitButton.setImage(
            UIImage(systemName: "arrow.down.backward.and.arrow.up.forward",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)),
            for: .normal
        )
        fitButton.accessibilityLabel = String(
            localized: "Fit All Pins",
            comment: "Accessibility label for the map button that zooms to show every pin."
        )
        fitButton.addAction(UIAction { [weak coordinator] _ in
            coordinator?.fitAllPins()
        }, for: .primaryActionTriggered)
        let fitContainer = Self.glassContainer()
        fitContainer.contentView.addSubview(fitButton)
        NSLayoutConstraint.activate([
            fitButton.centerXAnchor.constraint(equalTo: fitContainer.contentView.centerXAnchor),
            fitButton.centerYAnchor.constraint(equalTo: fitContainer.contentView.centerYAnchor),
            fitContainer.widthAnchor.constraint(equalToConstant: 44),
            fitContainer.heightAnchor.constraint(equalToConstant: 44),
        ])
```

and change the stack line to include it:

```swift
        let stack = UIStackView(arrangedSubviews: [styleContainer, fitContainer, trackingContainer])
```

(If `arrow.down.backward.and.arrow.up.forward` doesn't render on the target SDK, fall back to `"arrow.up.left.and.arrow.down.right"` — verify in the simulator.)

- [ ] **Step 4: Prune at bootstrap**

In `RootView.bootstrap()`, after `restoreSessionIfNeeded()`:

```swift
        // Camera-store hygiene: drop cameras for files no longer anywhere in the catalogue
        // (active OR trashed — restoring from the trash keeps the camera). Only kicks in
        // past the cap; below it stale entries are harmless bytes.
        MapCameraStore().pruneIfNeeded(keeping: Set(catalog.entries.map(\.storageFolderName)))
```

- [ ] **Step 5: Build + full tests + lint**

Run: `scripts/build.sh && scripts/test.sh`
Expected: green; `swiftlint lint`: 0 errors.

- [ ] **Step 6: Manual verification**

1. Open a file's map (toolbar) → it fits all pins (no saved camera yet). Pan/zoom somewhere specific, pop back, reopen the map → the camera is where you left it.
2. Relaunch the app entirely (no kill needed — this persists across sessions), reopen the map → same camera.
3. Tap the fit-all button → map fits all pins; reopen the map → the FIT framing is what's remembered now.
4. POI page → "Show on Map" → still zooms to that pin (focus wins over the saved camera).
5. Kill-and-restore with the map on top (Task 6 flow) → the map restores at the saved camera, NOT re-focused on the old focus pin, and NOT fit-all.

- [ ] **Step 7: Commit**

```bash
git add App/Views/PlacemarkMapRepresentable.swift App/Views/PlacemarkMapSupport.swift App/Views/RootView.swift
git commit -m "feat(app): remember per-file map camera with fit-all reset control

Claude-Session: https://claude.ai/code/session_01EYocFdaGHNVorJBtCaFNz9"
```

---

### Task 9: Settings toggle

**Files:**
- Modify: `App/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `AppSettings.restoreSessionEnabled` (Task 2 — turning it off already clears the saved state via its `didSet`).

- [ ] **Step 1: Add the section**

In `SettingsView.body`'s `Form`, add `sessionSection` after `mapViewSection`:

```swift
        Form {
            defaultMapAppSection
            mapAppsSection
            mapViewSection
            sessionSection
            iCloudSection(settings: $settings)
        }
```

and the section itself (after `mapViewSection`'s definition):

```swift
    // MARK: - Session section

    @ViewBuilder
    private var sessionSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Restore Session on Launch", isOn: $settings.restoreSessionEnabled)
        } header: {
            Text("Session")
        } footer: {
            Text("Reopens the file, screen, and position you were viewing when the app restarts.")
        }
    }
```

- [ ] **Step 2: Build, verify, commit**

Run: `scripts/build.sh && scripts/test.sh`
Expected: green.

Manual: Settings shows the toggle ON by default; turn it OFF → kill → relaunch → catalogue (no restore); turn it back ON → open a file → kill → relaunch → restored.

```bash
git add App/Views/SettingsView.swift
git commit -m "feat(app): settings toggle for session restoration

Claude-Session: https://claude.ai/code/session_01EYocFdaGHNVorJBtCaFNz9"
```

---

### Task 10: Final verification + merge

**Files:** none (verification only).

- [ ] **Step 1: Full automated pass**

```bash
scripts/build.sh && scripts/test.sh && (cd PinfoldCore && swift test)
swiftlint lint | grep "error:" ; echo "errors above (want none)"
```

Expected: everything green; no lint errors.

- [ ] **Step 2: Full manual matrix (simulator, iOS 26.5)**

Kill = background the app first (`.inactive` must fire), then `xcrun simctl terminate booted tech.inkhorn.pinfold`.

| # | Scenario | Expected |
| --- | --- | --- |
| 1 | Kill on the placemark LIST, scrolled deep, with a search query + a collapsed folder | Relaunch → same file, query + collapse + scroll restored |
| 2 | Kill on a POI page | Relaunch → file → POI page; back pops to the list at its saved scroll |
| 3 | Kill on a map pushed from a POI ("Show on Map"), after panning away | Relaunch → file → POI → map at the PANNED camera (not re-focused, not fit-all) |
| 4 | Kill on the catalogue (nothing selected) | Relaunch → catalogue |
| 5 | Restore toggle OFF, kill mid-file | Relaunch → catalogue |
| 6 | Kill mid-file, then delete the entry's folder from the storage root (Application Support, via the simulator's container on disk) before relaunch | Relaunch → catalogue, no crash, stale state cleared (next kill/relaunch cycle doesn't retry it) |
| 7 | Open the map, pan, pop, reopen (NO kill) | Camera remembered per file |
| 8 | Fit-all button | Fits pins; the fit framing becomes the remembered camera |
| 9 | Deep link wins: kill mid-file-A, relaunch by opening a KML file into the app ("Open in Pinfold" drag onto simulator) | The file imports and the app stays on the catalogue (restore suppressed); no restore of A on top of the import |
| 10 | Regular-width (iPad sim or resized window): favorites hit → POI deep link still lands in the detail column | Unchanged deep-link behavior |

Fix anything that fails before merging; re-run the matrix line that failed.

- [ ] **Step 3: Merge**

```bash
git checkout main
git merge --no-ff feature/session-restoration -m "Merge feature/session-restoration: restore session state across app termination

Claude-Session: https://claude.ai/code/session_01EYocFdaGHNVorJBtCaFNz9"
```
