import PinfoldCore
import SwiftUI

// MARK: - KMLDetailView

/// Displays the folder/placemark hierarchy of a single imported KML/KMZ file.
///
/// On appearance the original file is loaded and parsed off the main actor. While
/// loading a `ProgressView` is shown; on error a `ContentUnavailableView` is shown.
///
/// A search field is rendered as the first (non-sticky) row of the list, styled like
/// the other groups. Typing in it filters the hierarchy in place — folders that contain
/// matches stay, the rest are pruned — so results remain grouped by category. Because the
/// search field lives in the list (not the navigation bar's search mode), the back and
/// map toolbar buttons stay visible while searching, and the map plots the filtered set.
struct KMLDetailView: View {
    // MARK: - Properties

    let entry: CatalogEntry

    // MARK: - Environment

    @Environment(\.storageLocations) private var storage

    // MARK: - State

    @State private var document: KMLDocument?
    @State private var loadError: Error?
    @State private var searchText = ""
    @State private var annotations: PlacemarkAnnotations?

    // MARK: - Body

    var body: some View {
        Group {
            if let error = loadError {
                ContentUnavailableView {
                    Label("Cannot Open File", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                }
            } else if let document {
                contentList(document)
            } else {
                ProgressView("Loading\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(entry.displayName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    if let document {
                        PlacemarkMapView(
                            placemarks: mappablePlacemarks,
                            document: document,
                            entry: entry
                        )
                    }
                } label: {
                    Image(systemName: "map")
                }
                .accessibilityLabel("Map")
                .disabled(mappablePlacemarks.isEmpty)
            }
        }
        .task(id: entry.id) {
            annotations = nil
            document = nil
            loadError = nil
            await loadDocument()
        }
        .environment(annotations)
    }

    // MARK: - Mappable placemarks

    /// Point placemarks to plot on the map: the current search results (all placemarks
    /// when the query is empty) filtered to those that have a coordinate.
    private var mappablePlacemarks: [KMLPlacemark] {
        guard let document else { return [] }
        return placemarksMatching(searchText, in: document).filter { $0.coordinate != nil }
    }

    // MARK: - Load document

    private func loadDocument() async {
        annotations = PlacemarkAnnotations(entry: entry, storage: storage)
        let fileURL = storage.originalFile(for: entry)
        do {
            let parsedKML = try await Task.detached(priority: .userInitiated) {
                // Materialize the original from iCloud first if it is a not-yet-downloaded
                // placeholder (no-op for local files). Off-main; a spinner shows meanwhile.
                let data = try UbiquityContainer.readDownloadingIfNeeded(fileURL)
                return try KMLReader.read(data: data)
            }.value
            document = parsedKML.document
        } catch {
            loadError = error
        }
    }

    // MARK: - Content list

    /// A single inset-grouped list: the search field row, then either the full hierarchy
    /// (no query) or the pruned hierarchy (active query). Folders are force-expanded while
    /// searching so matches nested in collapsed folders aren't hidden.
    @ViewBuilder
    private func contentList(_ document: KMLDocument) -> some View {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        List {
            searchSection
            if query.isEmpty {
                hierarchyContent(document.root, document: document, forceExpanded: false)
            } else if let root = filteredContainer(document.root, matching: query) {
                hierarchyContent(root, document: document, forceExpanded: true)
            } else {
                Section {
                    Text("No placemarks match \u{201C}\(query)\u{201D}.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Search field row

    /// The search field, rendered as the first list group with the same card styling as
    /// the others. It scrolls with the content (non-sticky) and never enters the navigation
    /// bar's search mode, so the back and map buttons stay visible while searching.
    private var searchSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search placemarks", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
        }
    }

    // MARK: - Hierarchy content

    /// The hierarchy rows for `root`, intended to be composed directly inside `contentList`'s
    /// `List` (it deliberately does not wrap itself in a `List`).
    @ViewBuilder
    private func hierarchyContent(_ root: KMLContainer, document: KMLDocument, forceExpanded: Bool) -> some View {
        // Root-level placemarks (before any folders)
        ForEach(root.placemarks) { placemark in
            placemarkLink(placemark, document: document)
        }
        // Root-level folders rendered as Sections
        ForEach(root.children) { container in
            AnyView(containerSection(container, document: document, forceExpanded: forceExpanded))
        }
    }

    // MARK: - Recursive container view (uses AnyView to break the self-referencing opaque type cycle)

    private func containerSection(_ container: KMLContainer, document: KMLDocument, forceExpanded: Bool) -> some View {
        Section {
            ForEach(container.placemarks) { placemark in
                placemarkLink(placemark, document: document)
            }
            ForEach(container.children) { child in
                AnyView(nestedContainerDisclosure(child, document: document, forceExpanded: forceExpanded))
            }
        } header: {
            Text(container.name ?? "Folder")
        }
    }

    @ViewBuilder
    private func nestedContainerDisclosure(
        _ container: KMLContainer,
        document: KMLDocument,
        forceExpanded: Bool
    ) -> some View {
        let content = Group {
            ForEach(container.placemarks) { placemark in
                placemarkLink(placemark, document: document)
            }
            ForEach(container.children) { child in
                AnyView(nestedContainerDisclosure(child, document: document, forceExpanded: forceExpanded))
            }
        }
        if forceExpanded {
            DisclosureGroup(container.name ?? "Folder", isExpanded: .constant(true)) { content }
        } else {
            DisclosureGroup(container.name ?? "Folder") { content }
        }
    }

    // MARK: - Placemark navigation link

    private func placemarkLink(_ placemark: KMLPlacemark, document: KMLDocument) -> some View {
        NavigationLink(destination: PlacemarkDetailView(
            placemark: placemark,
            document: document,
            entry: entry
        )) {
            PlacemarkRow(placemark: placemark, document: document, entry: entry)
        }
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
                .tint(.blue)
            }
        }
    }
}
