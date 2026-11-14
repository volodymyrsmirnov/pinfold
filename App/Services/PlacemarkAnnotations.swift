import Foundation
import Observation
import PinfoldCore

/// The favorite/visited state for the *currently open* KML file.
///
/// Owned by `KMLDetailView` for one entry and injected into the environment so every
/// descendant (rows, detail view, map, preview card) reads the same instance. State is
/// keyed by `KMLPlacemark.stableKey` and persisted to the entry's `metadata.json`.
///
/// Toggling mutates the in-memory set (instant UI via `@Observable`) and synchronously
/// writes through to the sidecar via `StorageLocations.updateMetadata` — it never reloads
/// the catalogue or re-parses the open document. The store is `@MainActor`-bound, so all
/// toggles and writes are serialized; the sidecar is sub-KB JSON, making the synchronous
/// write-through negligible in wall-clock time.
@MainActor @Observable final class PlacemarkAnnotations {
    private(set) var favoriteKeys: Set<String> = []
    private(set) var visitedKeys: Set<String> = []
    /// All notes for this entry keyed by stable key, including tombstones (empty text).
    private(set) var notes: [String: PlacemarkNote] = [:] {
        didSet { notesRevision &+= 1 }
    }

    /// Bumps on every change to `notes`; a cheap identity for "notes changed" triggers.
    private(set) var notesRevision = 0

    @ObservationIgnored private let storage: StorageLocations
    @ObservationIgnored private let folderName: String
    @ObservationIgnored private var canPersist = true

    /// `false` when this entry cannot be written (read-only, not downloaded, unreadable
    /// sidecar). Favorite, Seen and the note editor are then disabled everywhere they're offered,
    /// rather than showing a change that would be dropped.
    var canEdit: Bool {
        canPersist
    }

    init(entry: CatalogEntry, storage: StorageLocations) {
        self.storage = storage
        folderName = entry.storageFolderName
        reload(entry: entry)
    }

    /// Re-reads favourites, Seen and notes from the sidecar on disk, keeping this instance (and
    /// so every view observing it) — used when the catalogue hands out its shared store for a
    /// file after a rescan (`Catalog.annotations(for:)`).
    func reload(entry: CatalogEntry) {
        // A read-only entry (sidecar unreadable / still downloading) must never be written:
        // the in-memory sets would be empty and a later write would destroy synced data.
        canPersist = !entry.isReadOnly
        do {
            let meta = try storage.readMetadata(forFolderNamed: entry.storageFolderName)
            favoriteKeys = meta?.favoriteKeys ?? []
            visitedKeys = meta?.visitedKeys ?? []
            notes = meta?.notes ?? [:]
        } catch {
            // Sidecar exists but failed to decode (corrupt/truncated). Start empty but
            // refuse to persist, so a toggle never overwrites recoverable data.
            favoriteKeys = []
            visitedKeys = []
            notes = [:]
            canPersist = false
        }
    }

    func isFavorite(_ placemark: KMLPlacemark) -> Bool {
        favoriteKeys.contains(placemark.stableKey)
    }

    func isVisited(_ placemark: KMLPlacemark) -> Bool {
        visitedKeys.contains(placemark.stableKey)
    }

    /// A VoiceOver-friendly description combining the placemark name with its
    /// favorite/Seen state, e.g. "Mount Everest, Favorite, Seen" (the wording every action uses).
    func accessibilityDescription(for placemark: KMLPlacemark) -> String {
        var parts = [placemark.name ?? "Untitled"]
        if isFavorite(placemark) {
            parts.append("Favorite")
        }
        if isVisited(placemark) {
            parts.append("Seen")
        }
        return parts.joined(separator: ", ")
    }

    func toggleFavorite(_ placemark: KMLPlacemark) {
        toggleFavorite(key: placemark.stableKey)
    }

    func toggleVisited(_ placemark: KMLPlacemark) {
        toggleVisited(key: placemark.stableKey)
    }

    // MARK: By stable key (search hits carry the key, not a parsed placemark)

    func isFavorite(key: String) -> Bool {
        favoriteKeys.contains(key)
    }

    func isVisited(key: String) -> Bool {
        visitedKeys.contains(key)
    }

    /// No-op when the entry can't be written, so the UI never shows a change that won't stick.
    func toggleFavorite(key: String) {
        guard canPersist else { return }
        let added = toggle(&favoriteKeys, key: key)
        persist(favorite: (key, added))
    }

    /// No-op when the entry can't be written, so the UI never shows a change that won't stick.
    func toggleVisited(key: String) {
        guard canPersist else { return }
        let added = toggle(&visitedKeys, key: key)
        persist(visited: (key, added))
    }

    /// The live (non-tombstone) note for a placemark, if any.
    func note(for placemark: KMLPlacemark) -> PlacemarkNote? {
        guard let note = notes[placemark.stableKey], !note.isTombstone else { return nil }
        return note
    }

    /// Live note text by stable key (tombstones omitted), for search indexing.
    var noteTextsByKey: [String: String] {
        notes.compactMapValues { $0.isTombstone ? nil : $0.text }
    }

    /// Saves a note, stamping `modifiedAt` and a snapshot of the placemark's name. Blank text
    /// (after trimming) writes a tombstone so the deletion wins a later sync merge.
    /// Returns `false` (leaving the in-memory notes unchanged) when the note could not be
    /// written, so the caller can keep the draft instead of pretending it was saved.
    @discardableResult
    func setNote(_ text: String, for placemark: KMLPlacemark, now: Date = Date()) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, notes[placemark.stableKey] == nil {
            return true
        }
        guard canPersist else { return false }
        let key = placemark.stableKey
        let previous = notes[key]
        notes[key] = PlacemarkNote(text: trimmed, modifiedAt: now, placemarkName: placemark.name)
        guard persist() else {
            notes[key] = previous
            return false
        }
        return true
    }

    /// Live notes whose key is not in `validKeys` (the placemark vanished from the file),
    /// sorted by key for a stable order.
    func orphanedNotes(validKeys: Set<String>) -> [(key: String, note: PlacemarkNote)] {
        notes
            .filter { !$0.value.isTombstone && !validKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, note: $0.value) }
    }

    /// Toggles `key`, returning `true` if it is now present.
    private func toggle(_ set: inout Set<String>, key: String) -> Bool {
        if set.contains(key) {
            set.remove(key)
            return false
        }
        set.insert(key)
        return true
    }

    /// Writes only this session's change onto the *current* on-disk state (re-read at write
    /// time), so a sidecar that arrived or changed while the file was open is never clobbered
    /// by the open-time snapshot.
    @discardableResult
    private func persist(
        favorite: (key: String, added: Bool)? = nil,
        visited: (key: String, added: Bool)? = nil
    ) -> Bool {
        guard canPersist else { return false }
        // For favorites/visited a failed write is tolerated (in-memory state stays for this
        // session); note saves check the result and surface the failure.
        do {
            try storage.updateExistingMetadata(forFolderNamed: folderName) { meta in
                if let favorite {
                    if favorite.added {
                        meta.favoriteKeys.insert(favorite.key)
                    } else {
                        meta.favoriteKeys.remove(favorite.key)
                    }
                }
                if let visited {
                    if visited.added {
                        meta.visitedKeys.insert(visited.key)
                    } else {
                        meta.visitedKeys.remove(visited.key)
                    }
                }
                // Merge rather than replace so a note synced from another device while this
                // file was open is not clobbered by this session's snapshot.
                for (key, note) in notes {
                    meta.notes[key] = meta.notes[key].map { PlacemarkNote.winner($0, note) } ?? note
                }
            }
            return true
        } catch {
            return false
        }
    }
}
