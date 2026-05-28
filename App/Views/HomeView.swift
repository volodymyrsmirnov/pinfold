import SwiftUI
import UniformTypeIdentifiers

// MARK: - Segment

private enum Segment: Hashable {
    case files
    case trash
}

// MARK: - ImportCoordinator

/// Manages the state machine for the file-import flow in `HomeView`.
///
/// Import is a two-phase pipeline: `prepare` runs off-main (hashing + parsing),
/// then `commit` runs on the main actor (writes files to disk). When a
/// duplicate SHA-256 is detected, the coordinator stalls and presents an alert so
/// the user can choose Import Anyway or Skip. After the user responds, the
/// coordinator moves on to the next URL in the queue.
///
/// `ImportCoordinator` is `@Observable` so `HomeView` can react to its state.
@MainActor @Observable
final class ImportCoordinator {
    // MARK: - Alert content

    struct DuplicateAlert {
        let result: ImportResult
        let existingEntry: CatalogEntry
    }

    // MARK: - Published state

    /// Non-nil while the duplicate-import alert is visible.
    var pendingDuplicate: DuplicateAlert?

    /// Non-nil when an import error should be presented to the user.
    var importError: Error?

    // MARK: - Private state

    private var queue: [URL] = []
    private var isProcessing = false

    // MARK: - Entry point

    /// Enqueues a set of security-scoped URLs for sequential import processing.
    func enqueue(_ urls: [URL], catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        queue.append(contentsOf: urls)
        if !isProcessing {
            processNext(catalog: catalog, storage: storage, cache: cache)
        }
    }

    // MARK: - Duplicate resolution

    /// Called when the user taps "Import Anyway" on the duplicate alert.
    func importAnyway(catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        guard let dup = pendingDuplicate else { return }
        pendingDuplicate = nil
        commit(dup.result, catalog: catalog, storage: storage, cache: cache)
        processNext(catalog: catalog, storage: storage, cache: cache)
    }

    /// Called when the user taps "Skip" on the duplicate alert, or when the alert is
    /// dismissed by any other means. Idempotent: if the alert was already resolved (e.g.
    /// via "Import Anyway"), this is a no-op so the queue is never advanced twice.
    func skipDuplicate(catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        guard pendingDuplicate != nil else { return }
        pendingDuplicate = nil
        processNext(catalog: catalog, storage: storage, cache: cache)
    }

    // MARK: - Private queue processing

    private func commit(_ result: ImportResult, catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        do {
            try ImportService.commit(result, storage: storage, cache: cache)
            Task { await catalog.reload() }
        } catch {
            importError = error
        }
    }

    private func processNext(catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        guard !queue.isEmpty else {
            isProcessing = false
            return
        }
        isProcessing = true
        let url = queue.removeFirst()
        Task {
            await self.importURL(url, catalog: catalog, storage: storage, cache: cache)
        }
    }

    private func importURL(
        _ url: URL,
        catalog: Catalog,
        storage: StorageLocations,
        cache: ResourceCache
    ) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            importError = error
            processNext(catalog: catalog, storage: storage, cache: cache)
            return
        }

        let result: ImportResult
        do {
            result = try ImportService.prepare(data: data, sourceFilename: url.lastPathComponent)
        } catch {
            importError = error
            processNext(catalog: catalog, storage: storage, cache: cache)
            return
        }

        if let existing = catalog.entry(withSHA256: result.contentSHA256) {
            // Stall the queue and show the duplicate alert; processNext runs after the
            // user responds.
            pendingDuplicate = DuplicateAlert(result: result, existingEntry: existing)
        } else {
            do {
                try ImportService.commit(result, storage: storage, cache: cache)
                // Await the reload so the next file's duplicate check sees this one.
                await catalog.reload()
            } catch {
                importError = error
            }
            processNext(catalog: catalog, storage: storage, cache: cache)
        }
    }
}

// MARK: - HomeView

/// The root screen of Pinfold.
///
/// Shows a segmented Files / Trash list. The "+" toolbar button opens a `fileImporter`
/// to pick KML/KMZ files. The gear toolbar button navigates to Settings (Chunk 4b stub).
///
/// Layout: the `NavigationTitle` "Pinfold" stays in the nav bar; the segmented Picker
/// lives in a `safeAreaInset` bar above the List so it never replaces the title; empty
/// states are shown as `overlay`s on the List so `ContentUnavailableView` has the full
/// view bounds it needs to centre itself.
struct HomeView: View {
    // MARK: - Environment

    @Environment(Catalog.self) private var catalog
    @Environment(\.resourceCache) private var resourceCache

    // MARK: - Local state

    @State private var segment: Segment = .files
    @State private var isImporting = false
    @State private var importCoordinator = ImportCoordinator()

    // MARK: - Computed partitions

    private var active: [CatalogEntry] {
        catalog.active
    }

    private var trashed: [CatalogEntry] {
        catalog.trashed
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            pickerBar
            fileList
        }
        .navigationTitle("Pinfold")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isImporting = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: SettingsView()) {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: allowedUTTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileImporterResult(result)
        }
        // Duplicate-import alert
        .alert(
            "Duplicate File",
            isPresented: Binding(
                get: { importCoordinator.pendingDuplicate != nil },
                // Route dismissal through skipDuplicate so the import queue always
                // advances, even if the alert is dismissed without tapping a button.
                // skipDuplicate is idempotent, so the button paths are unaffected.
                set: { if !$0 {
                    importCoordinator.skipDuplicate(
                        catalog: catalog, storage: catalog.storage, cache: resourceCache
                    )
                } }
            ),
            presenting: importCoordinator.pendingDuplicate
        ) { _ in
            Button("Import Anyway") {
                importCoordinator.importAnyway(
                    catalog: catalog,
                    storage: catalog.storage,
                    cache: resourceCache
                )
            }
            Button("Skip", role: .cancel) {
                importCoordinator.skipDuplicate(
                    catalog: catalog,
                    storage: catalog.storage,
                    cache: resourceCache
                )
            }
        } message: { dup in
            Text("\"\(dup.result.displayName)\" has already been imported. Would you like to import it again?")
        }
        // Import error alert
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { importCoordinator.importError != nil },
                set: { if !$0 { importCoordinator.importError = nil } }
            ),
            presenting: importCoordinator.importError
        ) { _ in
            Button("OK", role: .cancel) {
                importCoordinator.importError = nil
            }
        } message: { error in
            Text(error.localizedDescription)
        }
        // Inbox draining (share-extension handoff) is performed once in RootView's
        // .task on launch; it is intentionally NOT duplicated here.
    }

    // MARK: - File list

    @ViewBuilder
    private var fileList: some View {
        if segment == .files {
            if active.isEmpty {
                ContentUnavailableView {
                    Label("No Files", systemImage: "map")
                } description: {
                    Text("Import a KML or KMZ file using the + button.")
                }
            } else {
                List {
                    ForEach(active) { entry in
                        NavigationLink(destination: KMLDetailView(entry: entry)) {
                            FileRow(entry: entry)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await catalog.moveToTrash(entry) }
                            } label: {
                                Label("Trash", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await catalog.moveToTrash(entry) }
                            } label: {
                                Label("Trash", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        } else {
            if trashed.isEmpty {
                ContentUnavailableView {
                    Label("Trash is Empty", systemImage: "trash")
                } description: {
                    Text("Files you trash will appear here.")
                }
            } else {
                List {
                    ForEach(trashed) { entry in
                        FileRow(entry: entry)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await catalog.deleteForever(entry) }
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                                Button {
                                    Task { await catalog.restore(entry) }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    Task { await catalog.restore(entry) }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                Button(role: .destructive) {
                                    Task { await catalog.deleteForever(entry) }
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                            }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    // MARK: - Picker bar

    /// Segmented Files / Trash picker, pinned directly below the navigation bar.
    private var pickerBar: some View {
        Picker("View", selection: $segment) {
            Text("Files").tag(Segment.files)
            if trashed.isEmpty {
                Text("Trash").tag(Segment.trash)
            } else {
                Text("Trash (\(trashed.count))").tag(Segment.trash)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Import helpers

    private var allowedUTTypes: [UTType] {
        // Prefer UTType(filenameExtension:) for exact KML/KMZ match.
        // Fall back to .xml / .zip if the extension-derived type is unavailable.
        let kml = UTType(filenameExtension: "kml") ?? .xml
        let kmz = UTType(filenameExtension: "kmz") ?? .zip
        return [kml, kmz]
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            importCoordinator.enqueue(
                urls,
                catalog: catalog,
                storage: catalog.storage,
                cache: resourceCache
            )
        case let .failure(error):
            importCoordinator.importError = error
        }
    }
}
