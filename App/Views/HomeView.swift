import SwiftUI
import UniformTypeIdentifiers

// MARK: - Segment

private enum Segment: Hashable {
    case files
    case trash
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
    @Environment(ImportFailureLog.self) private var importFailureLog
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
            importFailureBanner
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

    // MARK: - Import failure banner

    /// A dismissible banner listing recent import failures (parse or I/O) from any arrival
    /// path. Non-empty only when `ImportFailureLog` has recorded failures; "Clear" empties it.
    @ViewBuilder
    private var importFailureBanner: some View {
        if !importFailureLog.failures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label {
                        if importFailureLog.failures.count == 1 {
                            Text("1 file couldn't be imported")
                        } else {
                            Text("\(importFailureLog.failures.count) files couldn't be imported")
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Clear") { importFailureLog.clear() }
                        .font(.subheadline)
                }
                ForEach(importFailureLog.failures.prefix(5)) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.filename)
                            .font(.footnote.weight(.medium))
                        Text(failure.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // VoiceOver reads filename + reason as one element per failure.
                    .accessibilityElement(children: .combine)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
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
