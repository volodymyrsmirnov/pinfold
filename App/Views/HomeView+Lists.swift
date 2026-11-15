import SwiftUI

extension HomeView {
    // MARK: - File list

    @ViewBuilder
    var fileList: some View {
        if segment == .files {
            if isSearching {
                searchResults
            } else if active.isEmpty {
                withListControls {
                    ContentUnavailableView {
                        Label("No Files", systemImage: "map")
                    } description: {
                        Text(ImportFormats.emptyCatalogueHint)
                    }
                }
            } else if isSelecting {
                selectionList
            } else {
                // `List(selection:)` drives the detail column on regular width and pushes the
                // detail on compact width (collapsed split view) — replacing the old explicit
                // `NavigationLink(destination:)`. Selection is by entry id (see `selection`).
                List(selection: $selection) {
                    Section {
                        ForEach(sortedActive) { entry in
                            activeFileRow(entry)
                        }
                    } header: {
                        listControls
                    }
                }
                .catalogueListStyle()
            }
        } else {
            if trashed.isEmpty {
                withListControls {
                    ContentUnavailableView {
                        Label("No Archived Files", systemImage: "archivebox")
                    } description: {
                        Text("Files you archive will appear here.")
                    }
                }
            } else if visibleTrashed.isEmpty {
                withListControls { ContentUnavailableView.search(text: trimmedQuery) }
            } else if isSelecting {
                selectionList
            } else {
                TrashList(trashed: visibleTrashed) { listControls }
            }
        }
    }

    // MARK: - List controls

    /// The sync notice, the Files / Archive picker and the import-failure banner. They are the
    /// header of the first section of whichever list is showing, so they scroll — and stretch on
    /// a pull-down — with the rows under the large title and search bar, as a file's own rows do.
    /// (Pinned above the list instead, the title never collapsed; pinned in a safe-area bar, a
    /// pull-down slid the title and search bar over them.)
    var listControls: some View {
        controlsStack
            // An inset-grouped header (iPhone) already lines up with the cards; a plain list's
            // (the iPad/Mac sidebar) runs edge to edge.
            .padding(.horizontal, showsRowDisclosure ? 0 : 16)
            // A section header is styled secondary and, in grouped lists, may be uppercased: these
            // are controls, not a caption.
            .foregroundStyle(.primary)
            .textCase(nil)
            .listRowInsets(EdgeInsets())
    }

    private var controlsStack: some View {
        VStack(spacing: 0) {
            SyncStatusBanner()
            pickerBar
            importFailureBanner
        }
    }

    /// `listControls` above content that isn't a list (an empty or no-results state).
    func withListControls(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            controlsStack
                .padding(.horizontal)
            content()
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Picker bar

    /// Segmented Files / Archive picker, at the top of the list (`listControls`).
    var pickerBar: some View {
        Picker("View", selection: $segment) {
            Text("Files").tag(Segment.files)
            if trashed.isEmpty {
                Text("Archive").tag(Segment.trash)
            } else {
                Text("Archive (\(trashed.count))").tag(Segment.trash)
            }
        }
        .pickerStyle(.segmented)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}
