# Show on Embedded Map + Seen-pin fade — design

Date: 2026-06-17

## Summary

Two related improvements to the placemark/map experience:

1. **"Show on Embedded Map"** — a new action on the POI detail page's three-dots
   menu that opens the app's embedded map zoomed to and with that POI selected.
2. **Seen-pin fade** — the map already draws "Seen" (visited) pins at reduced
   opacity, but it is not visibly taking effect in at least one build. Treat as a
   defect: confirm the root cause and fix it. The opacity value (`0.45`) stays.

## Motivation

- From a POI page you can "Open in Maps" (external app), but there is no way to
  see that POI on the in-app map in context with the file's other pins.
- Seen pins are meant to fade back so unvisited pins stand out; a user reported a
  Seen POI rendering at full opacity on the embedded map.

## Feature 1 — "Show on Embedded Map"

### Behavior

- A menu item **"Show on Embedded Map"** (SF Symbol `map`) appears at the top of
  `PlacemarkDetailView`'s three-dots `Menu`, shown **only when the placemark has a
  coordinate** (`hasCoordinate`).
- Tapping it **pushes** the embedded map (`PlacemarkMapView`) onto the current
  navigation stack. The back button returns to the POI page.
- The map shows **all of the file's mappable placemarks** (every placemark in the
  document that has a coordinate), with **this POI selected and the map zoomed to a
  ~1 km region centered on it** — its preview card shows, exactly as if the user had
  tapped the pin. This gives context (surrounding pins) while focusing the chosen POI.

### Design

`PlacemarkMapView` and `PlacemarkMapRepresentable` gain an optional
`initialFocusKey: String?` (default `nil`).

- `PlacemarkMapRepresentable.makeUIView`'s `onFirstLayout` closure:
  - If `initialFocusKey` resolves to a realized `PlacemarkAnnotation`, **select it**
    via `mapView.selectAnnotation(annotation, animated: false)` and **zoom to a
    ~1 km region** centered on its coordinate (reusing the single-pin region path in
    `fit`). Selecting fires the existing `didSelect`, which sets `selectedKey`,
    highlights the pin, and surfaces the preview card — no new selection plumbing.
  - Otherwise (`nil` or unmatched key), behavior is **unchanged**: fit all pins.
- The first-layout fit is the single place this branches; the rest of the
  representable (reconciliation, re-decoration, selection bridging) is untouched.

`PlacemarkDetailView`:

- New `@State private var showOnMap = false`.
- Menu button sets `showOnMap = true`.
- A `.navigationDestination(isPresented: $showOnMap)` pushes:

  ```swift
  PlacemarkMapView(
      placemarks: document.root.allPlacemarks.filter { $0.coordinate != nil },
      document: document,
      entry: entry,
      initialFocusKey: placemark.stableKey
  )
  .environment(annotations)
  ```

  The `allPlacemarks.filter { $0.coordinate != nil }` reproduces the exact
  definition of "mappable" used by `PlacemarkOutline` (a placemark with a
  coordinate). The `.environment(annotations)` re-injection mirrors the documented
  exception at `PlacemarkMapView.swift:73`: the map is pushed from an already-pushed
  view, the one case where stack-root environment propagation has been unreliable, so
  re-injecting keeps favorite/visited decoration deterministic.

### Edge cases

- **No coordinate:** the menu item is hidden (`hasCoordinate == false`).
- **Only this placemark is mappable:** map shows one pin, zoomed to ~1 km, selected.
- **Reached from the map already** (map → preview card → POI → "Show on Embedded
  Map"): a second map is pushed, focused on the POI. Acceptable; the user chose
  push-onto-current-stack navigation.

## Feature 2 — Seen-pin fade not rendering

- The fade is implemented: `PlacemarkPinImage.decorated(_:isFavorite:isVisited:)`
  draws the base image at `alpha: 0.45` when `isVisited`, and
  `PlacemarkMapRepresentable.updateUIView` re-decorates when `visitedKeys` changes.
- A user screenshot shows a Seen POI's pin at full opacity. The same screenshot
  shows a trailing "✓" after the name where current source renders a **strikethrough**
  — suggesting the screenshotted build did not match current source.
- **Plan:** build current source to the iOS 26.5 simulator with a Seen POI and
  observe. If the fade renders correctly, the original report was a stale build and
  no code change is needed. If it genuinely does not render, root-cause via
  systematic debugging and fix the actual defect. **The `0.45` value does not change.**

## Out of scope

- Changing the Seen fade opacity value.
- Changing the preview card's Seen styling (strikethrough/secondary color).
- Adding "Show on Embedded Map" to any surface other than the POI detail page.

## Testing

- **Unit:** the mappable-placemark filter (`allPlacemarks.filter { $0.coordinate
  != nil }`) returns the document's coordinate-bearing placemarks; the initial-focus
  region/selection logic selects the matching annotation when `initialFocusKey` is set
  and falls back to fit-all when it is `nil`/unmatched (test the pure pieces where the
  `MKMapView`-bound parts can't be exercised in a unit test).
- **Manual (simulator):**
  1. POI page → three-dots → "Show on Embedded Map" → map opens zoomed on the POI
     with its preview card showing and surrounding pins visible.
  2. Menu item is absent for a coordinate-less placemark.
  3. A Seen POI's pin renders visibly faded relative to unvisited pins.
