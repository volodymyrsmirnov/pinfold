---
name: authoring-kml-for-pinfold
description: Use when generating, writing, authoring, converting, or exporting a .kml or .kmz file that will be imported into Pinfold (the offline KML/KMZ catalogue app for iPhone, iPad, and Mac). Covers exactly which KML elements Pinfold parses and renders — placemarks, points, lines, polygons, tracks, shared and inline styles, AABBGGRR colors, descriptions, photos, ExtendedData, KMZ packaging — which it ignores or rejects, and how GPX and GeoJSON files map onto the same model.
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

1. **Use `<Point>` placemarks for anything that is a place.** Only point placemarks get a
   regular map pin, appear on the Favorites map, and can be sorted nearest-first. Search is
   broader: it matches the placemark's name, its description text, ExtendedData values,
   `<Snippet>` and `<address>` (plus the user's own notes) — but the name is what lists show,
   so make it specific.
2. **Put human-readable info in `<name>` and `<description>`.** `name` = a short title;
   `description` = the body (rendered natively — see Descriptions).
3. **Prefer shared styles: define them once at the `<Document>` level and reference them
   with `<styleUrl>`.** Inline `<Style>`/`<StyleMap>` inside a `<Placemark>` also work (they
   are merged over the placemark's `styleUrl` style, inline fields winning), but shared
   styles keep the file small and consistent.
4. **Coordinates are `longitude,latitude[,altitude]`** — longitude first, comma-separated,
   tuples separated by whitespace. (Standard KML, but the #1 source of swapped pins.)
5. **Photos for the gallery go in a `gx_media_links` ExtendedData field.** `<img>` tags in a
   description are shown inline, but only once the image is in the local cache (packaged in
   the KMZ, or downloaded at import when the user's image setting allows it).
6. **Do not include a `<!DOCTYPE>` declaration.** A bare one with no internal subset
   (`<!DOCTYPE kml>`) is tolerated and never fetched, but any DOCTYPE with a `[` internal
   subset (entity, element or attribute declarations) **rejects the entire file**. There is
   no reason to emit one, so don't.
7. **Tags, favorites, "visited" and notes are set by the user inside the app — not in the
   KML.** Don't try to encode them. (You *can* influence organization via `<Folder>`
   structure.)
8. **Write UTF-8.** UTF-16/UTF-32 (with or without a BOM), ASCII, Latin-1, ISO-8859-x and
   Windows-125x also work; any other declared encoding (UTF-7, EBCDIC, …) rejects the file.

## Document skeleton (copy this shape)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2"
     xmlns:gx="http://www.google.com/kml/ext/2.2">
  <Document>
    <name>Reykjavík Coffee Crawl</name>
    <description>Twelve specialty cafés worth a detour, gathered June 2026.</description>

    <!-- 1. Shared styles first, at Document level, each with a stable id -->
    <Style id="cafe">
      <IconStyle>
        <color>ff4287f5</color>      <!-- AABBGGRR: opaque, blue-ish -->
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
- The root element must be `<kml>` (a bare `<Document>`, `<Folder>` or `<Placemark>` root is
  also accepted). Any other XML root is rejected as not a KML file.
- The `gx:` namespace declaration is only needed if you use `gx_media_links` or `<gx:Track>`.
- Leading whitespace, a byte-order mark, and stray control characters before or inside the
  document are tolerated, but don't rely on that — start with the XML declaration.

## What Pinfold reads — supported elements

Use **only** these. Everything else is parsed-and-discarded (see "What Pinfold ignores").

### Structure
| Element | Notes |
|---|---|
| `<Document>` | Root container. Its `name`/`description` become the catalogue entry's; the description opens from an info button on the file screen. |
| `<Folder>` | Groups placemarks; nestable to any depth. `name` shows as a section header; a folder `description` is previewed under that header and opens in full from its info button. |
| `<Placemark>` | The unit of content. Add `id="..."` for stable identity (see Stable identity). |
| `<name>` | Title. Searchable, and what lists show. Keep it specific and human. |
| `<description>` | Body. Searchable (its plain text). See Descriptions for how HTML is treated. |
| `<Snippet>` | Short teaser. Replaces the description's first line as the list preview under the name. Searchable. |
| `<address>` | Shown as an address row in the placemark detail. Searchable. |
| `<phoneNumber>` | Shown as a tappable call row in the placemark detail. |

### Geometry (coordinates are `lon,lat[,alt]`)
| Element | Renders as | Notes |
|---|---|---|
| `<Point>` | Map pin + locatable entry | **Strongly preferred.** Only the *first* coordinate tuple is used. |
| `<LineString>` | Polyline overlay (tappable) | All tuples used. Styled by `LineStyle`. Needs at least 2 vertices. |
| `<Polygon>` | Filled/stroked area (tappable) | Use `<outerBoundaryIs>` + optional `<innerBoundaryIs>` holes. Styled by `PolyStyle`/`LineStyle`. Rings need at least 3 vertices. |
| `<gx:Track>` | Polyline overlay + a pin at its start | Each `<gx:coord>` is **space-separated** `lon lat alt` (different from `<coordinates>`!). Timestamps in `<when>` are ignored. |
| `<gx:MultiTrack>` | Each inner `<gx:Track>` rendered | Treated as its tracks; `<gx:interpolate>` is ignored. |
| `<MultiGeometry>` | Each child rendered independently | Fine to mix a Point + LineString in one placemark. With several `<Point>`s, the **first** is the placemark's own location and **every extra point gets its own pin** (all opening the same placemark). |

Coordinate whitespace is tolerant: `-9.13, 38.71, 0` (spaces after commas) parses the same as
`-9.13,38.71,0`; whitespace *without* a comma starts the next tuple.

A placemark **without a `<Point>`** (only a line/polygon) still appears in the list and is
searchable; on the map its line or area is the tappable target and there is no pin. It is
located by its first vertex but is not shown on the Favorites map or sorted by distance. If
it represents a place, also include a `<Point>`.

### Styling
Define shared styles at the `<Document>` level (any level outside a placemark works) and
reference them by id. Inline styles inside a placemark are also read.

| Element | Fields Pinfold reads | Ignored fields |
|---|---|---|
| `<Style id="…">` | the sub-styles below | `<LabelStyle>`, `<BalloonStyle>`, `<ListStyle>` |
| `<IconStyle>` | `<color>`, `<Icon><href>` | `<scale>` (pins and icons are drawn at a fixed size), `<hotSpot>`, `<heading>` |
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
- **Reference shared styles by id:** `<styleUrl>#cafe</styleUrl>`.
- **Inline styles:** a `<Style>` (or a `<StyleMap>` whose `normal` pair holds one) inside a
  `<Placemark>` applies to that placemark only. Its fields override the placemark's
  `<styleUrl>` style field by field, so `<styleUrl>#trail</styleUrl>` plus an inline
  `<LineStyle><width>6</width></LineStyle>` thickens one trail while keeping the shared
  color.

### ExtendedData (custom key/value facts)
Use either form; both surface in the placemark detail view as label → value rows:

```xml
<ExtendedData>
  <Data name="hours"><displayName>Hours</displayName><value>08:00–18:00</value></Data>
  <Data name="wifi"><value>Free</value></Data>
</ExtendedData>
```

- A `<Data>` element's `<displayName>` is used as the row label; without one the `name`
  attribute is shown.
- `<SimpleData name="…">` inside `<SchemaData>` also works (the values are read, labelled by
  their `name`), but the `<Schema>` definition is ignored — including its
  `<SimpleField><displayName>` — so the simpler `<Data>` form is preferred.
- ExtendedData **values are searchable**, alongside names, descriptions, snippets and
  addresses. Repeated names are all kept.

## Photos — the `gx_media_links` pattern

This is the way to attach a photo **gallery** to a placemark. Provide one or more
**http/https** URLs, separated by whitespace, inside a `<Data name="gx_media_links">` value:

```xml
<ExtendedData>
  <Data name="gx_media_links">
    <value>https://example.com/photos/cafe-1.jpg https://example.com/photos/cafe-2.jpg</value>
  </Data>
</ExtendedData>
```

- Remote photo (and icon) URLs are downloaded and cached locally so they work offline later —
  **subject to the user's "Download Images" setting** (Always, Ask per file, or Never). With
  Never, or before the user allows it, remote images do not appear. At most 500 distinct
  remote images per file are fetched.
- In a **KMZ**, you may instead reference a packaged image by a relative path (see KMZ
  packaging). Packaged images always display, whatever the setting.

## Descriptions — how HTML is treated

The description is rendered natively (no web view) as a small set of blocks:

- **Paragraphs and line breaks:** `<p>`, `<div>`, `<br>` and other block-level tags break
  lines; headings `<h1>`–`<h6>` render as bold paragraphs.
- **Inline formatting:** `<b>`/`<strong>` render bold, `<i>`/`<em>` italic.
- **Lists:** `<ul>`/`<ol>` with `<li>` render as bulleted/numbered lists.
- **Tables:** `<table>`/`<tr>`/`<td>`/`<th>` render as rows of cells (`<th>` bold) — a
  two-column key/value table, as Google My Maps exports, reads well.
- **Images:** `<img src="…">` renders inline **only from the local cache**: a relative path
  packaged in the KMZ, or an http(s) URL downloaded at import per the user's Download Images
  setting. Nothing is loaded when the description is viewed. `data:` and other schemes are
  never shown. Use `alt` text — it is shown when the image is not available.
- **Links:** an `<a href="…">label</a>` becomes a tappable link, but only for the schemes
  `http`, `https`, `mailto`, and `tel`. Other schemes (`javascript:`, `data:`, `file:`) render
  as plain text. Bare URLs, emails, and phone numbers are auto-linked.
- Everything else (`<span>`, `<font>`, CSS, scripts, forms) is reduced to its text.
- You may wrap the description in `<![CDATA[ … ]]>` if it contains markup or `&`/`<`
  characters — preferred when including HTML.

**Recommended description style:**

```xml
<description><![CDATA[<p>Tiny third-wave café with a rotating single-origin bar.</p>
<ul><li>Cash only</li><li>Closed Mondays</li></ul>
<p>Reservations: tel:+3545551234<br>More: https://example.com/cafe</p>]]></description>
```

Keep descriptions concise and front-load the important sentence: lists show a one-line
preview (unless a `<Snippet>` is given), and only the first ~1,000 characters of a
description's text are searchable. Very long descriptions are truncated for display.

## Images — embedding and linking

Pinfold shows images in three places. All three use the same two sources.

| Where it shows | How to declare it |
|---|---|
| **Pin icon** on the map and in the list | `<Style><IconStyle><Icon><href>…</href></Icon></IconStyle></Style>` |
| **Row thumbnail and photo gallery** on the place page | `<Data name="gx_media_links"><value>…</value></Data>` in the placemark's `ExtendedData`, with whitespace-separated paths or URLs; the **first** one is the row thumbnail |
| **Inline image** in a place, folder or document description | `<img src="…" alt="…">` inside the `<description>` HTML |

Images are **never fetched while the user is looking at the screen**. Pinfold shows only images already stored on the device, so every image must be either embedded or downloadable.

### Option A (recommended): embed images in a KMZ

A KMZ is a ZIP. Put `doc.kml` at the root and the images in a subfolder:

```
Places.kmz
├── doc.kml
└── images/
    ├── pin-cafe.png
    ├── cafe-1.jpg
    └── cafe-2.jpg
```

Reference each image by its **path inside the archive, relative to `doc.kml`**, using the same string in all three places:

```xml
<Style id="cafe">
  <IconStyle><Icon><href>images/pin-cafe.png</href></Icon></IconStyle>
</Style>

<Placemark>
  <name>Café Majestic</name>
  <styleUrl>#cafe</styleUrl>
  <description><![CDATA[
    <p><b>Café Majestic</b>, open since 1921.</p>
    <img src="images/cafe-2.jpg" alt="The dining room">
  ]]></description>
  <ExtendedData>
    <Data name="gx_media_links"><value>images/cafe-1.jpg images/cafe-2.jpg</value></Data>
  </ExtendedData>
  <Point><coordinates>-8.6069,41.1469,0</coordinates></Point>
</Placemark>
```

Build the archive from inside the folder, so `doc.kml` sits at the archive root:

```bash
cd Places && zip -r -X ../Places.kmz doc.kml images
```

Rules for embedded paths. Pinfold matches the string exactly, with no normalisation:
- Write the path exactly as it is stored in the archive, with the same letter case. Don't prefix it with `./` and don't percent-encode it.
- **No spaces in image file names.** `gx_media_links` is split on whitespace, so `my photo.jpg` becomes two broken links. Use lowercase, hyphens and ASCII, like `cafe-1.jpg`.
- No absolute paths (`/…`) and no `..`. Such entries are skipped on import.
- Embedded images always display, whatever the user's "Download Images" setting, and they work offline from the first launch.

### Option B: link public web images

Use full `https://` URLs in the same three places. Pinfold downloads each image once, at import, and keeps it for offline use:
- The URL must be **publicly reachable without a sign-in, cookies or a referer**. Links that need a Google account return "403 Forbidden" and never appear: the `lh3.googleusercontent.com/umsh/…` photo links in Google My Maps exports are the common case. Host the images somewhere public, or embed them (Option A).
- Downloads follow the user's **Download Images** setting: Always (the default), Ask per file, or Never. Under Ask or Never, remote images stay empty until the user allows them.
- At most **500** distinct remote images per file, and **20 MB** per image. Over-size images are skipped. Pin icons are kept first under the 500 limit.
- A failed download (server error, offline) is retried later with a growing delay. Meanwhile the row shows a grey photo placeholder.

### Formats and sizes

- **Formats:** PNG, JPEG, GIF, WebP, BMP, TIFF and HEIC/HEIF/AVIF. SVG is not supported. A download that isn't one of these, such as an HTML error page, is not shown.
- **Pin icons:** square PNG, 64–128 px, transparent background. Icons are shown as-is: `IconStyle` `<color>` does not tint an icon image, and `<scale>` is ignored.
- **Photos:** JPEG, at most about 1600 px on the long edge, ideally 100–300 KB each. Row thumbnails and gallery tiles are **square crops of the centre**, so keep the subject centred.
- Give description images `alt` text. It is shown when the image is not available.

The repository's `samples/` folder has a complete example of each option: `Image Sample (offline).kmz` (everything embedded) and `Image Sample (online).kml` (public Wikimedia Commons links).

## KMZ packaging (when bundling icons/photos)

Produce a `.kmz` (a ZIP) when you want icons or photos to travel **inside** the file instead
of being fetched from the network.

- The main document should be named **`doc.kml`** at the archive root. (Without one,
  Pinfold picks the first top-level `.kml` alphabetically, but `doc.kml` is the unambiguous
  convention.)
- Reference packaged resources by a **relative path** from `doc.kml`:
  ```xml
  <Icon><href>icons/coffee.png</href></Icon>
  ```
  and place the file at `icons/coffee.png` in the archive.
- Path rules enforced on import: **no absolute paths** (`/…`), **no `..` traversal**. Keep
  everything in subfolders under the archive root.
- The same relative paths work for `gx_media_links` photos and for `<img src="…">` in
  descriptions. Write each path exactly as it appears in the archive.
- Size limits: the root KML may be up to 256 MiB uncompressed, all packaged resources
  together up to 1 GiB, and the archive at most 100,000 entries. A plain `.kml` file is
  capped at 256 MiB.

Use plain `.kml` + remote `https://` hrefs when the file should stay tiny and the user is
happy to download images; use `.kmz` with packaged resources for fully self-contained,
offline-first bundles that display regardless of the image-download setting.

## What Pinfold IGNORES — don't bother emitting these

These parse without error but have **no effect**. Including them adds noise; omit them.

- `<LabelStyle>`, `<BalloonStyle>`, `<ListStyle>` → ignored.
- The `highlight` pair of a `<StyleMap>` → ignored.
- `<TimeStamp>`, `<TimeSpan>`, `<gx:TimeSpan>`, `<gx:Track>` timestamps → ignored.
- `<Region>`, `<LatLonAltBox>`, `<Lod>` → ignored.
- `<altitudeMode>` / `<gx:altitudeMode>` → ignored (altitude *values* are kept but the mode
  is not; Pinfold renders in 2D, so altitude has no visible effect).
- `<NetworkLink>` → **never fetched automatically.** If a file contains *only* network links
  (no placemarks of its own), Pinfold offers a one-time download of the linked http(s) files,
  which runs only when the user confirms it; the result is a static copy that is not
  refreshed. Prefer inlining the content into the file instead.
- `<GroundOverlay>`, `<ScreenOverlay>`, `<PhotoOverlay>` → ignored.
- `<Model>` → not rendered (a placemark whose only geometry is a `<Model>` is dropped).
- `<visibility>`, `<open>` → ignored.
- `<Schema>` field definitions (including `<SimpleField><displayName>`) → ignored (only
  `<SimpleData>`/`<Data>` *values* are read).
- IconStyle `<scale>`/`<hotSpot>`/`<heading>`, PolyStyle `<outline>`, `<colorMode>` →
  ignored.

## Stable identity & good-citizen details

- **Give each `<Placemark>` an `id`** (e.g. `id="cafe-roasters"`). Pinfold uses it as the
  durable key for favorites, "visited" marks, notes, search results, and Spotlight deep
  links, so a re-import or edited file keeps the user's per-placemark state. Without an `id`,
  identity falls back to a hash of name+first coordinate — stable only if those don't change.
- Make `id` values **unique and slug-like** within the file.
- Always provide a `<name>` on every placemark — nameless placemarks look broken in lists
  and on the map.
- Validate coordinates: longitude in `[-180, 180]`, latitude in `[-90, 90]`. `NaN`/infinite
  values are rejected; out-of-range finite values are accepted but will look wrong.

## Common mistakes

| Mistake | Fix |
|---|---|
| Copy-pasting the same inline `<Style>` into every placemark | Works, but define it once at `<Document>` level and reference it via `<styleUrl>#id</styleUrl>`. |
| `lat,lon` coordinates | KML is **`lon,lat`** — longitude first. |
| RGBA / `#rrggbb` colors | Use **`AABBGGRR`** hex (alpha first, then blue, green, red). |
| Relying on remote `<img>` URLs for essential pictures | They show only if the user allows downloads. Package them in a KMZ, or use `gx_media_links` for a gallery. |
| A `<!DOCTYPE>` with an internal subset (`[ <!ENTITY …> ]`) | Remove the DOCTYPE entirely — a subset rejects the whole file. |
| Relying on `<NetworkLink>` / overlays / 3D | Not rendered (network links only via a one-time, user-confirmed download). Inline the content; use Point/Line/Polygon geometry. |
| Nameless placemarks | Every placemark needs a clear `<name>`. |
| Places drawn only as a line or polygon | Add a `<Point>` so the place gets a pin and appears on the Favorites map. |

## Pre-flight checklist

Before emitting the file, verify:

- [ ] No `<!DOCTYPE>` anywhere (and never one with a `[` internal subset).
- [ ] UTF-8 encoding (or no `encoding` attribute).
- [ ] One top-level `<Document>` with a `<name>`.
- [ ] Shared `<Style>`/`<StyleMap>` at Document level, each with an `id`, referenced via
      `<styleUrl>#id</styleUrl>`; inline styles only for genuine one-off overrides.
- [ ] Every placemark has a unique `id`, a clear `<name>`, and (ideally) a `<Point>`.
- [ ] Coordinates are `lon,lat[,alt]`, comma-separated, longitude first.
- [ ] Colors are `AABBGGRR` hex.
- [ ] Photo galleries go in `gx_media_links` (whitespace-separated URLs or KMZ paths).
- [ ] Every image is either embedded in the KMZ (path written exactly as in the archive, no
      spaces in file names) or a public `https://` URL that loads without a sign-in.
- [ ] Images are PNG/JPEG/GIF/WebP/HEIC (no SVG), icons 64–128 px, photos ≤ ~1600 px.
- [ ] Descriptions use paragraphs, bold/italic, lists, tables and http/https/mailto/tel
      links; wrapped in CDATA if they contain markup or `&`; the key sentence comes first.
- [ ] For KMZ: main file is `doc.kml`; resources referenced by relative paths with no `..`
      or leading `/`; within the size limits.
- [ ] No ignored elements emitted as if they mattered (see "What Pinfold ignores").

## Other formats Pinfold imports

Pinfold also imports **GPX** and **GeoJSON** (detected by content, not extension) into the
same model. Prefer KML when you control the output — it is the only format with folders,
icons and full styling — but these mappings tell you what survives:

**GPX (1.0/1.1)**
- `<metadata><name>`/`<desc>` → the file's name and description.
- Each `<wpt>` → a point placemark (`ele` kept as altitude). Each `<trk>` → one placemark
  with a track per `<trkseg>` (pin at its start). Each `<rte>` → one placemark with a line.
- `name` → name; `desc` (else `cmt`) plus an http(s) `link`/`url` → description; `sym`,
  `type`, `time` (and `cmt` when `desc` is present) → ExtendedData rows.
- When more than one kind is present, placemarks are grouped into "Waypoints", "Tracks" and
  "Routes" folders. `<extensions>` are ignored. Same DOCTYPE and encoding rules as KML.

**GeoJSON (RFC 7946)**
- A `FeatureCollection`, a single `Feature`, or a bare geometry; one flat list of placemarks
  (no folders). A top-level `"name"` on the collection becomes the file name.
- Positions are `[lon, lat, alt?]`. `Point` → pin; `MultiPoint` → first point is the pin,
  each further point gets its own pin; `LineString`/`MultiLineString` → lines;
  `Polygon`/`MultiPolygon` → areas (first ring outer, the rest holes); `GeometryCollection`
  → its members.
- Feature `id` → stable identity. `properties.name` (else `title`) → name;
  `properties.description` → description (HTML kept, plain text escaped).
- simplestyle keys become a style: `marker-color` (pin tint), `stroke`, `stroke-width`,
  `stroke-opacity`, `fill`, `fill-opacity` (colors as `#rgb`/`#rrggbb`). `marker-size` and
  `marker-symbol` are ignored. Every other property → an ExtendedData row (nested values
  shown as JSON).
- Invalid JSON (including out-of-range numbers such as `1e999`) rejects the whole file.

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
        <Icon><href>https://example.com/icons/binoculars.png</href></Icon>
      </IconStyle>
    </Style>

    <Folder>
      <name>Alfama &amp; Graça</name>
      <description>The old town's eastern hills.</description>

      <Placemark id="miradouro-senhora-do-monte">
        <name>Miradouro da Senhora do Monte</name>
        <Snippet>Highest viewpoint in Lisbon</Snippet>
        <description><![CDATA[<p>The highest viewpoint in Lisbon — <b>best at sunset</b>.</p>
<p>Quiet on weekday mornings.<br>Map: https://example.com/spot</p>]]></description>
        <styleUrl>#viewpoint</styleUrl>
        <ExtendedData>
          <Data name="best_time"><displayName>Best time</displayName><value>Sunset</value></Data>
          <Data name="gx_media_links">
            <value>https://example.com/photos/senhora-monte.jpg</value>
          </Data>
        </ExtendedData>
        <Point><coordinates>-9.1304,38.7197,0</coordinates></Point>
      </Placemark>

      <Placemark id="miradouro-portas-do-sol">
        <name>Miradouro das Portas do Sol</name>
        <description>Terrace café with a view over Alfama's rooftops to the river.</description>
        <!-- A one-off inline style: a tinted built-in pin, no shared style needed -->
        <Style><IconStyle><color>ff3c14dc</color></IconStyle></Style>
        <Point><coordinates>-9.1287,38.7119,0</coordinates></Point>
      </Placemark>

    </Folder>
  </Document>
</kml>
```
