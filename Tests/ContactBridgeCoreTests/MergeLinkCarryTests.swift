import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

/// What a Dedupe merge does with the Google links of the contacts it deletes.
struct MergeLinkCarryTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "disk full" }
    }

    /// A link store that can be told to fail.
    private final class FlakyLinks: LinkStoring, Sendable {
        let inner = InMemoryLinkStore()
        let failAdd = Mutex(false)
        let failLoad = Mutex(false)
        func load() throws -> LinkTable {
            if failLoad.withLock({ $0 }) { throw LinkStoreError.unreadable("locked") }
            return try inner.load()
        }
        func add(_ links: [ImportedLink], at date: Date) throws {
            if failAdd.withLock({ $0 }) { throw Boom() }
            try inner.add(links, at: date)
        }
        func remove(icloudIDs: [String]) throws { try inner.remove(icloudIDs: icloudIDs) }
    }

    private final class FlakyState: SyncStateStoring, Sendable {
        let inner: InMemorySyncStateStore
        let failLoad = Mutex(false)
        init(_ state: SyncState) { inner = InMemorySyncStateStore(state) }
        func load() throws -> SyncState {
            if failLoad.withLock({ $0 }) { throw SyncStateStoreError.unreadable("locked") }
            return try inner.load()
        }
        func save(_ state: SyncState) throws { try inner.save(state) }
        func update(_ change: (inout SyncState) throws -> Void) throws -> SyncState { try inner.update(change) }
    }

    private struct Rig {
        let directory: URL
        let store: InMemoryContactStore
        let links = FlakyLinks()
        let state: FlakyState
        let workflows: ContactWorkflows

        init(records: [ContactRecord], state: SyncState = SyncState()) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("merge-link-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = InMemoryContactStore(records: records)
            self.state = FlakyState(state)
            let notes = InMemoryNotesStore()
            let store = store, directory = directory
            let backups = BackupCoordinator(makeSetup: {
                BackupSetup(writer: BackupWriter(store: store, notes: notes, baseDirectory: directory), containerID: "A")
            })
            workflows = ContactWorkflows(
                store: store, google: nil, notes: notes, backups: backups, links: links, syncState: self.state,
                dismissals: InMemoryDismissalStore(), containerID: "A"
            )
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }

        func drafts() async throws -> [MergeDraft] {
            try await workflows.loadDuplicates().clusters.map(MergeDraft.init)
        }

        var linkTable: [String: LinkEntry] { get throws { try links.inner.load().links } }
        var baselines: [String: SyncBaseline] { get throws { try state.inner.load().baselines } }
        var mergedAnything: Bool { !store.mutationLog.isEmpty }
    }

    private func person(_ id: String, _ given: String = "Ann", _ family: String = "Lee", phone: String = "415-555-0101") -> ContactRecord {
        ContactRecord(
            id: id, source: .icloud, sourceIdentifier: id, givenName: given, familyName: family,
            phones: [Labeled(label: "mobile", value: phone)]
        )
    }

    private func baseline(for record: ContactRecord, etag: String = "e1") -> SyncBaseline {
        SyncBaseline(
            icloud: record, google: ContactRecord(id: "people/c1", source: .google, sourceIdentifier: "people/c1", givenName: record.givenName, familyName: record.familyName, phones: record.phones),
            googleEtag: etag, icloudNoteHash: NoteHash.hash(""), googleNoteHash: NoteHash.hash(""), syncedAt: t0
        )
    }

    private func approved(_ baselines: [String: SyncBaseline] = [:]) -> SyncState {
        SyncState(baselines: baselines, firstSyncApproved: true)
    }

    /// One duplicate pair: the draft's survivor and its single loser.
    private func pair(_ rig: Rig) async throws -> (survivor: String, loser: String, draft: MergeDraft) {
        let draft = try #require(try await rig.drafts().first)
        return (draft.survivor.sourceIdentifier, try #require(draft.others.first).sourceIdentifier, draft)
    }

    // MARK: the pure helper

    @Test("The helper picks the loser with a baseline, then the oldest link, then the lowest id")
    func tieBreak() {
        let table = LinkTable(links: [
            "x": LinkEntry(googleResourceName: "people/c1", linkedAt: t0),
            "y": LinkEntry(googleResourceName: "people/c2", linkedAt: t0.addingTimeInterval(-100)),
            "z": LinkEntry(googleResourceName: "people/c3", linkedAt: t0.addingTimeInterval(-100)),
        ])
        func mover(_ state: SyncState?) -> String? {
            ContactWorkflows.linkCarryOver(survivorID: "s", loserIDs: ["z", "y", "x"], table: table, state: state).moved?.from
        }
        #expect(mover(nil) == "y", "oldest link; the lower id of the two oldest")
        let state = approved(["x": baseline(for: person("x"))])
        #expect(mover(state) == "x", "a baseline beats an older link")
        #expect(ContactWorkflows.linkCarryOver(survivorID: "s", loserIDs: ["z", "y", "x"], table: table, state: state).keptForSync.isEmpty)
    }

    @Test("A deleted contact that is not linked changes nothing")
    func nothingLinked() {
        let plan = ContactWorkflows.linkCarryOver(survivorID: "s", loserIDs: ["a"], table: LinkTable(), state: approved())
        #expect(plan == LinkCarryPlan())
    }

    // MARK: survivor unlinked, loser linked

    @Test("Sync off: the loser's link moves to the survivor, keeping its origin; Google is not involved")
    func movesLinkSyncOff() async throws {
        let rig = try Rig(records: [person("a1"), person("a2")])
        defer { rig.cleanUp() }
        let (survivor, loser, draft) = try await pair(rig)
        try rig.links.inner.add([ImportedLink(icloudID: loser, googleResourceName: "people/c1", origin: .matched)], at: t0)

        let run = try await rig.workflows.runMerge(draft)
        #expect(run.linksMoved == 1 && run.googleCopiesLeft == 0 && run.googleRemovalsPending == 0 && run.followUpWarnings.isEmpty)
        let table = try rig.linkTable
        #expect(table.keys.sorted() == [survivor] && table[survivor]?.googleResourceName == "people/c1" && table[survivor]?.origin == .matched)
        #expect(table[survivor]?.displayName == run.survivor.displayName)
        #expect(try rig.baselines.isEmpty)
        #expect(try await rig.store.fetchAll().map(\.sourceIdentifier) == [survivor])
    }

    @Test("Sync on: the loser's baseline moves to the survivor with the survivor's ids, so the next sync pushes the merged data as an update")
    func movesLinkAndBaselineSyncOn() async throws {
        // a1 is richer (it has an email), so it survives; a2, the loser, is the synced one and lacks the email.
        var rich = person("a1")
        rich.emails = [Labeled(label: "home", value: "ann@example.com")]
        let rig = try Rig(records: [rich, person("a2")])
        defer { rig.cleanUp() }
        let draft = try #require(try await rig.drafts().first)
        try #require(draft.survivor.sourceIdentifier == "a1")
        let synced = baseline(for: person("a2"))
        try rig.state.inner.save(approved(["a2": synced]))
        try rig.links.inner.add([ImportedLink(icloudID: "a2", googleResourceName: "people/c1", origin: .matched)], at: t0)

        let run = try await rig.workflows.runMerge(draft)
        #expect(run.linksMoved == 1 && run.googleRemovalsPending == 0 && run.followUpWarnings.isEmpty)
        #expect(try rig.linkTable.keys.sorted() == ["a1"])
        #expect(try rig.baselines.keys.sorted() == ["a1"], "the loser's baseline is gone")
        let moved = try #require(try rig.baselines["a1"])
        #expect(moved.icloud.id == "a1" && moved.icloud.sourceIdentifier == "a1")
        #expect(moved.icloud.phones == synced.icloud.phones && moved.icloud.emails.isEmpty && moved.googleEtag == "e1" && moved.google == synced.google)

        // Against that baseline the merged contact is an ordinary iCloud edit: the record ids play no part in the diff.
        let merged = try #require(try await rig.store.fetchAll().first)
        let diff = ThreeWayDiff.diff(
            icloud: merged, google: moved.google, base: moved, icloudNoteHash: NoteHash.hash(""), googleNoteHash: NoteHash.hash(""), at: t0
        )
        #expect(diff.needsPush && diff.pushFields == [.emails] && !diff.needsReview)
    }

    @Test("A loser's link with no baseline yet moves too; the survivor is adopted like any earlier import")
    func movesUnbaselinedLinkSyncOn() async throws {
        let rig = try Rig(records: [person("a1"), person("a2")], state: approved())
        defer { rig.cleanUp() }
        let (survivor, loser, draft) = try await pair(rig)
        try rig.links.inner.add([ImportedLink(icloudID: loser, googleResourceName: "people/c1")], at: t0)
        let run = try await rig.workflows.runMerge(draft)
        #expect(run.linksMoved == 1 && run.googleCopiesLeft == 0)
        #expect(try rig.linkTable.keys.sorted() == [survivor] && rig.baselines.isEmpty)
    }

    // MARK: both linked

    @Test("Both linked, sync off: the survivor's link wins, the loser's is removed, and Google is left alone")
    func bothLinkedSyncOff() async throws {
        let rig = try Rig(records: [person("a1"), person("a2")])
        defer { rig.cleanUp() }
        let (survivor, loser, draft) = try await pair(rig)
        try rig.links.inner.add([
            ImportedLink(icloudID: survivor, googleResourceName: "people/c1"), ImportedLink(icloudID: loser, googleResourceName: "people/c2"),
        ], at: t0)

        let run = try await rig.workflows.runMerge(draft)
        #expect(run.linksMoved == 0 && run.googleCopiesLeft == 1 && run.googleRemovalsPending == 0 && run.followUpWarnings.isEmpty)
        let table = try rig.linkTable
        #expect(table.keys.sorted() == [survivor] && table[survivor]?.googleResourceName == "people/c1")
    }

    @Test("Both linked, sync on: the loser's link and baseline stay, so the next sync deletes its Google copy through the guarded delete")
    func bothLinkedSyncOn() async throws {
        let rig = try Rig(records: [person("a1"), person("a2")])
        defer { rig.cleanUp() }
        let (survivor, loser, draft) = try await pair(rig)
        let loserBaseline = baseline(for: person(loser))
        try rig.state.inner.save(approved([survivor: baseline(for: person(survivor)), loser: loserBaseline]))
        try rig.links.inner.add([
            ImportedLink(icloudID: survivor, googleResourceName: "people/c1"), ImportedLink(icloudID: loser, googleResourceName: "people/c2"),
        ], at: t0)

        let run = try await rig.workflows.runMerge(draft)
        #expect(run.linksMoved == 0 && run.googleCopiesLeft == 0 && run.googleRemovalsPending == 1)
        #expect(try rig.linkTable.keys.sorted() == [survivor, loser].sorted() && rig.baselines[loser] == loserBaseline)
    }

    @Test("Both linked, sync on, but the loser's link was never baselined: nothing safe to delete, so the link goes and Google is left alone")
    func bothLinkedSyncOnUnbaselined() async throws {
        let rig = try Rig(records: [person("a1"), person("a2")], state: approved())
        defer { rig.cleanUp() }
        let (survivor, loser, draft) = try await pair(rig)
        try rig.links.inner.add([
            ImportedLink(icloudID: survivor, googleResourceName: "people/c1"), ImportedLink(icloudID: loser, googleResourceName: "people/c2"),
        ], at: t0)
        let run = try await rig.workflows.runMerge(draft)
        #expect(run.googleCopiesLeft == 1 && run.googleRemovalsPending == 0)
        #expect(try rig.linkTable.keys.sorted() == [survivor])
    }

    @Test("Two linked losers and an unlinked survivor: one link moves (the tie-break), the other follows the survivor-wins rule")
    func twoLinkedLosers() async throws {
        let rig = try Rig(records: [person("a1"), person("a2"), person("a3")])
        defer { rig.cleanUp() }
        let draft = try #require(try await rig.drafts().first)
        let survivor = draft.survivor.sourceIdentifier
        let losers = draft.others.map(\.sourceIdentifier).sorted()
        try rig.links.inner.add([ImportedLink(icloudID: losers[0], googleResourceName: "people/c1")], at: t0.addingTimeInterval(100))
        try rig.links.inner.add([ImportedLink(icloudID: losers[1], googleResourceName: "people/c2")], at: t0)

        let run = try await rig.workflows.runMerge(draft)
        #expect(run.linksMoved == 1 && run.googleCopiesLeft == 1)
        let table = try rig.linkTable
        #expect(table.keys.sorted() == [survivor] && table[survivor]?.googleResourceName == "people/c2", "the older link moves")
    }

    // MARK: failures

    @Test("If the links cannot be written the merge still stands, with a warning and no move")
    func linkWriteFailure() async throws {
        let rig = try Rig(records: [person("a1"), person("a2")])
        defer { rig.cleanUp() }
        let (_, loser, draft) = try await pair(rig)
        try rig.links.inner.add([ImportedLink(icloudID: loser, googleResourceName: "people/c1")], at: t0)
        rig.links.failAdd.withLock { $0 = true }

        let run = try await rig.workflows.runMerge(draft)
        #expect(try await rig.store.fetchAll().count == 1)
        #expect(run.linksMoved == 0 && run.followUpWarnings.count == 1 && run.followUpWarnings[0].contains("disk full"))
        #expect(try rig.linkTable.keys.sorted() == [loser], "left as it was; a later sync releases and re-matches it")
    }

    @Test("A bulk merge stops on a group whose links could not be written; later groups are not run")
    func bulkStopsOnLinkFailure() async throws {
        let rig = try Rig(records: [
            person("a1"), person("a2"), person("b1", "Bob", "Stone", phone: "415-555-0202"), person("b2", "Bob", "Stone", phone: "415-555-0202"),
        ])
        defer { rig.cleanUp() }
        let drafts = try await rig.drafts()
        for draft in drafts {
            try rig.links.inner.add([ImportedLink(icloudID: try #require(draft.others.first).sourceIdentifier, googleResourceName: "people/c\(draft.members[0].id)")], at: t0)
        }
        rig.links.failAdd.withLock { $0 = true }

        let report = try await rig.workflows.runBulkMerge(drafts)
        #expect(report.stop == .stoppedOnProblem && report.mergedCount == 1 && report.notRunCount == 1)
        guard case .merged(_, _, _, let links) = report.entries[0].outcome else {
            Issue.record("unexpected outcomes \(report.entries.map(\.outcome))")
            return
        }
        #expect(links.followUpWarnings.count == 1 && report.entries[1].outcome == .notRun)
        #expect(try await rig.store.fetchAll().count == 3)
    }

    @Test("A bulk merge reports what each group did with its links")
    func bulkReportsLinks() async throws {
        let rig = try Rig(records: [person("a1"), person("a2")])
        defer { rig.cleanUp() }
        let (survivor, loser, draft) = try await pair(rig)
        try rig.links.inner.add([ImportedLink(icloudID: loser, googleResourceName: "people/c1")], at: t0)
        let report = try await rig.workflows.runBulkMerge([draft])
        guard case .merged(_, _, _, let links) = report.entries[0].outcome else {
            Issue.record("unexpected outcomes \(report.entries.map(\.outcome))")
            return
        }
        #expect(report.isComplete && links.linksMoved == 1 && links.followUpWarnings.isEmpty)
        #expect(try rig.linkTable.keys.sorted() == [survivor])
    }

    @Test("Unreadable links or sync state: nothing is merged")
    func unreadableFilesMergeNothing() async throws {
        let rig = try Rig(records: [person("a1"), person("a2")])
        defer { rig.cleanUp() }
        let (_, loser, draft) = try await pair(rig)
        try rig.links.inner.add([ImportedLink(icloudID: loser, googleResourceName: "people/c1")], at: t0)

        rig.links.failLoad.withLock { $0 = true }
        await #expect(throws: LinkStoreError.unreadable("locked")) { try await rig.workflows.runMerge(draft) }
        rig.links.failLoad.withLock { $0 = false }
        rig.state.failLoad.withLock { $0 = true }
        await #expect(throws: SyncStateStoreError.unreadable("locked")) { try await rig.workflows.runMerge(draft) }
        let remaining = try await rig.store.fetchAll().count
        #expect(!rig.mergedAnything && remaining == 2)

        let report = try await rig.workflows.runBulkMerge([draft])
        guard case .failed = report.entries[0].outcome else {
            Issue.record("unexpected outcomes \(report.entries.map(\.outcome))")
            return
        }
        #expect(!rig.mergedAnything && report.stop == .stoppedOnProblem)
        #expect(try rig.linkTable.keys.sorted() == [loser])
    }

    @Test("A merge of contacts that were never linked leaves the link files alone")
    func unlinkedMerge() async throws {
        let rig = try Rig(records: [person("a1"), person("a2")], state: approved())
        defer { rig.cleanUp() }
        let run = try await rig.workflows.runMerge(try #require(try await rig.drafts().first))
        #expect(run.links == MergeLinkOutcome())
        #expect(try rig.linkTable.isEmpty && rig.baselines.isEmpty)
    }
}
