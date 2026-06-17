# Deep-link search / favorites / Spotlight hits to the POI page

**Date:** 2026-06-17
**Branch:** `v1.4`

## Problem

Tapping a placemark from any of the three catalogue-wide entry points does **not** open
that placemark's detail page. Instead it opens the placemark's *file* with the in-file
outline pre-*filtered* to the placemark's name, leaving the user to scroll the (still
long) filtered list and tap the row themselves.

The three affected entry points:

1. **"Places" search hits** — `HomeView+Sections.openPlaceHit`.
2. **Favorites** — `FavoritesView.open`.
3. **Spotlight** placemark-result taps — `RootView.handleSpotlightActivity`.

All three share one mechanism: they set `RootView.pendingDetailSearch` to the placemark's
**name** and select the file. `KMLDetailView` consumes that as a one-shot seed for its
in-file search field, which only *filters* the outline — it never pushes the POI page.

**Expected:** tapping a hit lands directly on `PlacemarkDetailView` (the POI page).
**Back** from the POI shows the file's **full, unfiltered** placemark list, so the user can
browse the file's other places.

## Key facts

- A placemark's durable identity is its `stableKey` (`KMLPlacemark.stableKey`). Every hit
  from all three entry points already carries it:
  - `PlacemarkIndex.Hit.key` (search + favorites),
  - `SpotlightID.parse(...).placemarkKey` (Spotlight).
- `PlacemarkDetailView` needs the parsed `KMLDocument` and the `PlacemarkAnnotations`
  environment, both of which only exist **after** `KMLDetailView` parses the file off-main
  on open. So the push must happen from inside `KMLDetailView`, once its document is loaded.
- The detail column owns a `NavigationStack` (in `RootView`); `KMLDetailView` is its root.
  A `.navigationDestination(item:)` attached inside `KMLDetailView` pushes within that stack.

## Approach

**stableKey deep-link that auto-pushes the POI.** Replace the name-based deep-link payload
with the `stableKey`, and have `KMLDetailView` resolve it to a `KMLPlacemark` after load and
push `PlacemarkDetailView` programmatically.

Rejected alternative — pushing the POI from `RootView`, bypassing `KMLDetailView` — would
duplicate document loading and `PlacemarkAnnotations` injection at the root and produce an
awkward back stack.

## Design

### 1. Rename the deep-link payload (name → stableKey)

`RootView.pendingDetailSearch: String?` becomes `RootView.pendingPlacemarkKey: String?`.
The binding already threads HomeView / FavoritesView / Spotlight → RootView →
`KMLDetailView`; only the payload's meaning changes.

Call-site changes:

- `HomeView+Sections.openPlaceHit(hit)` and `FavoritesView.open(hit)`:
  set `pendingPlacemarkKey = hit.key` (instead of `pendingDetailSearch = hit.name`).
  These no longer need to special-case an empty name.
- `RootView.handleSpotlightActivity`: pass `parsed.placemarkKey` straight through. The
  off-main `readPlacemarkName(forKey:in:)` helper is **deleted** — the name is no longer
  needed for routing.
- `RootView.openEntry(folderName:)` (App Intent / file-level deep link): clears
  `pendingPlacemarkKey` (was `pendingDetailSearch`), unchanged in spirit.

The `HomeView.pendingDetailSearch` and `FavoritesView.pendingDetailSearch` bindings rename
to `pendingPlacemarkKey` accordingly.

### 2. KMLDetailView: resolve the key and push

- Replace the `initialSearch: String?` / `onConsumeInitialSearch` properties with
  `initialPlacemarkKey: String?` / `onConsumePlacemarkKey`.
- Add `@State private var deepLinkTarget: PlacemarkRoute?` backing a
  `.navigationDestination(item: $deepLinkTarget)` that pushes `PlacemarkDetailView`.
- `KMLPlacemark` is not `Hashable`, so the route is a tiny wrapper:

  ```swift
  /// Identifies a programmatic push target by the placemark's parse-`id`, which is unique
  /// within a single loaded document (the only scope this route lives in).
  private struct PlacemarkRoute: Identifiable, Hashable {
      let placemark: KMLPlacemark
      var id: String { placemark.id }
      static func == (a: Self, b: Self) -> Bool { a.placemark.id == b.placemark.id }
      func hash(into h: inout Hasher) { h.combine(placemark.id) }
  }
  ```

- Resolution happens in **two** places, mirroring today's dual-consume for `initialSearch`:
  - **New file:** the load `.task(id: entry.id)`, immediately after `loadDocument()`
    succeeds — set `deepLinkTarget` from `initialPlacemarkKey`, then `onConsumePlacemarkKey()`.
  - **Already-open file** (same identity, new param): `.onChange(of: initialPlacemarkKey)`
    resolves against the already-loaded `document` and pushes.
- Resolution primitive: `document.root.allPlacemarks.first { $0.stableKey == key }`.
  The in-file search field (`searchText`) is **not** seeded, so Back lands on the full list.

### 3. Edge cases

- **Key not found** (stale index, or placemark removed since the index was built): no push.
  The file opens to its normal full list — silent and safe, matching how `FavoritesView`
  already drops unresolvable favorite keys.
- **Duplicate `stableKey`** (a repeated POI): `first(where:)` picks the first occurrence —
  the same collapsing the index and search results already do.
- The existing list `NavigationLink`s, the manual in-file search field, the map push, and
  favorite/visited swipe actions are all untouched.

## Testing

- **Unit (pure):** the resolution primitive against a fixture `KMLDocument`:
  - a present key resolves to the correct placemark,
  - an absent key resolves to `nil`,
  - a duplicated key resolves to the first occurrence.
  If `allPlacemarks.first { $0.stableKey == }` is used inline, factor it into a small
  testable helper (e.g. `KMLContainer.firstPlacemark(withStableKey:)` in PinfoldCore, or an
  app-side free function) so it can be asserted directly.
- **Manual:** run the app in the simulator and verify all three flows (search hit, favorite,
  Spotlight tap) land directly on the POI page, and that Back shows the full file list.

## Out of scope

- Changing how the in-file search field behaves for manual searching.
- Map-pin taps (already push `PlacemarkDetailView` directly).
- Any change to index/Spotlight building or the favorites storage model.
