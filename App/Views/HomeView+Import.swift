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
            // Duplicate-import alert
            .alert(
                "Duplicate File",
                isPresented: Binding(
                    get: { importCoordinator.pendingDuplicate != nil },
                    // Route dismissal through skipDuplicate so the import queue always
                    // advances, even if the alert is dismissed without tapping a button.
                    // skipDuplicate is idempotent, so the button paths are unaffected.
                    set: {
                        if !$0 {
                            importCoordinator.skipDuplicate(
                                catalog: catalog, storage: catalog.storage, cache: resourceCache
                            )
                        }
                    }
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
}
