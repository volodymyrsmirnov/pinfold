import Foundation

/// What the launch reconciler needs from Core Spotlight, behind a seam so tests can record
/// the calls instead of touching the real index.
protocol SpotlightSink: Sendable {
    func index(entry: CatalogEntry, indexEntries: [PlacemarkIndex.Entry])
    func deindex(folderName: String)
    func clearLegacyDomains()
}

/// The live sink: forwards to `SpotlightIndexer`.
struct SystemSpotlightSink: SpotlightSink {
    func index(entry: CatalogEntry, indexEntries: [PlacemarkIndex.Entry]) {
        SpotlightIndexer.index(entry: entry, indexEntries: indexEntries)
    }

    func deindex(folderName: String) {
        // Rows are not needed: the per-folder domain delete removes every item of the folder
        // this version indexed, and the entry item id is deleted explicitly.
        SpotlightIndexer.deindex(folderName: folderName, indexEntries: [])
    }

    func clearLegacyDomains() {
        SpotlightIndexer.clearLegacyDomains()
    }
}

/// Brings the per-device derived state (the Spotlight index, the local resources cache) back
/// in line with the catalogue after changes made elsewhere (another device, the Files app).
///
/// Deletions are deliberately conservative: an empty or unreadable catalogue never deindexes
/// or prunes anything, because that is what a still-starting iCloud root looks like.
struct LaunchReconciler {
    /// What was indexed for one folder, per device.
    struct Record: Codable, Equatable {
        var displayName: String
        var trashed: Bool
    }

    /// What a reconcile pass will do.
    struct Plan: Equatable {
        var clearLegacy = false
        var deindex: [String] = []
        var reindex: [String] = []
    }

    static let ledgerKey = "spotlight.indexLedger.v1"

    /// The per-device ledger lives here; injectable for tests.
    var defaults: UserDefaults = .standard
    var sink: any SpotlightSink = SystemSpotlightSink()

    // MARK: - Spotlight

    func loadLedger() -> [String: Record]? {
        guard let data = defaults.data(forKey: Self.ledgerKey) else { return nil }
        return try? JSONDecoder().decode([String: Record].self, from: data)
    }

    private func saveLedger(_ ledger: [String: Record]) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: Self.ledgerKey)
    }

    /// The pure diff between the ledger and the catalogue. A `nil` ledger is the first launch
    /// of a version that keeps one: clear the old shared domains, reindex every active entry.
    static func plan(ledger: [String: Record]?, entries: [CatalogEntry]) -> Plan {
        guard let ledger else {
            return Plan(clearLegacy: true, reindex: entries.filter { !$0.isTrashed }.map(\.storageFolderName))
        }
        let byFolder = Dictionary(entries.map { ($0.storageFolderName, $0) }, uniquingKeysWith: { first, _ in first })
        var plan = Plan()
        for (folder, record) in ledger where !record.trashed {
            if byFolder[folder]?.isTrashed ?? true {
                plan.deindex.append(folder)
            }
        }
        for entry in entries where !entry.isTrashed {
            let record = ledger[entry.storageFolderName]
            if record == nil || record?.trashed == true || record?.displayName != entry.displayName {
                plan.reindex.append(entry.storageFolderName)
            }
        }
        plan.deindex.sort()
        plan.reindex.sort()
        return plan
    }

    /// Applies the plan through the sink and records the new ledger. Does nothing (and keeps
    /// the ledger) when the catalogue is empty but the ledger is not.
    @MainActor func reconcileSpotlight(entries: [CatalogEntry], storage: StorageLocations) async {
        let ledger = loadLedger()
        if entries.isEmpty, let ledger, ledger.contains(where: { !$0.value.trashed }) {
            return
        }
        let plan = Self.plan(ledger: ledger, entries: entries)
        if plan.clearLegacy {
            sink.clearLegacyDomains()
        }
        for folder in plan.deindex {
            sink.deindex(folderName: folder)
        }
        let byFolder = Dictionary(entries.map { ($0.storageFolderName, $0) }, uniquingKeysWith: { first, _ in first })
        let toIndex = plan.reindex.compactMap { byFolder[$0] }
        let rows = await readIndexRows(for: toIndex, in: storage)
        for entry in toIndex {
            sink.index(entry: entry, indexEntries: rows[entry.storageFolderName] ?? [])
        }
        saveLedger(Dictionary(
            entries.map { ($0.storageFolderName, Record(displayName: $0.displayName, trashed: $0.isTrashed)) },
            uniquingKeysWith: { first, _ in first }
        ))
    }

    // MARK: - Cache pruning

    /// Removes `<cacheRoot>/<name>` folders whose entry no longer exists in the root. Blocking
    /// file work: call off the main actor. Returns the names removed.
    ///
    /// Only when all of these hold: the layout is split (cache root differs from the root),
    /// sync is `.active` (never while iCloud is unavailable: every iCloud entry would look
    /// orphaned), the root listing succeeded and is non-empty, and the folder holds nothing
    /// but a `resources` directory (the shape this app creates).
    @discardableResult
    static func pruneCache(storage: StorageLocations, status: SyncStatus.State) -> [String] {
        guard status == .active,
              storage.cacheRoot.standardizedFileURL != storage.root.standardizedFileURL,
              let names = try? storage.entryFolderNames(), !names.isEmpty
        else { return [] }
        let live = Set(names)
        let fm = FileManager.default
        guard let cached = try? fm.contentsOfDirectory(
            at: storage.cacheRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var removed: [String] = []
        for url in cached {
            let name = url.lastPathComponent
            guard !live.contains(name), hasCacheShape(url) else { continue }
            if (try? fm.removeItem(at: url)) != nil {
                removed.append(name)
            }
        }
        return removed.sorted()
    }

    private static func hasCacheShape(_ url: URL) -> Bool {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        guard isDir, let children = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return children.allSatisfy { $0 == StorageLocations.reservedCacheFolderName }
    }
}

/// Reads the placemark index rows for `entries` off the main actor. A `nonisolated` free
/// function so the `Task.detached` closure stays out of any `@MainActor` caller's SIL.
private nonisolated func readIndexRows(
    for entries: [CatalogEntry], in storage: StorageLocations
) async -> [String: [PlacemarkIndex.Entry]] {
    await Task.detached(priority: .utility) {
        var rows: [String: [PlacemarkIndex.Entry]] = [:]
        for entry in entries {
            rows[entry.storageFolderName] = PlacemarkIndex.read(from: storage.resourcesDirectory(for: entry)) ?? []
        }
        return rows
    }.value
}
