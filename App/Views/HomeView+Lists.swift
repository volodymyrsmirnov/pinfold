import SwiftUI

extension HomeView {
    // MARK: - File list

    @ViewBuilder
    var fileList: some View {
        if segment == .files {
            if isSearching {
                searchResults
            } else if active.isEmpty {
                ContentUnavailableView {
                    Label("No Files", systemImage: "map")
                } description: {
                    Text(ImportFormats.emptyCatalogueHint)
                }
            } else {
                // `List(selection:)` drives the detail column on regular width and pushes the
                // detail on compact width (collapsed split view) — replacing the old explicit
                // `NavigationLink(destination:)`. Selection is by entry id (see `selection`).
                List(selection: $selection) {
                    ForEach(displayedActive) { entry in
                        FileRow(entry: entry)
                            .tag(entry.id)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await catalog.moveToTrash(entry) }
                                } label: {
                                    Label("Trash", systemImage: "trash")
                                }
                            }
                            .contextMenu { activeRowMenu(for: entry) }
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
                TrashList(trashed: trashed)
            }
        }
    }

    // MARK: - Picker bar

    /// Segmented Files / Trash picker, pinned directly below the navigation bar.
    var pickerBar: some View {
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
}
