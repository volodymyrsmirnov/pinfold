import Foundation

extension StorageLocations {
    /// Resolves the original file inside the synced folder `name`. The single resolver used by
    /// the scanner, the refresh pass, the share/open paths and the snapshot service, so they all
    /// agree on which file is the entry's data.
    ///
    /// Order: the sidecar's `sourceFilename` when that file exists; otherwise the 1.7 ranking
    /// (KML/KMZ first, then GPX/GeoJSON/JSON), alphabetical within a rank. `nil` if none.
    func originalFileURL(inFolderNamed name: String) -> URL? {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        if let named = sidecarSourceFilename(inFolderNamed: name), isPlainOriginalName(named) {
            let url = folder.appendingPathComponent(named)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }
        guard let contents = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents
            .filter {
                ImportFormats.originalExtensions.contains($0.pathExtension.lowercased())
                    && !ImportFormats.reservedNames.contains($0.lastPathComponent)
            }
            .sorted {
                let (lhs, rhs) = (Self.rank($0), Self.rank($1))
                return lhs == rhs ? $0.lastPathComponent < $1.lastPathComponent : lhs < rhs
            }
            .first
    }

    /// A bare file name (no path components) that is not the sidecar itself.
    private func isPlainOriginalName(_ named: String) -> Bool {
        named == (named as NSString).lastPathComponent && !ImportFormats.reservedNames.contains(named)
    }

    private static func rank(_ url: URL) -> Int {
        ["kml", "kmz"].contains(url.pathExtension.lowercased()) ? 0 : 1
    }

    /// The sidecar's `sourceFilename`, decoded without any conflict handling or writes.
    private func sidecarSourceFilename(inFolderNamed name: String) -> String? {
        guard let data = try? Data(contentsOf: metadataFile(forFolderNamed: name)),
              let meta = try? EntryMetadata.decoded(from: data)
        else { return nil }
        return meta.sourceFilename
    }

    /// Deletes `.snapshot-*.tmp` files an interrupted network-link snapshot left in `name`.
    /// Only files untouched for `minimumAge` seconds are removed, so a snapshot being written
    /// right now is never disturbed.
    func removeStaleSnapshotTemps(inFolderNamed name: String, minimumAge: TimeInterval = 600) {
        let fm = FileManager.default
        let folder = root.appendingPathComponent(name, isDirectory: true)
        guard let contents = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return }
        for url in contents {
            let file = url.lastPathComponent
            guard file.hasPrefix(".snapshot-"), file.hasSuffix(".tmp") else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .now
            if Date().timeIntervalSince(modified) >= minimumAge {
                try? fm.removeItem(at: url)
            }
        }
    }
}
