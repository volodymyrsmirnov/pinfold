# Favorite & Visited Placemarks — Design

**Date:** 2026-05-25
**Status:** Approved (pre-implementation)

## Goal

Let the user mark any placemark as **favorite** and/or **visited**, from both the
points list (leading swipe) and the point detail page (three-dots menu). Favorites
carry a leading star icon everywhere they appear; visited points render struck-out.
**List order is unchanged** — placemarks stay in their original parse order. State
persists in the entry's `metadata.json` and is re-read whenever the KML file is opened.

## Decisions (locked)

- **No reordering.** Placemarks keep their original parse order in the list regardless
  of favorite/visited status. Favorite/visited are conveyed purely by appearance (star
  icon, strikethrough), not position. A placemark can be both favorite and visited — it
  shows the star and is struck-out, in place.
- **Map reflects state.** Favorite and visited status change pin appearance on the map
  screen (not list/detail only).
- **Favorite star icon shows before the title** consistently in list rows, the point
  detail page, the map preview card, and as a pin badge on the map.
- **Stable key is a technical decision, not per-file user input** — see below.

## 1. Stable placemark identity (PinfoldCore)

`KMLPlacemark.id` is a parse-order identifier (`"p1"`, `"p2"`, …) and is **explicitly
not stable across re-parses**, so it cannot key persistent state. We add a stable key
derived from the placemark's own content, via a fallback chain:

1. **Author `<Placemark id="…">`** — the parser currently discards this XML attribute.
   Capture `attributeDict["id"]` on `<Placemark>` start into a new
   `sourceID: String?` field on `KMLPlacemark`. When present and non-empty (Google
   Earth / My Maps exports include it), the key is `"id:<sourceID>"`.
2. **Hash of name + coordinate** — otherwise `"h:<hash>"`, where `hash` is a truncated
   hex SHA-256 of a normalized `"<name>|<lat>|<lon>"` string, reusing the same hashing
   already used for `contentSHA256`. Survives folder reordering; only breaks if that
   placemark's own name or coordinate is edited.
3. **Parse-order id** — last resort `"p:<id>"` for a placeless, nameless placemark.

Exposed as a computed `var stableKey: String` on `KMLPlacemark` (pure, unit-testable).

**Accepted edge case:** two placemarks with identical name + coordinate and no author
`id` share a key and therefore toggle together. Acceptable for this catalogue.

## 2. Persistence (`metadata.json`)

Extend `EntryMetadata` with:

```swift
var favoriteKeys: Set<String> = []
var visitedKeys: Set<String> = []
```

Use **custom `Codable`** (not synthesized) because:

- Old `metadata.json` files predate these keys. Decode with
  `decodeIfPresent(...) ?? []` so they round-trip to empty sets. (Synthesized `Codable`
  would throw `keyNotFound` for a missing non-optional property.)
- Encode each set as a **sorted `[String]` array**, not a raw `Set`, to preserve the
  existing pretty-printed, key-sorted, diff-friendly JSON guarantee in
  `EntryMetadata.encoded()`. (A `Set`'s JSON array order is not stable, which would
  cause spurious diffs and iCloud sync churn.)

`CatalogEntry` does **not** mirror these sets — the catalogue list view has no need for
per-placemark state, and loading potentially large sets into every list row is wasted
work. This has one consequence handled in §3.

## 3. Write path: read-modify-write, no reload

`Catalog.writeTrashedAt` currently reconstructs `EntryMetadata` from the in-memory
`CatalogEntry` (`var meta = entry.metadata`). Because `CatalogEntry` no longer carries
the favorite/visited sets, that path would **clobber** them on a trash/restore.

Fix: all metadata mutations — trash/restore **and** annotation toggles — switch to
**read-modify-write of the on-disk `metadata.json`**: read the current sidecar, mutate
the single relevant field, write it back. No field can be dropped by a partial
in-memory mirror.

Annotation writes specifically must **never** call `Catalog.reload()` or re-parse the
open document. The sidecar is a sub-KB JSON file, so the write is done synchronously on
the main actor (exactly like the existing `writeTrashedAt`), which also serializes
concurrent toggles for free.

## 4. Open-document state (`PlacemarkAnnotations`)

A new `@Observable` class, owned by `KMLDetailView` for the currently open entry and
installed into the SwiftUI environment so all descendants (rows, detail view, map,
preview card) read the same instance:

- On open, loads `favoriteKeys` / `visitedKeys` from the entry's `metadata.json`.
- `isFavorite(_:)`, `isVisited(_:)`, `toggleFavorite(_:)`, `toggleVisited(_:)` —
  all keyed by a placemark's `stableKey`.
- A toggle mutates the in-memory set (instant UI via `@Observable`), then synchronously
  writes through to `metadata.json` per §3. It does **not** reload the catalogue or
  re-parse.

It holds the references it needs to write (storage locations + the entry's folder
name).

## 5. List order

Unchanged. `KMLDetailView` renders placemarks in their original parse order in every
container; favorite/visited status never reorders rows. The existing `ForEach` keyed on
`placemark.id` and the search pruning are untouched. Status is conveyed only by the row
appearance (§6).

## 6. UI controls

### List row (`PlacemarkRow`)
- **Leading star icon** (filled, yellow) immediately before the name when favorite.
- **Visited** → name `.strikethrough()` and dimmed.
- Reads the environment `PlacemarkAnnotations`.

### Leading swipe ("swipe right")
- `swipeActions(edge: .leading)` on each placemark row with two buttons:
  - **Favorite** — `star` / `star.slash`, yellow tint.
  - **Visited** — `eye` / `eye.slash`.
- Button labels reflect current state ("Favorite" / "Unfavorite",
  "Mark Seen" / "Mark Unseen").

### Point detail page (`PlacemarkDetailView`)
- A star shown **before the title**. Because the large navigation title can't host a
  custom leading glyph, the star is placed inline at the start of the content header
  (next to / leading the title text), reading as "star before title."
- The three-dots menu gains, at the top, **"Add to / Remove from Favorites"** and
  **"Mark as Seen / Unseen"**, then a `Divider`, then the existing Copy Coordinates /
  Share / Copy Name actions.

## 7. Map screen

`PlacemarkMapView` / `PlacemarkMapRepresentable` / `PlacemarkPinImage` receive the
favorite/visited sets (value types) and refresh pin appearance when they change:

- **Favorite** → pin carries a star badge (and/or accent tint).
- **Visited** → pin dimmed (reduced opacity).
- **`PlacemarkPreviewCard`** shows the leading star when favorite and strikethrough
  when visited, matching the list.

Exact pin glyph/tint/opacity values are refined during implementation; the behavior
(star badge for favorite, dimmed for visited) is fixed.

## 8. Edge cases & constraints

- **iCloud sync** is whole-file last-write-wins on `metadata.json`. Toggling different
  placemarks on two devices simultaneously can lose one device's change. Acceptable for
  a single-user personal catalogue.
- **Stale keys**: if a placemark is later removed from the source file (e.g. re-import),
  its key lingers in the sets as an unused string. Harmless; no cleanup (YAGNI).
- **App Group / share extension** is unaffected — this is all in-app on the synced
  storage root.

## 9. Testing

**PinfoldCore (`swift test`):**
- `stableKey` uses `"id:"` scheme when `<Placemark id>` is present.
- Hash fallback is deterministic and stable across folder reordering.
- Hash differs when coordinate differs (and when name differs).
- Placeless, nameless placemark falls back to `"p:"` scheme.
- Parser captures the `<Placemark id="…">` attribute into `sourceID`.

**App (`scripts/test.sh`):**
- `EntryMetadata` Codable round-trip including the new fields.
- Decoding a legacy `metadata.json` (no favorite/visited keys) yields empty sets.
- Encoded JSON stores the sets as sorted arrays (stable output).
- `PlacemarkAnnotations` toggle updates the set and writes through.
- Write-through preserves `trashedAt` and other fields (read-modify-write).

App tests run on the iPhone 17 / iOS 26.5 simulator with signing disabled
(`scripts/test.sh`). This feature touches no SwiftData, so the SwiftData test rules in
`CLAUDE.md` do not apply; annotation write-through can be tested against a temporary
`StorageLocations` directory.

## 10. Files touched

**PinfoldCore**
- `Model/KMLPlacemark.swift` — add `sourceID`, computed `stableKey`.
- `Parsing/KMLParser.swift` — capture `attributeDict["id"]` for `<Placemark>`.

**App**
- `Model/EntryMetadata.swift` — add `favoriteKeys` / `visitedKeys` + custom `Codable`.
- `Services/PlacemarkAnnotations.swift` *(new)* — `@Observable` store + environment key.
- `Model/StorageLocations.swift` — read-modify-write metadata helper (if not already
  expressible with existing read/write methods).
- `Services/Catalog.swift` — switch `writeTrashedAt` to read-modify-write.
- `Views/KMLDetailView.swift` — own + inject the store, add leading swipe actions.
- `Views/PlacemarkRow.swift` — leading star + strikethrough.
- `Views/PlacemarkDetailView.swift` — star before title, menu toggles.
- `Views/PlacemarkMapView.swift`, `Views/PlacemarkMapRepresentable.swift`,
  `Views/PlacemarkPinImage.swift` — reflect favorite/visited on pins and preview card.
