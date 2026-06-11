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
/// to pick KML/KMZ files. The gear toolbar button presents Settings as a modal sheet.
///
/// Layout: the `NavigationTitle` "Pinfold" stays in the nav bar; the segmented Picker
/// lives in a `safeAreaInset` bar above the List so it never replaces the title; empty
/// states are shown as `overlay`s on the List so `ContentUnavailableView` has the full
/// view bounds it needs to centre itself.
struct HomeView: View {
    // MARK: - Bindings

    /// The catalogue selection, owned by `RootView` (drives the detail column). Stored by
    /// entry id so it survives `catalog.reload()`; see `RootView.selectedEntryID`.
    @Binding var selection: CatalogEntry.ID?

    // MARK: - Environment

    @Environment(Catalog.self) private var catalog
    @Environment(ImportFailureLog.self) private var importFailureLog
    @Environment(AppCommands.self) private var appCommands
    @Environment(\.resourceCache) private var resourceCache

    // MARK: - Local state

    @State private var segment: Segment = .files
    /// Presents the `fileImporter` picker sheet. Distinct from
    /// `importCoordinator.isImporting`, which tracks the import *pipeline* being busy.
    @State private var isFileImporterPresented = false
    /// Presents the Settings sheet. Settings is a modal sheet (not a pushed/detail screen) so
    /// it covers the whole window on iPad/Mac rather than landing in one split column.
    @State private var isSettingsPresented = false
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
                    isFileImporterPresented = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
                // While an import is in flight, the button is disabled and a progress
                // indicator (below) takes its visual place — re-tapping mid-import is a no-op
                // anyway (the picker just enqueues more), but the spinner signals work is on.
                // Also disabled while a duplicate alert stalls the queue: the coordinator is
                // waiting on the user's decision, so offering more imports would contradict
                // the stalled state (queued URLs are kept either way).
                .disabled(importCoordinator.isImporting || importCoordinator.pendingDuplicate != nil)
            }
            // Import progress: a spinner plus the current filename, shown only while the
            // coordinator is draining its queue (e.g. a large KMZ that takes a moment).
            // Placed in the bottom bar (`.bottomBar`) rather than `.principal`: a principal
            // item REPLACES the navigation title on compact width, which made the "Pinfold"
            // title vanish mid-import. The status bar floats below the list and leaves the
            // title intact on every size class.
            if importCoordinator.isImporting {
                ToolbarItem(placement: .bottomBar) {
                    HStack(spacing: 8) {
                        ProgressView()
                        if let name = importCoordinator.currentFilename {
                            Text("Importing \(name)…")
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("Importing…")
                                .font(.subheadline)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
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
        // Settings as a modal sheet (was a pushed NavigationLink under the old single-stack
        // root). A sheet keeps Settings full-window on iPad/Mac instead of landing in one
        // split column, and wraps it in its own NavigationStack so its title bar renders.
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isSettingsPresented = false }
                        }
                    }
            }
        }
        // The "Import…" menu command (⌘I) flips a counter on AppCommands; presenting the
        // fileImporter here keeps that transient UI state owned by the view, not the scene.
        .onChange(of: appCommands.importRequested) { _, _ in
            isFileImporterPresented = true
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
                // `List(selection:)` drives the detail column on regular width and pushes the
                // detail on compact width (collapsed split view) — replacing the old explicit
                // `NavigationLink(destination:)`. Selection is by entry id (see `selection`).
                List(selection: $selection) {
                    ForEach(active) { entry in
                        FileRow(entry: entry)
                            .tag(entry.id)
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
