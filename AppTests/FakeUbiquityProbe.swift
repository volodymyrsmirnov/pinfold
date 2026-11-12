import Foundation
@testable import Pinfold

/// A scripted `UbiquityProbe` for tests: reports whatever it is told and records download
/// requests, so no iCloud is needed.
final class FakeUbiquityProbe: UbiquityProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var status: UbiquityDownloadStatus?
    private var placeholder = false
    private var requested: [URL] = []

    init(status: UbiquityDownloadStatus? = nil, placeholder: Bool = false) {
        self.status = status
        self.placeholder = placeholder
    }

    var downloadRequests: [URL] {
        lock.withLock { requested }
    }

    func downloadStatus(of _: URL) -> UbiquityDownloadStatus? {
        lock.withLock { status }
    }

    func placeholderExists(for _: URL) -> Bool {
        lock.withLock { placeholder }
    }

    func startDownloading(_ url: URL) {
        lock.withLock { requested.append(url) }
    }
}
