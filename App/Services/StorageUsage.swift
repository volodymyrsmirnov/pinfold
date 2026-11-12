import Foundation

/// How much disk the catalogue uses, split the way Settings presents it.
struct StorageUsage: Equatable {
    /// Original files and `metadata.json` sidecars in the active root.
    var files: Int64
    /// Downloaded images (manifest entries keyed by an http(s) href).
    var downloadedImages: Int64
    /// Everything else in the resources folders: KMZ-extracted media, search indexes, bookkeeping.
    var extractedData: Int64

    static let zero = StorageUsage(files: 0, downloadedImages: 0, extractedData: 0)

    var total: Int64 {
        files + downloadedImages + extractedData
    }

    /// Measures `storage`. Synchronous and disk-bound: call off the main actor
    /// (see `measureOffMain(in:)`). Reads sizes only under the storage roots.
    static func measure(in storage: StorageLocations) -> StorageUsage {
        var usage = StorageUsage.zero
        for name in (try? StorageLocations.entryFolderNames(in: storage.root)) ?? [] {
            let folder = storage.root.appendingPathComponent(name, isDirectory: true)
            usage.files += size(of: folder, skippingNamed: StorageLocations.reservedCacheFolderName)
        }
        for name in (try? StorageLocations.entryFolderNames(in: storage.cacheRoot)) ?? [] {
            let resources = storage.resourcesDirectory(forFolderNamed: name)
            let split = resourcesSplit(resources)
            usage.downloadedImages += split.downloaded
            usage.extractedData += split.other
        }
        return usage
    }

    /// `measure(in:)` on a background thread.
    static func measureOffMain(in storage: StorageLocations) async -> StorageUsage {
        await runMeasure(storage)
    }

    // MARK: - Helpers

    private static func resourcesSplit(_ dir: URL) -> (downloaded: Int64, other: Int64) {
        let manifest = ResourceManifestStore.shared.manifest(in: dir)
        var downloadedNames = Set<String>()
        for (key, filename) in manifest where !filename.isEmpty {
            if ResourceCache.isRemoteHref(key) {
                downloadedNames.insert(filename)
            }
        }
        var downloaded: Int64 = 0
        var other: Int64 = 0
        for url in files(under: dir, skippingNamed: nil) {
            let bytes = allocatedSize(of: url)
            if downloadedNames.contains(url.lastPathComponent) {
                downloaded += bytes
            } else {
                other += bytes
            }
        }
        return (downloaded, other)
    }

    private static func size(of folder: URL, skippingNamed skipped: String) -> Int64 {
        // In the single-root layout the resources folder lives inside the entry folder; it is
        // counted by the resources pass, not as a user file.
        files(under: folder, skippingNamed: skipped).reduce(0) { $0 + allocatedSize(of: $1) }
    }

    /// Regular files below `dir`, not descending into a directory named `skipped`.
    private static func files(under dir: URL, skippingNamed skipped: String?) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                if url.lastPathComponent == "resources", skipped != nil {
                    enumerator.skipDescendants()
                }
            } else {
                result.append(url)
            }
        }
        return result
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }
}

/// Runs the measurement detached; kept as a free function so the closure stays small.
private nonisolated func runMeasure(_ storage: StorageLocations) async -> StorageUsage {
    await Task.detached(priority: .utility) { StorageUsage.measure(in: storage) }.value
}

extension ResourceCache {
    /// Clears the downloaded images of every entry under `storage` (see `clearDownloaded(in:)`).
    /// Synchronous disk work; call off the main actor.
    func clearAllDownloaded(in storage: StorageLocations) {
        for name in (try? StorageLocations.entryFolderNames(in: storage.cacheRoot)) ?? [] {
            clearDownloaded(in: storage.resourcesDirectory(forFolderNamed: name))
        }
    }
}
