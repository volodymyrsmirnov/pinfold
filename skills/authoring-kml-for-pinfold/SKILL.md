---
name: authoring-kml-for-pinfold
description: Use when generating, writing, authoring, converting, or exporting a .kml or .kmz file that will be imported into Pinfold (the offline KML/KMZ catalogue app for iPhone, iPad, and Mac). Covers exactly which KML elements Pinfold parses and renders — placemarks, points, lines, polygons, tracks, document-level styles, AABBGGRR colors, descriptions, photos, ExtendedData, KMZ packaging — and which it silently ignores or rejects.
---

# Authoring KML/KMZ for Pinfold

## Overview

You are generating a KML (or KMZ) file that will be imported into **Pinfold**, an offline
KML/KMZ catalogue app for iPhone/iPad/Mac. Pinfold has its own parser with a specific,
deliberately limited feature set. Producing a file that "is valid KML" is not the goal — the
goal is a file whose every element Pinfold actually reads and renders. Anything Pinfold
ignores is wasted bytes that can confuse the result.

**Core principle:** When in doubt, prefer the **supported** pattern over the
technically-richer KML feature. Violating the spirit by emitting unsupported KML produces a
file that "validates" but renders wrong.

## The golden rules (read these first)

1. **Use `<Point>` placemarks for anything you want to find, search, or favorite.** A
   placemark's name is the *only* searchable text, and only `<Point>` placemarks get a map
   pin and a representative location/distance.
2. **Put all human-readable info in `<name>` and `<description>`.** `name` = a short title;
   `description` = the body (rendered as readable text — see Descriptions).
3. **Define styles once at the `<Document>` level and reference them with `<styleUrl>`.**
   Inline styles inside a `<Placemark>` are **ignored**. This is the single most common
   mistake — do not inline styles.
4. **Coordinates are `longitude,latitude[,altitude]`** — longitude first, comma-separated,
   tuples separated by whitespace. (Standard KML, but the #1 source of swapped pins.)
5. **Photos come only from a `gx_media_links` ExtendedData field**, not from `<img>` tags in
   the description. `<img>` in a description is stripped and never shown.
6. **Do not include a `<!DOCTYPE>` declaration.** Pinfold **rejects the entire file** if one
   is present (a security guard against entity-expansion attacks). No DTDs, ever.
7. **Tags, favorites, and "visited" are set by the user inside the app — not in the KML.**
   Don't try to encode them. (You *can* influence organization via `<Folder>` structure.)

## Document skeleton (copy this shape)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2"
     xmlns:gx="http://www.google.com/kml/ext/2.2">
  <Document>
    <name>Reykjavík Coffee Crawl</name>
    <description>Twelve specialty cafés worth a detour, gathered June 2026.</description>

    <!-- 1. Styles first, all at Document level, each with a stable id -->
    <Style id="cafe">
      <IconStyle>
        <color>ff4287f5</color>      <!-- AABBGGRR: opaque, blue-ish -->
        <scale>1.1</scale>
        <Icon><href>https://example.com/icons/coffee.png</href></Icon>
      </IconStyle>
    </Style>

    <!-- 2. Folders to group placemarks (optional, nestable) -->
    <Folder>
      <name>Downtown</name>

      <Placemark id="cafe-reykjavik-roasters">
        <name>Reykjavík Roasters</name>
        <description>Flagship roastery on Kárastígur. Order the filter flight.</description>
        <styleUrl>#cafe</styleUrl>
        <Point>
          <coordinates>-21.9408,64.1432,0</coordinates>
        </Point>
      </Placemark>

    </Folder>
  </Document>
</kml>
```

Notes:
- A single top-level `<Document>` is collapsed into the catalogue root — its `<name>` becomes
  the entry's display name. (If absent, the filename stem is used. Always provide a `<name>`.)
- The `gx:` namespace declaration is only needed if you use `gx_media_links` or `<gx:Track>`.

## What Pinfold reads — supported elements

Use **only** these. Everything else is parsed-and-discarded (see "What Pinfold ignores").

### Structure
| Element | Notes |
|---|---|
| `<Document>` | Root container. Its `name`/`description` become the catalogue entry's. |
| `<Folder>` | Groups placemarks; nestable to any depth. `name` shows as a section header. |
| `<Placemark>` | The unit of content. Add `id="..."` for stable identity (see Stable identity). |
| `<name>` | Title. **The only searchable field.** Keep it specific and human. |
| `<description>` | Body text. See Descriptions for how HTML is treated. |

### Geometry (coordinates are `lon,lat[,alt]`)
| Element | Renders as | Notes |
|---|---|---|
| `<Point>` | Map pin + searchable, locatable entry | **Strongly preferred.** Only the *first* coordinate tuple is used. |
| `<LineString>` | Polyline overlay | All tuples used. Styled by `LineStyle`. |
| `<Polygon>` | Filled/stroked area | Use `<outerBoundaryIs>` + optional `<innerBoundaryIs>` holes. Styled by `PolyStyle`/`LineStyle`. |
| `<gx:Track>` | Polyline overlay | Each `<gx:coord>` is **space-separated** `lon lat alt` (different from `<coordinates>`!). Timestamps in `<when>` are ignored. |
| `<MultiGeometry>` | Each child rendered independently | Fine to mix a Point + LineString in one placemark. |

A placemark **without a `<Point>`** (only a line/polygon) still appears, but has no pin and is
not located/searchable by position. If you want it findable, give it a clear `<name>` or also
include a `<Point>`. (A `<gx:Track>` placemark keeps a pin at its start.)

### Styling (define at `<Document>` level only)
| Element | Fields Pinfold reads | Ignored fields |
|---|---|---|
| `<Style id="…">` | the four sub-styles below | — |
| `<IconStyle>` | `<color>`, `<scale>`, `<Icon><href>` | `<hotSpot>`, `<heading>` |
| `<LineStyle>` | `<color>`, `<width>` | `<colorMode>`, `gx:` extras |
| `<PolyStyle>` | `<color>` (alpha = fill opacity), `<fill>` | `<outline>` |
| `<StyleMap>` | the `normal` pair only | the `highlight` pair |

- **Colors are `AABBGGRR` hex** (alpha, blue, green, red), *not* RGBA. Example: fully opaque
  red = `ff0000ff`; 50%-opaque red fill = `800000ff`.
- **Icon `<color>` without an `<Icon><href>` is fully supported and recommended for simple
  pins:** Pinfold draws a built-in teardrop pin tinted by that color (legible in light and
  dark map themes). Supply an `<Icon><href>` only when you have an actual icon image; KML
  marker images (e.g. Google "paddle"/dot icons) are shown as-is, untinted.
- `<StyleMap>` is supported but you only need it if a tool generates one; a plain `<Style>` +
  `<styleUrl>` is simpler and fully sufficient.
- **Reference styles by id:** `<styleUrl>#cafe</styleUrl>`.

### ExtendedData (custom key/value facts)
Use either form; both surface in the placemark detail view as name → value rows:

```xml
<ExtendedData>
  <Data name="Hours"><value>08:00–18:00</value></Data>
  <Data name="Wi-Fi"><value>Free</value></Data>
</ExtendedData>
```

`<SimpleData name="…">` inside `<SchemaData>` also works (the values are read), but the
`<Schema>` definition itself is ignored, so the simpler `<Data>` form is preferred.

> ExtendedData is **not searchable** — only `<name>` is. Put anything the user might search
> for into the name or description, and use ExtendedData for structured supporting facts.

## Photos — the `gx_media_links` pattern

This is the **only** way to attach photos to a placemark. They render as a photo gallery in
the detail view. Provide one or more **http/https** URLs, separated by whitespace, inside a
`<Data name="gx_media_links">` value:

```xml
<ExtendedData>
  <Data name="gx_media_links">
    <value>https://example.com/photos/cafe-1.jpg https://example.com/photos/cafe-2.jpg</value>
  </Data>
</ExtendedData>
```

- Remote photo URLs are downloaded and cached locally on import (so they work offline later).
- In a **KMZ**, you may instead reference a packaged image by a relative path (see KMZ packaging).
- Do **not** rely on `<img src>` in `<description>` — it will not display.

## Descriptions — how HTML is treated

The description is rendered as **readable plain text with tappable links**, not as a web page:

- Tags are **stripped**. `<b>`, `<i>`, `<span>`, `<table>`, `<img>` etc. produce no visual
  formatting and no images.
- `<br>` and block-level closings become **line breaks** — useful for paragraphs.
- **Links survive**: an `<a href="…">label</a>` becomes a tappable link, but only for the
  schemes `http`, `https`, `mailto`, and `tel`. Other schemes (`javascript:`, `data:`,
  `file:`) are dropped for security. Bare URLs, emails, and phone numbers are auto-linked.
- You may wrap the description in `<![CDATA[ … ]]>` if it contains markup or `&`/`<`
  characters — preferred when including links.

**Recommended description style:**

```xml
<description><![CDATA[Tiny third-wave café with a rotating single-origin bar.
Cash only. Closed Mondays.
Reservations: tel:+3545551234
More: https://example.com/cafe]]></description>
```

Keep descriptions concise. There is a generous size cap, but the UI shows a one-line preview
in lists and the full readable text in detail — front-load the important sentence.

## KMZ packaging (when bundling icons/photos)

Produce a `.kmz` (a ZIP) when you want icons or photos to travel **inside** the file instead
of being fetched from the network.

- The main document should be named **`doc.kml`** at the archive root. (Pinfold also accepts
  the first `.kml` alphabetically, but `doc.kml` is the unambiguous convention.)
- Reference packaged resources by a **relative path** from `doc.kml`:
  ```xml
  <Icon><href>icons/coffee.png</href></Icon>
  ```
  and place the file at `icons/coffee.png` in the archive.
- Path rules enforced on import: **no absolute paths** (`/…`), **no `..` traversal**. Keep
  everything in subfolders under the archive root.
- Same relative-path trick works for `gx_media_links` photos packaged inside the KMZ.
- Keep it reasonable: the importer rejects archives over ~2 GiB uncompressed or ~100k entries.

Use plain `.kml` + remote `https://` hrefs when the file should stay tiny and the device will
have network at import time; use `.kmz` with packaged resources for fully self-contained,
offline-first bundles.

## What Pinfold IGNORES — don't bother emitting these

These parse without error but have **no effect**. Including them adds noise; omit them.

- **Inline `<Style>` / `<StyleMap>` inside a `<Placemark>`** → ignored. (Define at Document
  level and reference by `styleUrl`.)
- `<LabelStyle>`, `<BalloonStyle>` → ignored.
- `<TimeStamp>`, `<TimeSpan>`, `<gx:TimeSpan>`, `<gx:Track>` timestamps → ignored.
- `<Region>`, `<LatLonAltBox>`, `<Lod>` → ignored.
- `<altitudeMode>` / `<gx:altitudeMode>` → ignored (altitude *values* are kept but the mode
  is not; Pinfold renders in 2D, so altitude has no visible effect).
- `<NetworkLink>` → **not fetched**. Pinfold is offline-first and never follows them. If you
  have linked content, inline it into the file instead.
- `<GroundOverlay>`, `<ScreenOverlay>`, `<PhotoOverlay>` → ignored.
- `<Model>`, `<gx:MultiTrack>` → geometry not rendered.
- `<visibility>`, `<open>` → ignored.
- `<Schema>` field definitions → ignored (only `<SimpleData>`/`<Data>` *values* are read).
- IconStyle `<hotSpot>`/`<heading>`, PolyStyle `<outline>`, `<colorMode>` → ignored.

## Stable identity & good-citizen details

- **Give each `<Placemark>` an `id`** (e.g. `id="cafe-roasters"`). Pinfold uses it as the
  durable key for favorites, "visited" marks, search results, and Spotlight deep links, so a
  re-import or edited file keeps the user's per-placemark state. Without an `id`, identity
  falls back to a hash of name+coordinates — stable only if those don't change.
- Make `id` values **unique and slug-like** within the file.
- Always provide a `<name>` on every placemark — nameless placemarks are hard to find
  (search matches names only) and look broken in lists.
- Validate coordinates: longitude in `[-180, 180]`, latitude in `[-90, 90]`. `NaN`/infinite
  values are rejected; out-of-range finite values are accepted but will look wrong.

## Common mistakes

| Mistake | Fix |
|---|---|
| Inline `<Style>` inside a `<Placemark>` | Move it to `<Document>` level, reference via `<styleUrl>#id</styleUrl>`. |
| `lat,lon` coordinates | KML is **`lon,lat`** — longitude first. |
| RGBA / `#rrggbb` colors | Use **`AABBGGRR`** hex (alpha first, then blue, green, red). |
| `<img>` in description for photos | Use `<Data name="gx_media_links">` with whitespace-separated http(s) URLs. |
| Emitting a `<!DOCTYPE>` | Remove it entirely — its presence rejects the whole file. |
| Relying on `<NetworkLink>` / overlays / 3D | Not rendered. Inline the content; use Point/Line/Polygon geometry. |
| Nameless placemarks | Every placemark needs a clear `<name>` (the only searchable text). |

## Pre-flight checklist

Before emitting the file, verify:

- [ ] No `<!DOCTYPE>` anywhere.
- [ ] One top-level `<Document>` with a `<name>`.
- [ ] All `<Style>`/`<StyleMap>` at Document level, each with an `id`; placemarks reference
      them via `<styleUrl>#id</styleUrl>` — **no inline styles**.
- [ ] Every placemark has a unique `id`, a clear `<name>`, and (ideally) a `<Point>`.
- [ ] Coordinates are `lon,lat[,alt]`, comma-separated, longitude first.
- [ ] Colors are `AABBGGRR` hex.
- [ ] Photos go in `gx_media_links` (whitespace-separated URLs), not `<img>` tags.
- [ ] Descriptions use plain sentences + `<br>` + http/https/mailto/tel links; wrapped in
      CDATA if they contain markup or `&`.
- [ ] For KMZ: main file is `doc.kml`; resources referenced by relative paths with no `..`
      or leading `/`.
- [ ] No ignored elements emitted as if they mattered (see "What Pinfold ignores").

## Minimal complete example

```xml
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2"
     xmlns:gx="http://www.google.com/kml/ext/2.2">
  <Document>
    <name>Lisbon Miradouros</name>
    <description>Best free viewpoints over the city.</description>

    <Style id="viewpoint">
      <IconStyle>
        <color>ff00a5ff</color>
        <scale>1.2</scale>
        <Icon><href>https://example.com/icons/binoculars.png</href></Icon>
      </IconStyle>
    </Style>

    <Folder>
      <name>Alfama &amp; Graça</name>

      <Placemark id="miradouro-senhora-do-monte">
        <name>Miradouro da Senhora do Monte</name>
        <description><![CDATA[The highest viewpoint in Lisbon — best at sunset.
Quiet on weekday mornings.
Map: https://example.com/spot]]></description>
        <styleUrl>#viewpoint</styleUrl>
        <ExtendedData>
          <Data name="Best time"><value>Sunset</value></Data>
          <Data name="gx_media_links">
            <value>https://example.com/photos/senhora-monte.jpg</value>
          </Data>
        </ExtendedData>
        <Point><coordinates>-9.1304,38.7197,0</coordinates></Point>
      </Placemark>

      <Placemark id="miradouro-portas-do-sol">
        <name>Miradouro das Portas do Sol</name>
        <description>Terrace café with a view over Alfama's rooftops to the river.</description>
        <styleUrl>#viewpoint</styleUrl>
        <Point><coordinates>-9.1287,38.7119,0</coordinates></Point>
      </Placemark>

    </Folder>
  </Document>
</kml>
```
