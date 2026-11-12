import Foundation

/// The download state of an iCloud item as far as Pinfold cares.
enum UbiquityDownloadStatus: Equatable {
    /// The newest version is on this device.
    case current
    /// A version is on this device but a newer one exists remotely.
    case downloaded
    /// Only metadata is here; the content has not been downloaded.
    case notDownloaded
}

/// Answers "has this iCloud item reached this device?" behind a seam, so the scanner's
/// never-backfill-over-a-sidecar-that-has-not-downloaded rule (B2) is unit-testable without
/// iCloud. The system implementation checks both ways a not-yet-downloaded file can present:
/// a hidden `.<name>.icloud` placeholder sibling, and a dataless item whose resource values
/// say `notDownloaded`.
protocol UbiquityProbe: Sendable {
    /// The download status of `url`, or `nil` when the system reports none (not an iCloud item
    /// or the file does not exist).
    func downloadStatus(of url: URL) -> UbiquityDownloadStatus?
    /// Whether a `.<name>.icloud` placeholder exists for `url`.
    func placeholderExists(for url: URL) -> Bool
    /// Asks the system to download `url`. Fire-and-forget; failures are ignored.
    func startDownloading(_ url: URL)
}

/// The real probe, backed by URL resource values and `FileManager`.
struct SystemUbiquityProbe: UbiquityProbe {
    func downloadStatus(of url: URL) -> UbiquityDownloadStatus? {
        guard let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus
        else { return nil }
        switch status {
        case .current: return .current
        case .downloaded: return .downloaded
        case .notDownloaded: return .notDownloaded
        default: return nil
        }
    }

    func placeholderExists(for url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    func startDownloading(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}

/// One unresolved iCloud conflict version of a file, behind closures so the conflict-resolution
/// path can be tested with plain data (E3).
struct ConflictVersion {
    /// The version's bytes, or `nil` if they cannot be read.
    let read: @Sendable () -> Data?
    /// Marks this version resolved so the system stops reporting it.
    let markResolved: @Sendable () -> Void
}

extension ConflictVersion {
    /// `NSFileVersion` is not `Sendable`; the wrapper is only touched from the closures below,
    /// each of which runs synchronously on the caller's thread.
    private final class VersionBox: @unchecked Sendable {
        let version: NSFileVersion
        init(_ version: NSFileVersion) {
            self.version = version
        }
    }

    /// The default source: the unresolved `NSFileVersion` conflicts of `url`.
    @Sendable static func systemVersions(of url: URL) -> [ConflictVersion] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map { version in
            let box = VersionBox(version)
            return ConflictVersion(
                read: { try? Data(contentsOf: box.version.url) },
                markResolved: { box.version.isResolved = true }
            )
        }
    }

    /// The default discard: `NSFileVersion.removeOtherVersionsOfItem` (irreversible).
    @Sendable static func removeSystemOtherVersions(of url: URL) throws {
        try NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
}
