# Session Restoration — Design

**Date:** 2026-07-02
**Status:** Approved

Supersedes `2026-07-01-remember-last-opened-file-design.md`, whose implementation never
landed in the repository. Its verified findings (scroll-anchor mechanism, `@Observable`
init gotcha, scenePhase save trigger) are carried forward here.

## Problem

When Pinfold is terminated in the background — jetsam under memory pressure, a user
swipe-kill in the app switcher, or a crash — it relaunches fresh at the catalogue. A user
who opened a big KML file, scrolled deep into its placemark list, opened a point, and
navigated to it in a maps app returns to find all of that gone.

## Goal

Relaunch in the state the app was in when it died, for all three termination causes:

1. **Selected file + open screen** — reopen the file and land on the same screen
   (placemark list, POI page, or map), with the literal navigation stack restored.
2. **List scroll position** — the placemark list scrolled back to the topmost visible row.
3. **Transient list state** — search text, collapsed folders, nearest-first sort.
4. **Map camera** — remembered **per file, across sessions** (not only across kills):
   reopening a file's map lands at the last center/zoom instead of fit-all-pins.

Gated by a Settings toggle, on by default. Every restore failure is a silent no-op that
degrades to today's behavior. Sheets (Settings, Favorites, map picker, photo viewer) and
the catalogue's own scroll position are out of scope and reset on relaunch.

## Approach — options considered

- **`@SceneStorage` / system state restoration (rejected as storage):** Apple documents
  scene state as best-effort and **discarded on user force-quit** — one of the exact
  cases to cover. Its *save trigger* (persist when the scene deactivates) is kept.
- **Milestone snapshot + deep-link replay (rejected):** keep today's destination-based
  navigation and replay a "top screen" snapshot through extended one-shot parameters.
  Less work, but restores an equivalent shallow stack rather than the literal one, and
  each new restorable screen adds another consume-once parameter to an already intricate
  dance.
- **Value-based navigation + persisted route path (chosen):** refactor pushes to
  `Codable` route values in a `NavigationStack(path:)` — SwiftUI's first-class,
  serializable representation of the stack — persisted in UserDefaults so it survives
  force-quit. Restores the literal stack and simplifies the existing deep-link plumbing.

## Design

### Route model (new `App/Model/EntryRoute.swift`)

```swift
enum EntryRoute: Hashable, Codable {
    case placemark(stableKey: String)   // POI page
    case map(focusKey: String?)         // nil = list toolbar; non-nil = POI "Show on Map"
}
```

Routes are self-contained durable values — no live `KMLPlacemark`s. `stableKey` is the
same identifier Spotlight, favorites, and App Intents already use, so a route resolves
(or silently fails) against a re-parsed document exactly like existing deep links.
Persisted as JSON inside a versioned wrapper; a decode failure (app updated, corrupt
data) discards the routes and the file opens at its list.

### Path ownership and the destination table

- The detail column's `NavigationStack` (`RootView`) becomes `NavigationStack(path:)`.
  The `[EntryRoute]` path lives on the existing `NavigationRouter` (`@Observable`,
  already the deep-link sink published to `AppDependencies`), environment-injected so
  any view in the file pushes by appending a value.
- Selecting a different entry clears the path — routes are per-document, matching
  today's stack reset on file switch.
- The four push mechanisms (`NavigationLink(destination:)` list rows, the toolbar map
  `NavigationLink`, `.navigationDestination(item:)` deep-link pushes in `KMLDetailView`
  and `PlacemarkMapView`, `.navigationDestination(isPresented:)` for "Show on Map")
  collapse into **one** `.navigationDestination(for: EntryRoute.self)` declared in
  `KMLDetailView` — the only place holding the parsed `document`, `outline`, and
  `annotations` needed to resolve a route into a screen. List rows become
  `NavigationLink(value:)`; the map preview card and the POI "Show on Map" button append
  to the path.
- The per-push-site `.environment(annotations)` re-injection workaround (four sites
  today, each with an explanatory comment) is needed once, in the destination builder.
  The Mac re-hosting behavior behind it must be re-verified after the refactor.

### Deep links unify with restore

`initialPlacemarkKey` / `deepLinkTarget` / `onConsumePlacemarkKey` generalize to a
single one-shot `initialRoutes: [EntryRoute]` parameter with the same consume-once
contract (including the second consume path via `onChange` for a file already open).
After the document parses, `KMLDetailView` validates each route in order — a stable key
that no longer resolves truncates the array to its valid prefix — and sets the router
path. A Spotlight/App-Intent tap is `initialRoutes = [.placemark(key)]`; session restore
is the same mechanism with a longer array. One restore-specific adjustment: a restored
`.map` route has its `focusKey` dropped (becoming `.map(focusKey: nil)`) — the saved
per-file camera already encodes where the user actually was and must win over a
re-focus zoom. The pin-selection preview card is not restored.

### Persistence (`App/Model/AppSettings.swift`)

UserDefaults-backed, per-device (UI state must never sync), following the existing
`didSet`-mirror pattern:

- `restoreSessionEnabled: Bool` — default **true**; read as
  `object(forKey:) as? Bool ?? true`. Turning it off clears all saved session state.
- `resumeEntryFolderName: String?` — the selected entry's `storageFolderName`.
- `resumeRoutes: Data?` — versioned JSON `[EntryRoute]`.
- Per-file transient slice, valid only beside the folder name: `resumeSearchText`,
  `resumeCollapsedFolderIDs`, `resumeNearestFirst`, `resumeScrollAnchorRowID`. Writing a
  **different** folder name clears the slice; re-writing the same name preserves it.
- **`@Observable` init gotcha (verified previously):** property observers DO fire for
  assignments inside `init`, so initializing the folder name from disk would trip the
  clear-on-different-folder coupling and delete the saved slice before it is read.
  Cross-property `didSet` effects are guarded by an `isBootstrapping` flag that `init`
  clears last; the `initWithSavedFolderAndAnchor_preservesAnchor` regression test pins it.

### Save triggers

On the `scenePhase` → `.inactive` transition — always passed through on the way to
background, before iOS's snapshot passes can re-lay the list out, and also fired on the
app-switcher kill path. Two writers, each owning its slice:

- `RootView` writes the folder name + encoded routes. Selection changes also update
  `resumeEntryFolderName` immediately via `onChange`, so a hard crash mid-session loses
  at most the in-file details, never the file.
- `KMLDetailView` writes the transient slice + scroll anchor (only it can read live row
  geometry).

### Scroll anchor (inherited verbatim from the superseded spec's verified design)

- `PlacemarkOutline.Row` ids are positional tree paths (`"0/1/p2"`), stable across
  launches because the tree is re-parsed identically from the same file.
- **Recording:** per-row `onGeometryChange` into a non-observable `RowFrameBox`
  (per-frame writes must not invalidate the view tree). NOT the iOS 18
  scroll-instrumentation APIs (`scrollPosition` / `onScrollVisibilityChange`): they do
  not support `List` (UICollectionView-backed) and silently never fire. At save time the
  anchor is the row whose top is nearest the list's content top, offset by the
  calibrated restore landing position stored in `RowFrameBox.restoredTopOffset`.
- **Restoring:** applied via `.task(id: rows.count)` (fires on appear AND on change;
  an `onChange` misses fast launches) with a verified retry — `ScrollViewReader
  .scrollTo(anchor, .top)` right after a `List`'s data lands is flaky, so the target
  row's live geometry is checked and the scroll re-issued (bounded) until it took.
- **Known approximation:** restore lands on the nearest row boundary, and an async
  outline rebuild shortly after (e.g. the location fix adding distance labels) can shift
  the settled position by about one row.

### Restore sequence (`RootView.bootstrap()` → `KMLDetailView`)

At the end of `bootstrap()`, after `catalog.reload()`, restore only when ALL hold:
toggle on; `resumeEntryFolderName` non-nil; `selectedEntryID` still nil (a live deep
link — Spotlight, App Intent, "Open in Pinfold" — wins over restore).

1. Resolve the folder name against `catalog.active`; set `selectedEntryID`. A miss
   (deleted, trashed, root switched) clears the stale state and lands on the catalogue.
2. Hand `KMLDetailView` the one-shot bundle: `initialRoutes` + the transient slice.
3. After the parse, seed `searchText` / `collapsedFolderIDs` / `nearestFirst` **before**
   the first outline build (one build, in the right shape), validate the routes, set the
   router path — the user lands on the POI page or map moments after a cold launch.
4. The list scroll restore runs concurrently underneath any pushed screen via the
   verified-retry mechanism; if a covering push kept it from sticking, one more attempt
   fires when the list next becomes visible. Nearest-first degrades as today: document
   order until a location fix arrives, then the outline re-sorts.

### Per-file map camera (`PlacemarkMapRepresentable` + a small store)

A Codable `MapCameraState` — center latitude/longitude, camera distance, heading, pitch
(the four `MKMapCamera` properties) — in a UserDefaults-backed dictionary keyed by
`storageFolderName`. Owned by the map layer as a small `MapCameraStore` (the same
ownership pattern as the representable's persisted basemap-style key), NOT by
`AppSettings`. Deliberately outside the resume snapshot and NOT gated by the restore
toggle: it is a navigation convenience that persists across sessions, like the basemap
style.

- **Saving:** in the coordinator's `regionDidChangeAnimated` (fires once per settled
  gesture/animation — no debounce needed), guarded so the programmatic initial framing
  (first-layout fit/focus) does not overwrite a saved camera.
- **Applying:** first-layout priority is **focus deep link → saved camera → fit all
  pins**. "Show on Map" always wins; fit-all remains the first-open default.
- **Re-fit control:** a "fit all pins" button joins the map's native control column
  (beside the compass), restoring the old framing on demand; it also updates the saved
  camera, acting as a natural reset.
- **Hygiene:** when the dictionary grows past ~100 entries it is pruned of keys absent
  from the catalogue; stale entries are otherwise harmless bytes.

### Settings UI (`App/Views/SettingsView.swift`)

`Toggle("Restore Session on Launch", ...)`, on by default, footer: "Reopens the file,
screen, and position you were viewing when the app restarts." Disabling clears the saved
snapshot.

### Failure handling

Every piece degrades independently and silently, consistent with deep-link conventions:

| Failure | Outcome |
| --- | --- |
| Saved folder name doesn't resolve | Catalogue; stale state cleared |
| Routes data fails to decode | File opens at its list; routes discarded |
| A route's stable key doesn't resolve | Valid route prefix kept, rest dropped |
| Scroll anchor row no longer exists | List opens at top |
| Saved camera invalid or missing | Fit all pins |

### Multi-scene caveat

The app declares multi-window support; UserDefaults is app-global, so with two iPad
windows the last scene to deactivate wins the snapshot. Accepted — per-scene fidelity
would require `@SceneStorage`, which force-quit discards.

## Testing

- **Unit:** `EntryRoute` + versioned wrapper Codable round-trip; corrupt/foreign-version
  data decodes to nil. `AppSettings` resume keys with an injected `UserDefaults` suite:
  default-true toggle, round-trips, clear-on-disable, clear-on-different-folder, and the
  bootstrap-flag regression test. `MapCameraState` round-trip + pruning. Route
  validation against a parsed fixture document (resolving, stale, mixed).
- **Integration (existing patterns):** `Catalog` resolve-by-folder-name (present /
  trashed / missing) with a temporary `StorageLocations(root:)`; suites sharing the
  `@MainActor` catalog are `@Suite(.serialized)`.
- **Manual, iOS 26.5 simulator:** background-kill and process-terminate against each top
  screen (list / POI / map); deep-link-beats-restore; toggle off; file deleted between
  sessions; map camera survives normal close/reopen of a file's map.
