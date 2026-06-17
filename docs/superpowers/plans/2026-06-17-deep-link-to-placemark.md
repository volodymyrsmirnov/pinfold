# Deep-link to POI Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tapping a placemark from Places search, Favorites, or a Spotlight result open that placemark's detail page (POI page) directly, instead of opening its file with a pre-filtered list.

**Architecture:** Replace the name-based one-shot deep-link payload (`pendingDetailSearch`) with the placemark's durable `stableKey` (`pendingPlacemarkKey`). After `KMLDetailView` parses the file off-main, it resolves the key to a `KMLPlacemark` and programmatically pushes `PlacemarkDetailView` via `.navigationDestination(item:)`. The in-file search field is no longer seeded, so Back lands on the full, unfiltered list.

**Tech Stack:** Swift 6, SwiftUI (iOS 26), `PinfoldCore` SwiftPM package, Swift Testing.

## Global Constraints

- Min iOS 26; Liquid Glass UI; MV + `@Observable` (no view-model layer).
- `PinfoldCore` is a standalone package: **no** UIKit/SwiftUI/SwiftData imports.
- App build: `scripts/build.sh`. App tests: `scripts/test.sh`. Package tests: `cd PinfoldCore && swift test`. These target the iPhone 17 simulator on iOS 26.5, code signing disabled — the only known-good destination.
- A PostToolUse hook auto-formats each edited `.swift` file (SwiftFormat). Keep SwiftLint at 0 errors.
- `Pinfold.xcodeproj` is generated/gitignored; `project.yml` is source of truth. Sources are globbed — no need to list files. This plan adds **no** app-target files, so no `xcodegen generate` is strictly required (the scripts run it anyway).
- Commit only when explicitly asked by the user; steps below include commits, but defer to the user's standing preference if they say otherwise.

---

### Task 1: `KMLContainer.firstPlacemark(withStableKey:)` resolution primitive

The pure, testable lookup the view will use to turn a deep-linked `stableKey` into a `KMLPlacemark`. Lives in `PinfoldCore` so it is unit-tested with `swift test`.

**Files:**
- Modify: `PinfoldCore/Sources/PinfoldCore/Model/KMLContainer.swift` (add a method after `allPlacemarks`, around line 18)
- Test: `PinfoldCore/Tests/PinfoldCoreTests/FirstPlacemarkTests.swift` (create)

**Interfaces:**
- Consumes: existing `KMLContainer` (`placemarks`, `children`) and `KMLPlacemark.stableKey`.
- Produces: `public func firstPlacemark(withStableKey key: String) -> KMLPlacemark?` on `KMLContainer`.

- [ ] **Step 1: Write the failing tests**

Create `PinfoldCore/Tests/PinfoldCoreTests/FirstPlacemarkTests.swift`:

```swift
import Testing
@testable import PinfoldCore

struct FirstPlacemarkTests {
    private func placemark(id: String, name: String) -> KMLPlacemark {
        KMLPlacemark(
            id: id, name: name, descriptionHTML: nil, styleUrl: nil,
            coordinate: Coordinate(longitude: 0, latitude: 0),
            extendedData: [], photoLinks: [], sourceID: nil
        )
    }

    @Test func findsPlacemarkByStableKeyAcrossNestedFolders() {
        let target = placemark(id: "p2", name: "Gullfoss")
        let root = KMLContainer(
            id: "d", name: "Doc",
            children: [
                KMLContainer(id: "f1", name: "Folder", children: [], placemarks: [target]),
            ],
            placemarks: [placemark(id: "p1", name: "Reykjavik")]
        )
        let found = root.firstPlacemark(withStableKey: target.stableKey)
        #expect(found?.id == "p2")
    }

    @Test func returnsNilForAbsentKey() {
        let root = KMLContainer(
            id: "d", name: "Doc", children: [],
            placemarks: [placemark(id: "p1", name: "Reykjavik")]
        )
        #expect(root.firstPlacemark(withStableKey: "id:does-not-exist") == nil)
    }

    @Test func returnsFirstOccurrenceForDuplicateKey() {
        // Identical name+coordinate ⇒ identical stableKey (a repeated POI).
        let first = placemark(id: "p1", name: "Dup")
        let second = placemark(id: "p2", name: "Dup")
        #expect(first.stableKey == second.stableKey)
        let root = KMLContainer(
            id: "d", name: "Doc", children: [],
            placemarks: [first, second]
        )
        #expect(root.firstPlacemark(withStableKey: first.stableKey)?.id == "p1")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd PinfoldCore && swift test --filter FirstPlacemarkTests`
Expected: FAIL — compile error, `value of type 'KMLContainer' has no member 'firstPlacemark'`.

- [ ] **Step 3: Implement the method**

In `PinfoldCore/Sources/PinfoldCore/Model/KMLContainer.swift`, add immediately after the `allPlacemarks` computed property (after line 18):

```swift
    /// The first placemark anywhere in this container subtree whose `stableKey` equals
    /// `key`, in document order, or `nil` if none matches.
    ///
    /// Used to resolve a deep link (a Places search hit, a favorite, or a Spotlight result)
    /// to the placemark it points at. A repeated placemark shares a `stableKey`; the first
    /// occurrence is returned, matching how the search index and outline already collapse
    /// duplicates. Document order means this container's own placemarks are checked before
    /// its children's, consistent with `allPlacemarks`.
    public func firstPlacemark(withStableKey key: String) -> KMLPlacemark? {
        for placemark in placemarks where placemark.stableKey == key {
            return placemark
        }
        for child in children {
            if let match = child.firstPlacemark(withStableKey: key) {
                return match
            }
        }
        return nil
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd PinfoldCore && swift test --filter FirstPlacemarkTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full package suite (no regressions)**

Run: `cd PinfoldCore && swift test`
Expected: PASS (all existing tests still green).

- [ ] **Step 6: Commit**

```bash
git add PinfoldCore/Sources/PinfoldCore/Model/KMLContainer.swift PinfoldCore/Tests/PinfoldCoreTests/FirstPlacemarkTests.swift
git commit -m "feat(core): add KMLContainer.firstPlacemark(withStableKey:)"
```

---

### Task 2: Swap the name-based deep-link for a stableKey push

Replace `pendingDetailSearch` (placemark name → in-file search seed) with `pendingPlacemarkKey` (stableKey → push POI page) end-to-end. This is one atomic change: the four files must change together to compile (the `KMLDetailView` API and the binding name change in lockstep). The deliverable is verified by build + the existing test suite + a manual three-flow check in the simulator.

**Files:**
- Modify: `App/Views/KMLDetailView.swift` (properties ~27–31; load `.task` ~115–141; `.onChange(of:)` ~151–155; add `.navigationDestination` near ~189; add `PlacemarkRoute` type)
- Modify: `App/Views/RootView.swift` (state `pendingDetailSearch` ~71; `HomeView(...)` ~94; `KMLDetailView(...)` ~106–112; `openEntry` ~186; `handleSpotlightActivity` ~205–215; delete `readPlacemarkName` ~425–429)
- Modify: `App/Views/HomeView.swift` (`@Binding` ~32; `FavoritesView(...)` ~346)
- Modify: `App/Views/HomeView+Sections.swift` (`openPlaceHit` ~283–289)
- Modify: `App/Views/FavoritesView.swift` (`@Binding` ~30; `open(_:)` ~118–123)

**Interfaces:**
- Consumes: `KMLContainer.firstPlacemark(withStableKey:)` from Task 1; `PlacemarkIndex.Hit.key`; `SpotlightID.parse(_:).placemarkKey`.
- Produces: `KMLDetailView(entry:initialPlacemarkKey:onConsumePlacemarkKey:)`; `HomeView(selection:pendingPlacemarkKey:)`; `FavoritesView(selection:pendingPlacemarkKey:)`.

- [ ] **Step 1: Rewrite `KMLDetailView`'s deep-link properties**

In `App/Views/KMLDetailView.swift`, replace the `initialSearch` / `onConsumeInitialSearch` properties (lines 22–31) with:

```swift
    /// A one-shot deep-link target: the durable `stableKey` of the placemark to open, supplied
    /// when this file was opened from a catalogue-wide hit (a "Places" search result, a favorite,
    /// or a Spotlight result — see `HomeView`/`FavoritesView`/`RootView`). After the document is
    /// parsed, the key is resolved to a `KMLPlacemark` and `PlacemarkDetailView` is pushed.
    /// `nil` for a normal selection. Consumed once (then `onConsumePlacemarkKey` clears the
    /// source so re-selecting the file normally doesn't re-push).
    var initialPlacemarkKey: String?

    /// Called once after `initialPlacemarkKey` has been consumed, so the owner can clear its
    /// one-shot source. Defaults to a no-op for callers (e.g. previews) that don't plumb it.
    var onConsumePlacemarkKey: () -> Void = {}
```

- [ ] **Step 2: Add the deep-link `@State` and route type**

In `App/Views/KMLDetailView.swift`, add to the `// MARK: - State` block (after `nearestFirst`, ~line 59):

```swift
    /// The placemark a deep link resolved to, driving a programmatic push of
    /// `PlacemarkDetailView` via `.navigationDestination(item:)`. `nil` when no deep link is
    /// active. Set by the load `.task` (new file) or `.onChange(of: initialPlacemarkKey)`
    /// (file already open).
    @State private var deepLinkTarget: PlacemarkRoute?
```

And add this nested type just below the `ImmediateOutlineTrigger` struct (after ~line 204):

```swift
    /// Identifies a programmatic push target by the placemark's parse-`id`, which is unique
    /// within a single loaded document (the only scope this route lives in). A wrapper exists
    /// because `KMLPlacemark` is `Equatable`/`Identifiable` but not `Hashable`, which
    /// `.navigationDestination(item:)` requires.
    private struct PlacemarkRoute: Identifiable, Hashable {
        let placemark: KMLPlacemark
        var id: String { placemark.id }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.placemark.id == rhs.placemark.id }
        func hash(into hasher: inout Hasher) { hasher.combine(placemark.id) }
    }
```

- [ ] **Step 3: Resolve + push in the load `.task` (new-file path)**

In `App/Views/KMLDetailView.swift`, replace the body of the load `.task(id: entry.id)` (lines 122–140, from `if loadedEntryID == entry.id` through `await loadDocument()`) with:

```swift
            if loadedEntryID == entry.id, document != nil { return }
            loadedEntryID = entry.id
            annotations = nil
            document = nil
            loadError = nil
            outline = nil
            collapsedFolderIDs = []
            nearestFirst = false
            searchText = ""
            deepLinkTarget = nil
            // Ask for a one-shot location fix so distances and the nearest sort can light up.
            locationAuth.request()
            await loadDocument()
            // Deep link: if this file was opened from a placemark hit, resolve the carried
            // stableKey against the freshly-parsed document and push its detail page. Consume
            // the one-shot key (whether or not it resolved) so a later normal re-selection of
            // the same file doesn't re-push, and so a stale key doesn't leak into another file.
            if let initialPlacemarkKey, !initialPlacemarkKey.isEmpty, let document,
               let match = document.root.firstPlacemark(withStableKey: initialPlacemarkKey) {
                deepLinkTarget = PlacemarkRoute(placemark: match)
            }
            if initialPlacemarkKey != nil {
                onConsumePlacemarkKey()
            }
```

- [ ] **Step 4: Resolve + push in `.onChange` (already-open path)**

In `App/Views/KMLDetailView.swift`, replace the `.onChange(of: initialSearch)` modifier (lines 142–155, the whole comment block + modifier) with:

```swift
        // Second consume path: a deep link into the file that is ALREADY open. The view keeps
        // its identity (`.id(entry.id)` unchanged), so the load `.task` above does NOT refire —
        // but SwiftUI re-evaluates the body with the new `initialPlacemarkKey` param, and this
        // `.onChange` observes the nil→key transition and pushes against the already-loaded
        // document. The guard's `let document` also covers the rare mid-load race: if the
        // document isn't ready yet, this no-ops WITHOUT consuming, and the in-flight load `.task`
        // (which reads `initialPlacemarkKey` after `loadDocument()`) handles it instead.
        .onChange(of: initialPlacemarkKey) { _, newValue in
            guard let newValue, !newValue.isEmpty, let document,
                  let match = document.root.firstPlacemark(withStableKey: newValue) else { return }
            deepLinkTarget = PlacemarkRoute(placemark: match)
            onConsumePlacemarkKey()
        }
```

- [ ] **Step 5: Add the `.navigationDestination` push**

In `App/Views/KMLDetailView.swift`, add this modifier immediately before `.environment(annotations)` (the last modifier on `body`, ~line 189):

```swift
        // Programmatic push for a resolved deep link. `deepLinkTarget` is only set once the
        // document is loaded, so `if let document` always succeeds here. Lives on the detail
        // column's NavigationStack root (this view), so the push lands in the detail column and
        // inherits the `.environment(annotations)` injected just below — the same environment
        // the list's own `NavigationLink`s rely on.
        .navigationDestination(item: $deepLinkTarget) { route in
            if let document {
                PlacemarkDetailView(placemark: route.placemark, document: document, entry: entry)
            }
        }
```

- [ ] **Step 6: Update `RootView` state + detail wiring**

In `App/Views/RootView.swift`:

(a) Rename the state property (lines 64–71). Replace the doc comment + declaration with:

```swift
    /// A one-shot deep-link target handed to the detail view when a selection is triggered by a
    /// catalogue-wide placemark hit (a "Places" search result, a favorite, or a Spotlight
    /// result). It carries the placemark's durable `stableKey` so `KMLDetailView` resolves it
    /// against the parsed document and pushes `PlacemarkDetailView` (the POI page).
    ///
    /// Consume-once flow: the source sets this AND `selectedEntryID` together when a hit is
    /// tapped; this view passes it into `KMLDetailView(initialPlacemarkKey:)`, which clears it
    /// via `onConsumePlacemarkKey`. A normal row tap only changes `selectedEntryID` (leaving
    /// this nil), so it does not push.
    @State private var pendingPlacemarkKey: String?
```

(b) Update the `HomeView` construction (line 94):

```swift
            HomeView(selection: $selectedEntryID, pendingPlacemarkKey: $pendingPlacemarkKey)
```

(c) Update the `KMLDetailView` construction (lines 106–112):

```swift
                    KMLDetailView(
                        entry: selectedEntry,
                        initialPlacemarkKey: pendingPlacemarkKey,
                        // Consumed once by the detail view; clearing here ensures a later normal
                        // selection of the same file doesn't re-push.
                        onConsumePlacemarkKey: { pendingPlacemarkKey = nil }
                    )
```

- [ ] **Step 7: Update `RootView` routing (App Intent + Spotlight)**

In `App/Views/RootView.swift`:

(a) In `openEntry(folderName:)`, replace `pendingDetailSearch = nil` (line 186) with:

```swift
        pendingPlacemarkKey = nil
```

(b) Replace the placemark-key branch in `handleSpotlightActivity` (lines 205–215) with:

```swift
        // A placemark item carries its stableKey directly in the Spotlight identifier — pass it
        // straight through as the deep-link target (no name lookup needed). An entry item has no
        // placemark key, so the file just opens.
        pendingPlacemarkKey = parsed.placemarkKey
        selectedEntryID = entry.id
```

(c) Delete the now-unused off-main helper `readPlacemarkName(forKey:in:)` and its `// MARK: - Off-main placemark name lookup` section (lines 419–429).

- [ ] **Step 8: Update `HomeView` binding + Favorites sheet**

In `App/Views/HomeView.swift`:

(a) Replace the `pendingDetailSearch` binding declaration (lines 30–32) with:

```swift
    /// One-shot deep-link target, owned by `RootView`. Set (together with `selection`) when the
    /// user taps a catalogue-wide "Places" search hit so the opened file pushes straight to that
    /// placemark's detail page. Left nil for ordinary file taps. See `RootView`.
    @Binding var pendingPlacemarkKey: String?
```

(b) Update the Favorites sheet construction (line 346):

```swift
        .sheet(isPresented: $isFavoritesPresented) {
            FavoritesView(selection: $selection, pendingPlacemarkKey: $pendingPlacemarkKey)
        }
```

- [ ] **Step 9: Update `openPlaceHit` (Places search)**

In `App/Views/HomeView+Sections.swift`, replace `openPlaceHit` (lines 283–289) and its doc comment with:

```swift
    /// Opens the file containing a Places hit, deep-linking to the placemark: seeds the one-shot
    /// `pendingPlacemarkKey` with the hit's stableKey, then selects the entry. `KMLDetailView`
    /// resolves the key after the file parses and pushes the placemark's detail page.
    ///
    /// Works for both selection states: a different file rebuilds `KMLDetailView` under a new
    /// identity (its load `.task` does the push); an already-open file keeps its identity but the
    /// `pendingPlacemarkKey` change re-evaluates the body, which `.onChange` consumes live.
    private func openPlaceHit(_ hit: PlacemarkIndex.Hit) {
        guard let entry = active.first(where: { $0.storageFolderName == hit.folderName }) else { return }
        // Seed the deep-link key BEFORE changing the selection so the detail view, rebuilt for
        // the new selection, reads it on its first load `.task`.
        pendingPlacemarkKey = hit.key
        selection = entry.id
    }
```

- [ ] **Step 10: Update `FavoritesView` binding + `open`**

In `App/Views/FavoritesView.swift`:

(a) Replace the `pendingDetailSearch` binding declaration (lines 28–30) with:

```swift
    /// One-shot deep-link target, owned by `RootView`. Set to the tapped favorite's stableKey so
    /// the opened file pushes straight to that placemark's detail page. See `RootView`.
    @Binding var pendingPlacemarkKey: String?
```

(b) Replace `open(_:)` (lines 114–123) and its doc comment with:

```swift
    /// Deep-links into the favorite's file, mirroring `HomeView.openPlaceHit`: seed the one-shot
    /// `pendingPlacemarkKey` with the hit's stableKey, then select the entry. The sheet is
    /// dismissed FIRST so the selection change reaches the underlying split view — driving the
    /// detail column to the favorite's file and pushing the placemark's detail page.
    private func open(_ hit: PlacemarkIndex.Hit) {
        guard let entry = catalog.active.first(where: { $0.storageFolderName == hit.folderName }) else { return }
        dismiss()
        pendingPlacemarkKey = hit.key
        selection = entry.id
    }
```

- [ ] **Step 11: Build the app**

Run: `scripts/build.sh`
Expected: BUILD SUCCEEDED. If a `FavoritesView` SwiftUI preview or any caller still references `pendingDetailSearch`/`initialSearch`, fix the reference to the new name (grep `git grep -n "pendingDetailSearch\|initialSearch\|onConsumeInitialSearch"` should return nothing).

- [ ] **Step 12: Run the app test suite (no regressions)**

Run: `scripts/test.sh`
Expected: PASS. (No app-target unit test exercises this view path; this confirms nothing else broke.)

- [ ] **Step 13: Lint**

Run: `swiftlint lint`
Expected: 0 errors (existing warnings are a known backlog).

- [ ] **Step 14: Manual verification in the simulator**

Use the `run-sim` skill (or `scripts/build.sh` + install/launch) to run the app, then import a fixture file with several placemarks (e.g. `AppTests/Fixtures` Iceland file) and verify all three flows land on the POI page, with Back showing the full unfiltered list:

1. **Places search:** type a query in the Home search field, tap a "Places" hit → POI detail page opens directly. Tap Back → the file's full placemark list (no search filter).
2. **Favorites:** star a placemark, open the Favorites sheet, tap it → POI detail page opens directly.
3. **Already-open file (iPad/regular width, optional):** with a file already selected in the detail column, tap another Places hit in the same file → its POI page pushes.

(Spotlight tap routing can't be exercised on the unsigned simulator reliably; the code path mirrors the other two and is covered by Task 1's resolution test.)

- [ ] **Step 15: Commit**

```bash
git add App/Views/KMLDetailView.swift App/Views/RootView.swift App/Views/HomeView.swift App/Views/HomeView+Sections.swift App/Views/FavoritesView.swift
git commit -m "feat(app): deep-link search/favorites/Spotlight hits to the POI page"
```

---

## Self-Review notes

- **Spec coverage:** payload rename (Task 2 Steps 6–10) ✓; KMLDetailView resolve + push, both paths (Steps 1–5) ✓; Spotlight simplification + `readPlacemarkName` deletion (Step 7) ✓; resolution primitive + tests including absent/duplicate keys (Task 1) ✓; full-unfiltered-list-on-Back via not seeding `searchText` (Step 3) ✓; manual three-flow check (Step 14) ✓.
- **Type consistency:** `initialPlacemarkKey` / `onConsumePlacemarkKey` / `pendingPlacemarkKey` / `firstPlacemark(withStableKey:)` / `PlacemarkRoute` used identically across all tasks.
- **Out of scope (unchanged):** manual in-file search field, map-pin push, index/Spotlight building, favorites storage.
