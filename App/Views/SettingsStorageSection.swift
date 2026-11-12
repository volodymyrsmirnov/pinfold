import SwiftUI

/// The Storage section of Settings: how much disk the catalogue uses, and a button to clear
/// downloaded images.
struct SettingsStorageSection: View {
    @Environment(\.storageLocations) private var storage
    @Environment(\.resourceCache) private var resourceCache

    @State private var usage: StorageUsage?
    @State private var isClearing = false
    @State private var confirmClear = false

    var body: some View {
        Section {
            usageRow("Files", usage?.files)
            usageRow("Downloaded Images", usage?.downloadedImages)
            usageRow("Extracted Data", usage?.extractedData)
            clearButton
        } header: {
            Text("Storage")
        } footer: {
            Text(
                "Clearing downloaded images frees space. They come back the next time you open "
                    + "the file, as your Downloads setting allows. Images stored inside KMZ files stay."
            )
        }
        .task(id: storage.root) { await refresh() }
    }

    private var clearButton: some View {
        Button("Clear Downloaded Images", role: .destructive) { confirmClear = true }
            .disabled(isClearing || (usage?.downloadedImages ?? 0) == 0)
            .confirmationDialog(
                "Clear downloaded images?", isPresented: $confirmClear, titleVisibility: .visible
            ) {
                Button("Clear Images", role: .destructive) { Task { await clear() } }
            } message: {
                Text("They are downloaded again when you next open a file.")
            }
    }

    private func usageRow(_ title: LocalizedStringKey, _ bytes: Int64?) -> some View {
        LabeledContent(title) {
            if let bytes {
                Text(bytes, format: .byteCount(style: .file))
            } else {
                ProgressView()
            }
        }
    }

    private func refresh() async {
        usage = await StorageUsage.measureOffMain(in: storage)
    }

    private func clear() async {
        isClearing = true
        await clearDownloadedImages(storage: storage, cache: resourceCache)
        await refresh()
        isClearing = false
    }
}

/// Clears every entry's downloaded images off the main actor.
private nonisolated func clearDownloadedImages(storage: StorageLocations, cache: ResourceCache) async {
    await Task.detached(priority: .utility) { cache.clearAllDownloaded(in: storage) }.value
}
