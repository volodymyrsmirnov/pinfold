import Foundation
import PinfoldCore

extension ResourceCache {
    /// Streams every non-root entry of a KMZ straight into `resourcesDir` (nothing is held in
    /// memory beyond one chunk) and records the archive-key to filename map in the manifest.
    ///
    /// Filenames follow `cachedFilename(for:)` with the root-relative key as the href, the same
    /// scheme `writeEmbedded` used, so `localURL(forHref:in:)` resolves embedded hrefs exactly
    /// as before. Re-running is idempotent (files are overwritten, the manifest merged).
    ///
    /// - Returns: The key to filename map that was recorded (empty for a non-KMZ).
    /// - Throws: A file-system, archive or cancellation error; files already written by this
    ///   call are removed again by the extractor and the manifest is left untouched.
    @discardableResult
    func extractEmbedded(fromKMZ data: Data, to resourcesDir: URL) throws -> [String: String] {
        let filenames = try KMLReader.extractResources(
            fromKMZ: data,
            into: resourcesDir,
            filenameFor: { cachedFilename(for: $0) }
        )
        guard !filenames.isEmpty else { return [:] }
        try ResourceManifestStore.shared.updateManifest(in: resourcesDir) {
            $0.merge(filenames) { _, new in new }
        }
        return filenames
    }
}
