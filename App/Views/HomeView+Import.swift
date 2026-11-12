import SwiftUI

extension HomeView {
    // MARK: - Import helpers

    func handleFileImporterResult(_ result: Result<[URL], Error>) {
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

// MARK: - Import progress label

/// A spinner plus the current filename, shown in the bottom bar while the import coordinator is
/// draining its queue.
struct ImportProgressLabel: View {
    let filename: String?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
            if let name = filename {
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

// MARK: - Import alerts

/// The duplicate-file and import-failure alerts, driven by the import coordinator. A
/// `ViewModifier` so `HomeView.body`'s chain stays inside the type-checker's budget.
struct ImportAlertsModifier: ViewModifier {
    let importCoordinator: ImportCoordinator
    @Environment(Catalog.self) private var catalog
    @Environment(\.resourceCache) private var resourceCache

    func body(content: Content) -> some View {
        content
            .alert(
                duplicateTitle,
                isPresented: Binding(
                    get: { importCoordinator.pendingDuplicate != nil },
                    // Route dismissal through skipDuplicate so the import queue always
                    // advances, even if the alert is dismissed without tapping a button.
                    // skipDuplicate is idempotent, so the button paths are unaffected.
                    set: {
                        if !$0 {
                            skip()
                        }
                    }
                ),
                presenting: importCoordinator.pendingDuplicate
            ) { dup in
                duplicateButtons(for: dup.kind)
            } message: { dup in
                Text(duplicateMessage(for: dup))
            }
            // Import error alert
            .alert(
                "Import Failed",
                isPresented: Binding(
                    get: { importCoordinator.importError != nil },
                    set: {
                        if !$0 {
                            importCoordinator.importError = nil
                        }
                    }
                ),
                presenting: importCoordinator.importError
            ) { _ in
                Button("OK", role: .cancel) {
                    importCoordinator.importError = nil
                }
            } message: { error in
                Text(error.localizedDescription)
            }
    }

    // MARK: - Duplicate alert

    private var duplicateTitle: LocalizedStringKey {
        importCoordinator.pendingDuplicate?.kind == .trashed ? "File in Trash" : "Duplicate File"
    }

    private func duplicateMessage(for dup: ImportCoordinator.DuplicateAlert) -> LocalizedStringKey {
        let name = dup.result.displayName
        return switch dup.kind {
        case .active:
            "\"\(name)\" has already been imported. Would you like to import it again?"
        case .trashed:
            "\"\(name)\" is already in the Trash. Restore it, or import a new copy?"
        }
    }

    @ViewBuilder
    private func duplicateButtons(for kind: ImportCoordinator.DuplicateKind) -> some View {
        switch kind {
        case .active:
            Button("Import Anyway") { importAnyway() }
        case .trashed:
            Button("Restore from Trash") {
                importCoordinator.restoreTrashedDuplicate(
                    catalog: catalog, storage: catalog.storage, cache: resourceCache
                )
            }
            Button("Import as New") { importAnyway() }
        }
        Button("Skip", role: .cancel) { skip() }
    }

    private func importAnyway() {
        importCoordinator.importAnyway(catalog: catalog, storage: catalog.storage, cache: resourceCache)
    }

    private func skip() {
        importCoordinator.skipDuplicate(catalog: catalog, storage: catalog.storage, cache: resourceCache)
    }
}
