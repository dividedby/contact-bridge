import Foundation

/// Why a scan read (or did not read) the notes. Reading goes through AppleScript, which launches Contacts if it is not
/// running, so a background run only does it when it is cheap or overdue.
public enum NotesReadReason: String, Sendable, Hashable, Codable {
    /// Sync has not been approved yet: the preview and the first run need every note for the baselines.
    case firstSync
    /// The user asked for "Sync now".
    case syncNow
    /// Contacts changed and the Contacts app is already running.
    case contactsRunning
    /// The last read is more than 24 hours old (or there never was one).
    case stale24h
    /// The fetch holds contacts with no baseline yet (new, or linked by an earlier import). A baseline made without
    /// their notes would leave the note unsynced for good, so the notes are read now.
    case newContacts
    case skipped
}

public enum SyncTrigger: Sendable, Hashable {
    /// A timer, a wake or a change notification.
    case scheduled
    /// The user pressed "Sync now".
    case syncNow
}

/// What happened to the notes in one scan.
public enum NotesReadOutcome: Sendable, Hashable {
    /// The notes were read. A contact the provider did not return has no note hash (see `ICloudScan.noteHashes`).
    case read
    /// No read was attempted (reason `skipped`).
    case notRead
    /// A read was due but failed or has no provider; the run carries no note information at all.
    case unavailable(String)
}

/// One look at the iCloud contacts, compared with the baselines.
public struct ICloudScan: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        /// The change token matches the last processed one: nothing changed, `records` is empty and every linked
        /// contact is as its baseline says.
        case unchanged
        case changed
        /// Sync must not continue: no deletion may be derived from this scan. `records` is empty.
        case paused(PauseReason)
    }

    public var status: Status
    /// Every contact in the container, ordered by identifier. Empty unless `status` is `.changed`.
    public var records: [ContactRecord]
    /// The store's token at scan time; save it as `SyncState.icloudChangeToken` once the run's results are committed.
    /// Writes the run makes itself move the store's token, so re-read it afterwards.
    public var changeToken: Data?
    public var containerID: String?
    /// `NoteHash.hash` per contact id, present only for contacts whose note was actually read. A contact without a note
    /// has `NoteHash.hash("")`; an unread note has no entry (never an empty-note hash).
    public var noteHashes: [String: String]
    /// The note text of contacts that have one, for the same reads.
    public var noteTexts: [String: String]
    public var notesReason: NotesReadReason
    public var notes: NotesReadOutcome
    /// When the notes were read, if they were; save it as `SyncState.lastNotesReadAt`.
    public var notesReadAt: Date?
    /// Contacts that differ from their baseline (fields, or note hash when both are known).
    public var changedIDs: [String]
    /// Contacts with no baseline.
    public var addedIDs: [String]
    /// Baselines whose contact is not in the container any more. Only filled when `status` is `.changed`.
    public var missingIDs: [String]

    public var pause: PauseReason? {
        if case .paused(let reason) = status { reason } else { nil }
    }
}

/// Finds out what changed in iCloud since the baselines, without writing anything.
///
/// Each run compares a full `fetchAll()` with the baselines (the iCloud history API is not used), except when the
/// store's change token equals the last processed one: then nothing is fetched. A different container, or an empty
/// container while baselines or links exist, pauses instead of reporting every contact as deleted.
public struct ICloudScanner: Sendable {
    public static let notesRefreshInterval: TimeInterval = 24 * 60 * 60

    private let store: any ContactStoring
    private let notes: (any NotesProvider)?
    private let contactsAppRunning: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - notes: nil when notes cannot be read at all; the scan then carries no note information.
    ///   - contactsAppRunning: whether the Contacts app is running (`NSRunningApplication` in the app).
    ///   - now: the clock.
    public init(
        store: any ContactStoring, notes: (any NotesProvider)? = nil,
        contactsAppRunning: @escaping @Sendable () -> Bool = { false }, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.notes = notes
        self.contactsAppRunning = contactsAppRunning
        self.now = now
    }

    /// - Parameter links: `links.json`, so an empty container is caught while only Phase 1 links (no baselines) exist.
    public func scan(state: SyncState, links: LinkTable = LinkTable(), trigger: SyncTrigger = .scheduled) async throws -> ICloudScan {
        let token = try await store.changeToken()
        let container = try await store.containerID()
        let tokenChanged = token == nil || token != state.icloudChangeToken
        var reason = notesReason(tokenChanged: tokenChanged, state: state, trigger: trigger)

        func empty(_ status: ICloudScan.Status) -> ICloudScan {
            ICloudScan(
                status: status, records: [], changeToken: token, containerID: container, noteHashes: [:], noteTexts: [:],
                notesReason: reason, notes: .notRead, notesReadAt: nil, changedIDs: [], addedIDs: [], missingIDs: []
            )
        }

        if let saved = state.icloudContainerID, let container, saved != container { return empty(.paused(.containerChanged)) }
        if !tokenChanged, reason == .skipped { return empty(.unchanged) }

        let records = try await store.fetchAll().sorted { $0.sourceIdentifier < $1.sourceIdentifier }
        if records.isEmpty, !state.baselines.isEmpty || !links.links.isEmpty { return empty(.paused(.containerChanged)) }
        if reason == .skipped, records.contains(where: { state.baselines[$0.sourceIdentifier] == nil && !$0.isEmpty }) {
            reason = .newContacts
        }

        var hashes: [String: String] = [:]
        var texts: [String: String] = [:]
        var outcome = NotesReadOutcome.notRead
        var readAt: Date?
        if reason != .skipped {
            if let notes {
                do {
                    let fetched = try await notes.fetchNotes(ids: records.map(\.sourceIdentifier))
                    for record in records {
                        // Absent means the provider could not match the contact: its note is unknown, not empty.
                        guard let text = fetched[record.sourceIdentifier] else { continue }
                        hashes[record.sourceIdentifier] = NoteHash.hash(text)
                        if !text.isBlank { texts[record.sourceIdentifier] = text }
                    }
                    outcome = .read
                    readAt = now()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    outcome = .unavailable(error.localizedDescription)
                }
            } else {
                outcome = .unavailable("Notes cannot be read on this Mac")
            }
        }

        var changed: [String] = []
        var added: [String] = []
        for record in records {
            let id = record.sourceIdentifier
            guard let base = state.baselines[id] else {
                added.append(id)
                continue
            }
            let noteMoved = hashes[id].flatMap { current in base.icloudNoteHash.map { $0 != current } } ?? false
            if record != base.icloud || noteMoved { changed.append(id) }
        }
        let present = Set(records.map(\.sourceIdentifier))
        return ICloudScan(
            status: .changed, records: records, changeToken: token, containerID: container, noteHashes: hashes, noteTexts: texts,
            notesReason: reason, notes: outcome, notesReadAt: readAt, changedIDs: changed, addedIDs: added,
            missingIDs: state.baselines.keys.filter { !present.contains($0) }.sorted()
        )
    }

    private func notesReason(tokenChanged: Bool, state: SyncState, trigger: SyncTrigger) -> NotesReadReason {
        if !state.firstSyncApproved { return .firstSync }
        if trigger == .syncNow { return .syncNow }
        if tokenChanged, contactsAppRunning() { return .contactsRunning }
        if let last = state.lastNotesReadAt, now().timeIntervalSince(last) <= Self.notesRefreshInterval { return .skipped }
        return .stale24h
    }
}
