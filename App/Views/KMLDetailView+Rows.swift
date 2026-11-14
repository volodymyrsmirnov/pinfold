import CoreLocation
import PinfoldCore
import SwiftUI

extension KMLDetailView {
    // MARK: - Content list

    /// A single inset-grouped list: the notices, then the flattened placemark outline.
    /// Rendering a flat `[PlacemarkOutline.Row]` (instead of nested `Section`/
    /// `DisclosureGroup` trees built via `AnyView`) lets `List` lazily realize and diff
    /// rows, and confines per-keystroke work to one memoized, debounced tree walk.
    @ViewBuilder
    func contentList(_ document: KMLDocument) -> some View {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        // Snapshot the user's location ONCE per list build so every row shares one fix instead
        // of re-reading `locationAuth` per row. `nil` → rows show no distance.
        let location = locationAuth.lastLocation
        ScrollViewReader { proxy in
            List {
                if let offer = networkLinkOffer {
                    networkLinkSection(offer)
                }
                remoteImagesSection
                if let outline {
                    // Only once the outline is built for this query: until then it still holds
                    // the previous (often unfiltered) set, and the row would map the wrong places.
                    if !query.isEmpty, outlineQuery == query, !outline.mappablePlacemarks.isEmpty {
                        searchResultsMapSection(count: outline.mappablePlacemarks.count)
                    }
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
                OrphanedNotesSection(notes: orphanedNotes)
            }
            .listStyle(.insetGrouped)
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .global)
            } action: { frame in
                rowFrames.listFrame = frame
            }
            // Appearance-bound AND change-bound: fires on appear (covers pop-back — the
            // "one more attempt when the list becomes visible again" case) and on every
            // completed outline rebuild via the generation counter (covers the fast-launch
            // race where rows land before the List attaches, and re-sorts that keep the
            // row count constant, like the nearest-first re-sort when the location fix
            // arrives on a folderless file).
            .task(id: outlineGeneration) {
                await applyPendingScroll(using: proxy)
            }
        }
    }

    // MARK: - Search results on the map

    /// While searching, a row that opens the map of just the matches. The system search bar
    /// hides the toolbar's Map button on iPhone, and closing search clears the query, so this
    /// is the way to map the results (the `.map(focusKey: nil)` route plots the live, filtered
    /// outline).
    func searchResultsMapSection(count: Int) -> some View {
        Section {
            NavigationLink(value: EntryRoute.map(focusKey: nil)) {
                Label {
                    if count == 1 {
                        Text("Show 1 Result on Map")
                    } else {
                        Text("Show \(count) Results on Map")
                    }
                } icon: {
                    Image(systemName: "map")
                }
            }
        }
    }

    // MARK: - Outline row

    /// Renders a single flattened outline row by kind, indented by its depth. Folder rows
    /// toggle their membership in `collapsedFolderIDs` (and rotate a chevron like a
    /// `DisclosureGroup`); while searching the outline ignores that set, so the chevron is
    /// shown expanded and tapping it has no visible effect until the query is cleared.
    @ViewBuilder
    func outlineRow(
        _ row: PlacemarkOutline.Row, document: KMLDocument, location: CLLocation?
    ) -> some View {
        switch row.kind {
        case let .folder(name, id):
            folderRow(name: name, id: id, descriptionHTML: document.root.container(atPath: id)?.descriptionHTML)
                .listRowInsets(EdgeInsets(top: 6, leading: leadingInset(row.depth), bottom: 6, trailing: 16))
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .global)
                } action: { frame in
                    rowFrames.frames[row.id] = frame
                }
                .onDisappear { rowFrames.frames[row.id] = nil }
        case let .placemark(placemark):
            placemarkLink(placemark, document: document, location: location)
                .listRowInsets(EdgeInsets(top: 6, leading: leadingInset(row.depth), bottom: 6, trailing: 16))
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .global)
                } action: { frame in
                    rowFrames.frames[row.id] = frame
                }
                .onDisappear { rowFrames.frames[row.id] = nil }
        }
    }

    /// Base list-row leading inset plus the per-depth indent.
    func leadingInset(_ depth: Int) -> CGFloat {
        16 + CGFloat(depth) * 16
    }

    /// A tappable folder header row with a disclosure chevron that rotates with the
    /// collapsed state. A non-empty search ignores the collapsed set, so the chevron is
    /// pinned open while searching.
    func folderRow(name: String, id: String, descriptionHTML: String? = nil) -> some View {
        let preview = Self.folderPreview(descriptionHTML)
        return HStack(spacing: 8) {
            folderToggle(name: name, id: id, preview: preview)
            if let descriptionHTML, preview != nil || descriptionHTML.contains("<img") {
                Button {
                    infoSheet = DescriptionSheetContent(id: "folder-\(id)", title: name, html: descriptionHTML)
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Folder description")
            }
        }
    }

    private func folderToggle(name: String, id: String, preview: String?) -> some View {
        let searching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        let collapsed = !searching && collapsedFolderIDs.contains(id)
        return Button {
            if collapsedFolderIDs.contains(id) {
                collapsedFolderIDs.remove(id)
            } else {
                collapsedFolderIDs.insert(id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    // Purely decorative; the Button's label/value/hint carry the semantics.
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let preview {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(searching)
        .accessibilityLabel(name)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        // String literal resolves as a LocalizedStringKey, so it localizes like Text.
        .accessibilityHint("Expands or collapses this folder.")
    }

    /// One plain-text line of a folder description (only the head is converted, so a huge
    /// description costs nothing per row render), or `nil` when there is nothing to show.
    ///
    /// Memoised by the converted head: rows re-render on every scroll/search/collapse change and
    /// the HTML-to-text conversion is far costlier than the lookup.
    static func folderPreview(_ html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        let head = String(html.prefix(2000)) as NSString
        if let cached = folderPreviewCache.object(forKey: head) {
            return cached.length == 0 ? nil : cached as String
        }
        let preview = AttributedHTML.plainText(head as String)
        folderPreviewCache.setObject(preview as NSString, forKey: head)
        return preview.isEmpty ? nil : preview
    }

    /// Folder-description heads mapped to their plain-text preview (empty string = none).
    private static let folderPreviewCache = NSCache<NSString, NSString>()

    // MARK: - Placemark navigation link

    /// Known accepted edge: two occurrences of the same POI share a `stableKey` (it hashes
    /// `name|lat|lon`), so both rows now push the FIRST occurrence's page — the same
    /// first-match semantics every existing deep link (Spotlight, favorites) already has.
    func placemarkLink(
        _ placemark: KMLPlacemark, document: KMLDocument, location: CLLocation?
    ) -> some View {
        NavigationLink(value: EntryRoute.placemark(stableKey: placemark.stableKey)) {
            PlacemarkRow(
                placemark: placemark,
                document: document,
                entry: entry,
                distance: PlacemarkDistance.format(from: location, to: placemark.coordinate)
            )
        }
        // Swipe right: the quick toggles plus Share, with the short labels swipe buttons need.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let annotations {
                Button {
                    annotations.toggleFavorite(placemark)
                } label: {
                    let on = annotations.isFavorite(placemark)
                    Label(on ? "Unfavorite" : "Favorite", systemImage: on ? "star.slash" : "star")
                }
                .tint(.yellow)

                Button {
                    annotations.toggleVisited(placemark)
                } label: {
                    let on = annotations.isVisited(placemark)
                    Label(on ? "Mark Unseen" : "Mark Seen", systemImage: on ? "eye.slash" : "eye")
                }
                .tint(.indigo)
            }
            if let url = PlacemarkActions.shareURL(for: placemark) {
                PlacemarkShareLink(placemark: placemark, url: url)
                    .tint(.blue)
            }
        }
        // Long press: the same actions as the place screen's "⋯" menu, from the same view.
        .contextMenu {
            PlacemarkActions(placemark: placemark, annotations: annotations)
        }
    }
}
