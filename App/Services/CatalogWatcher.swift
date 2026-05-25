import Foundation

/// Watches the active storage root and calls `onChange` when its contents change, so the
/// catalogue updates in real time — both for files synced from another device and for
/// local changes (e.g. the share-extension inbox) — without relaunching.
///
/// Two backends, picked by `start(root:ubiquitous:)`:
/// - **iCloud root** → `NSMetadataQuery` on the ubiquitous documents scope. (A plain
///   `DispatchSource` does not see iCloud's out-of-process placeholder updates.)
/// - **Local root** → a `DispatchSource` file-system watch on the directory.
///
/// Events are debounced so a burst of file operations triggers a single reload.
@MainActor
final class CatalogWatcher {

    private let onChange: @MainActor () -> Void
    private let debounce: Duration

    private var query: NSMetadataQuery?
    // `nonisolated(unsafe)` so the nonisolated `deinit` can tear these down. Safe: they are
    // only mutated on the main actor in `start`/`stop`, and the underlying APIs
    // (`removeObserver`, `cancel`, `close`) are themselves thread-safe.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private nonisolated(unsafe) var source: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var watchedFD: Int32 = -1
    private var pendingReload: Task<Void, Never>?

    init(debounce: Duration = .milliseconds(400), onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        self.debounce = debounce
    }

    /// Starts (or restarts) watching `root`. Pass `ubiquitous: true` when `root` is the
    /// iCloud container's `Documents` directory.
    func start(root: URL, ubiquitous: Bool) {
        stop()
        if ubiquitous {
            startMetadataQuery()
        } else {
            startLocalWatch(root: root)
        }
    }

    func stop() {
        pendingReload?.cancel()
        pendingReload = nil

        if let query {
            query.stop()
            self.query = nil
        }
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()

        source?.cancel()
        source = nil
        if watchedFD >= 0 {
            close(watchedFD)
            watchedFD = -1
        }
    }

    // MARK: - iCloud

    private func startMetadataQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == 'metadata.json'", NSMetadataItemFSNameKey)

        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering,
                     NSNotification.Name.NSMetadataQueryDidUpdate] {
            let token = center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
            observers.append(token)
        }
        query.start()
        self.query = query
    }

    // MARK: - Local

    private func startLocalWatch(root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.resume()
        self.source = source
    }

    // MARK: - Debounce

    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [debounce, onChange] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            onChange()
        }
    }

    deinit {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        source?.cancel()
        if watchedFD >= 0 { close(watchedFD) }
    }
}
