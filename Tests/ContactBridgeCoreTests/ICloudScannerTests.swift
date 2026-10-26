import Foundation
import Testing
@testable import ContactBridgeCore

struct ICloudScannerTests {
    private let t0 = SyncFixtures.t0

    private func baseline(_ record: ContactRecord, noteHash: String? = nil) -> SyncBaseline {
        SyncBaseline(icloud: record, google: record, googleEtag: "e1", icloudNoteHash: noteHash, googleNoteHash: noteHash, syncedAt: t0)
    }

    private func scanner(
        _ store: InMemoryContactStore, notes: (any NotesProvider)?, running: Bool = false, now: Date? = nil
    ) -> ICloudScanner {
        ICloudScanner(store: store, notes: notes, contactsAppRunning: { running }, now: { now ?? SyncFixtures.t0 })
    }

    /// A state that has synced before: approved, token current, notes read an hour ago.
    private func settled(_ store: InMemoryContactStore, baselines: [String: SyncBaseline] = [:]) async throws -> SyncState {
        SyncState(
            baselines: baselines, icloudChangeToken: try await store.changeToken(), icloudContainerID: try await store.containerID(),
            lastNotesReadAt: t0.addingTimeInterval(-3600), firstSyncApproved: true
        )
    }

    @Test("The in-memory change token moves on every mutation and only then")
    func changeToken() async throws {
        let ann = SyncFixtures.icloud("a", "Ann", "Lee")
        let store = InMemoryContactStore(records: [ann])
        let start = try await store.changeToken()
        _ = try await store.fetchAll()
        #expect(try await store.changeToken() == start)
        try await store.update(ann, backup: .forTesting())
        let afterUpdate = try await store.changeToken()
        #expect(afterUpdate != start)
        let created = try await store.create(SyncFixtures.icloud("x", "Bob", "Stone"), backup: .forTesting())
        let afterCreate = try await store.changeToken()
        #expect(afterCreate != afterUpdate)
        try await store.delete(ids: [created.sourceIdentifier], backup: .forTesting())
        #expect(try await store.changeToken() != afterCreate)
        await #expect(throws: ContactStoreError.accessDenied) { try await InMemoryContactStore(authorization: .denied).changeToken() }
    }

    @Test("The first sync reads every note: contacts without one get the empty-note hash")
    func firstSyncReadsNotes() async throws {
        let store = InMemoryContactStore(records: [SyncFixtures.icloud("a", "Ann", "Lee"), SyncFixtures.icloud("b", "Bob", "Stone")])
        let notes = InMemoryNotesStore(notes: ["a": "hello"])
        let scan = try await scanner(store, notes: notes).scan(state: SyncState())
        #expect(scan.status == .changed && scan.notesReason == .firstSync && scan.notes == .read)
        #expect(scan.noteHashes == ["a": NoteHash.hash("hello"), "b": NoteHash.hash("")])
        #expect(scan.noteTexts == ["a": "hello"])
        #expect(scan.notesReadAt == t0)
        #expect(scan.addedIDs == ["a", "b"] && scan.changedIDs.isEmpty && scan.missingIDs.isEmpty)
        #expect(notes.fetchedIDs == [["a", "b"]])
    }

    @Test("A contact the provider did not return gets no note hash and no text, while a found contact without a note gets the empty hash")
    func unmatchedContactHasNoHash() async throws {
        let store = InMemoryContactStore(records: [
            SyncFixtures.icloud("a", "Ann", "Lee"), SyncFixtures.icloud("b", "Bob", "Stone"), SyncFixtures.icloud("c", "Cy", "Park"),
        ])
        let notes = InMemoryNotesStore(notes: ["a": "hello"], unmatchedIDs: ["b"])
        let scan = try await scanner(store, notes: notes).scan(state: SyncState())
        #expect(scan.notes == .read)
        #expect(scan.noteHashes == ["a": NoteHash.hash("hello"), "c": NoteHash.hash("")])
        #expect(scan.noteHashes["b"] == nil && scan.noteTexts["b"] == nil)
    }

    @Test("A synced note is not reported as changed when its contact was not returned")
    func unmatchedContactIsNotChanged() async throws {
        let ann = SyncFixtures.icloud("a", "Ann", "Lee")
        let store = InMemoryContactStore(records: [ann])
        let state = try await settled(store, baselines: ["a": baseline(ann, noteHash: NoteHash.hash("hello"))])
        let scan = try await scanner(store, notes: InMemoryNotesStore(unmatchedIDs: ["a"])).scan(state: state, trigger: .syncNow)
        #expect(scan.notes == .read && scan.noteHashes.isEmpty && scan.changedIDs.isEmpty)
    }

    @Test("The same change token short-circuits: nothing is fetched and no note is read")
    func tokenShortCircuit() async throws {
        let ann = SyncFixtures.icloud("a", "Ann", "Lee")
        let store = InMemoryContactStore(records: [ann])
        let notes = InMemoryNotesStore()
        let state = try await settled(store, baselines: ["a": baseline(ann)])
        let scan = try await scanner(store, notes: notes).scan(state: state)
        #expect(scan.status == .unchanged && scan.records.isEmpty && scan.notesReason == .skipped && scan.notes == .notRead)
        #expect(scan.changeToken == state.icloudChangeToken)
        #expect(notes.fetchedIDs.isEmpty)
    }

    @Test("A moved token fetches; with Contacts closed and notes read recently the notes are skipped")
    func changedTokenSkipsNotes() async throws {
        let ann = SyncFixtures.icloud("a", "Ann", "Lee")
        let store = InMemoryContactStore(records: [ann])
        let state = try await settled(store, baselines: ["a": baseline(ann)])
        var edited = ann
        edited.nickname = "Annie"
        try await store.update(edited, backup: .forTesting())
        let notes = InMemoryNotesStore(notes: ["a": "x"])
        let scan = try await scanner(store, notes: notes).scan(state: state)
        #expect(scan.status == .changed && scan.notesReason == .skipped && scan.notes == .notRead)
        #expect(scan.noteHashes.isEmpty && scan.notesReadAt == nil && notes.fetchedIDs.isEmpty)
        #expect(scan.changedIDs == ["a"])
    }

    @Test("A moved token with Contacts running reads the notes")
    func contactsRunning() async throws {
        let ann = SyncFixtures.icloud("a", "Ann", "Lee")
        let store = InMemoryContactStore(records: [ann])
        let state = try await settled(store, baselines: ["a": baseline(ann, noteHash: NoteHash.hash(""))])
        try await store.update(ann, backup: .forTesting())
        let scan = try await scanner(store, notes: InMemoryNotesStore(notes: ["a": "new"]), running: true).scan(state: state)
        #expect(scan.notesReason == .contactsRunning && scan.notes == .read)
        #expect(scan.noteHashes["a"] == NoteHash.hash("new"))
        #expect(scan.changedIDs == ["a"], "a note-only edit still marks the contact changed")
    }

    @Test("An unmoved token with Contacts running does not read anything")
    func runningButUnchanged() async throws {
        let ann = SyncFixtures.icloud("a", "Ann", "Lee")
        let store = InMemoryContactStore(records: [ann])
        let state = try await settled(store, baselines: ["a": baseline(ann)])
        let scan = try await scanner(store, notes: InMemoryNotesStore(), running: true).scan(state: state)
        #expect(scan.status == .unchanged)
    }

    @Test("Notes older than 24 hours are read again, even with an unmoved token; exactly 24 hours is not yet stale")
    func stale() async throws {
        let ann = SyncFixtures.icloud("a", "Ann", "Lee")
        let store = InMemoryContactStore(records: [ann])
        var state = try await settled(store, baselines: ["a": baseline(ann)])
        state.lastNotesReadAt = t0.addingTimeInterval(-24 * 3600)
        let atLimit = try await scanner(store, notes: InMemoryNotesStore()).scan(state: state)
        #expect(atLimit.status == .unchanged && atLimit.notesReason == .skipped)

        state.lastNotesReadAt = t0.addingTimeInterval(-24 * 3600 - 1)
        let stale = try await scanner(store, notes: InMemoryNotesStore()).scan(state: state)
        #expect(stale.status == .changed && stale.notesReason == .stale24h && stale.notes == .read)

        state.lastNotesReadAt = nil
        #expect(try await scanner(store, notes: InMemoryNotesStore()).scan(state: state).notesReason == .stale24h)
    }

    @Test("Sync now reads the notes regardless of the token")
    func syncNow() async throws {
        let ann = SyncFixtures.icloud("a", "Ann", "Lee")
        let store = InMemoryContactStore(records: [ann])
        let state = try await settled(store, baselines: ["a": baseline(ann)])
        let scan = try await scanner(store, notes: InMemoryNotesStore()).scan(state: state, trigger: .syncNow)
        #expect(scan.status == .changed && scan.notesReason == .syncNow && scan.notes == .read)
    }

    @Test("A failed note read carries no note information at all, never empty hashes")
    func unreadableNotes() async throws {
        let store = InMemoryContactStore(records: [SyncFixtures.icloud("a", "Ann", "Lee")])
        let notes = InMemoryNotesStore(readError: NotesAccessError.notAuthorized)
        let scan = try await scanner(store, notes: notes).scan(state: SyncState())
        guard case .unavailable = scan.notes else {
            Issue.record("expected unavailable, got \(scan.notes)")
            return
        }
        #expect(scan.noteHashes.isEmpty && scan.noteTexts.isEmpty && scan.notesReadAt == nil)
        #expect(scan.status == .changed && scan.records.count == 1)

        let none = try await scanner(store, notes: nil).scan(state: SyncState())
        if case .unavailable = none.notes {} else { Issue.record("no provider must be unavailable") }
        #expect(none.noteHashes.isEmpty)
    }

    @Test("A different container pauses without fetching anything")
    func containerChanged() async throws {
        let ann = SyncFixtures.icloud("a", "Ann", "Lee")
        let store = InMemoryContactStore(records: [ann])
        let state = try await settled(store, baselines: ["a": baseline(ann)])
        store.setContainerID("another-account")
        let scan = try await scanner(store, notes: InMemoryNotesStore()).scan(state: state)
        #expect(scan.status == .paused(.containerChanged) && scan.pause == .containerChanged)
        #expect(scan.records.isEmpty && scan.missingIDs.isEmpty)
    }

    @Test("An empty fetch while baselines exist pauses instead of reporting deletions; without baselines it is just empty")
    func emptyFetch() async throws {
        let ann = SyncFixtures.icloud("a", "Ann", "Lee")
        let store = InMemoryContactStore(records: [ann])
        let state = try await settled(store, baselines: ["a": baseline(ann)])
        try await store.delete(ids: ["a"], backup: .forTesting())
        let scan = try await scanner(store, notes: InMemoryNotesStore()).scan(state: state)
        #expect(scan.status == .paused(.containerChanged) && scan.missingIDs.isEmpty)

        let fresh = try await scanner(store, notes: InMemoryNotesStore()).scan(state: SyncState())
        #expect(fresh.status == .changed && fresh.records.isEmpty)
    }

    @Test("Edits, additions and removals are told apart from the baselines")
    func differences() async throws {
        let ann = SyncFixtures.icloud("a", "Ann", "Lee")
        let bob = SyncFixtures.icloud("b", "Bob", "Stone")
        let cy = SyncFixtures.icloud("c", "Cy", "Moss")
        let store = InMemoryContactStore(records: [ann, bob, cy])
        let state = try await settled(store, baselines: ["a": baseline(ann), "b": baseline(bob), "c": baseline(cy), "gone": baseline(ann)])
        var edited = bob
        edited.jobTitle = "Chef"
        try await store.update(edited, backup: .forTesting())
        _ = try await store.create(SyncFixtures.icloud("n", "New", "Person"), backup: .forTesting())
        let scan = try await scanner(store, notes: InMemoryNotesStore()).scan(state: state, trigger: .syncNow)
        #expect(scan.changedIDs == ["b"])
        #expect(scan.addedIDs == ["mem-1"])
        #expect(scan.missingIDs == ["gone"])
        #expect(scan.records.map(\.sourceIdentifier) == ["a", "b", "c", "mem-1"])
    }

    @Test("Contacts with no baseline make an otherwise-skipped run read the notes; baselined edits alone do not")
    func newContactsReadNotes() async throws {
        let ann = SyncFixtures.icloud("a", "Ann", "Lee")
        let store = InMemoryContactStore(records: [ann])
        let state = try await settled(store, baselines: ["a": baseline(ann)])
        _ = try await store.create(SyncFixtures.icloud("x", "New", "Person"), backup: .forTesting())
        let notes = InMemoryNotesStore(notes: ["mem-1": "hi"])
        let scan = try await scanner(store, notes: notes).scan(state: state)
        #expect(scan.notesReason == .newContacts && scan.notes == .read && scan.notesReadAt == t0)
        #expect(scan.noteHashes["mem-1"] == NoteHash.hash("hi") && scan.noteHashes["a"] == NoteHash.hash(""))

        // A contact that exists but has no data does not need a baseline.
        let blank = InMemoryContactStore(records: [ann, ContactRecord(id: "e", source: .icloud, sourceIdentifier: "e")])
        let quiet = try await settled(blank, baselines: ["a": baseline(ann)])
        try await blank.update(ann, backup: .forTesting())
        #expect(try await scanner(blank, notes: InMemoryNotesStore()).scan(state: quiet).notesReason == .skipped)
    }

    @Test("An empty container is paused when only links exist")
    func emptyWithLinksOnly() async throws {
        let store = InMemoryContactStore(records: [])
        let links = LinkTable(links: ["a": LinkEntry(googleResourceName: "people/c1", linkedAt: t0)])
        let scan = try await scanner(store, notes: InMemoryNotesStore()).scan(state: SyncState(), links: links)
        #expect(scan.status == .paused(.containerChanged))
    }
}
