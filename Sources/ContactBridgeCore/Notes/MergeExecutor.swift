import Foundation

/// Runs a merge and carries the notes along. Contact fields go through `ContactStoring.merge`, untouched; notes, which
/// that store cannot see, are combined by `NotesMerge` and written to the survivor afterwards.
///
/// Order: check the receipt, read notes, merge, then (only if the merge succeeded and the combined note differs from
/// the survivor's) write the note. A failed note write never undoes the merge: it is reported in the outcome together
/// with the combined text, which is also recoverable from the backup (`icloud-notes.json`).
public struct MergeExecutor: Sendable {
    public enum NotesOutcome: Sendable, Equatable {
        /// No notes store was supplied.
        case skipped
        /// The duplicates added nothing to the survivor's note.
        case unchanged
        case written
        /// The merge is done but the combined note was not saved. `combined` is what should have been written.
        case writeFailed(combined: String, reason: String)
    }

    public struct Outcome: Sendable, Equatable {
        public var notes: NotesOutcome
    }

    public enum Failure: Error, Sendable, Equatable {
        /// The receipt is older than `maxBackupAge`: nothing was read or changed.
        case staleBackup
    }

    private let store: any ContactStoring
    private let notes: (any NotesStoring)?
    private let maxBackupAge: TimeInterval

    public init(store: any ContactStoring, notes: (any NotesStoring)?, maxBackupAge: TimeInterval = 3600) {
        self.store = store
        self.notes = notes
        self.maxBackupAge = maxBackupAge
    }

    /// Throws `Failure.staleBackup` before doing anything if the backup is not fresh. If reading notes throws (for
    /// example `NotesAccessError.notAuthorized`), nothing has been merged yet. Pass no notes store to merge without notes.
    public func execute(survivor: ContactRecord, absorbing ids: [String], backup: BackupReceipt, now: Date = Date()) async throws -> Outcome {
        guard backup.isFresh(maxAge: maxBackupAge, now: now) else { throw Failure.staleBackup }

        let survivorID = survivor.sourceIdentifier
        var seen: Set<String> = [survivorID]
        let duplicateIDs = ids.filter { seen.insert($0).inserted }

        var survivorNote: String?
        var combined: String?
        if let notes {
            let fetched = try await notes.fetchNotes(ids: [survivorID] + duplicateIDs)
            survivorNote = fetched[survivorID]
            combined = NotesMerge.combine(survivor: survivorNote, others: duplicateIDs.map { (id: $0, note: fetched[$0]) })
        }

        try await store.merge(survivor: survivor, absorbing: duplicateIDs, backup: backup)

        guard let notes else { return Outcome(notes: .skipped) }
        guard let combined, combined != survivorNote else { return Outcome(notes: .unchanged) }
        do {
            try await notes.setNote(combined, forID: survivorID)
            return Outcome(notes: .written)
        } catch {
            return Outcome(notes: .writeFailed(combined: combined, reason: error.localizedDescription))
        }
    }
}
