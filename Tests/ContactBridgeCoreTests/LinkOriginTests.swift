import Foundation
import Testing
@testable import ContactBridgeCore

struct LinkOriginTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-origin-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: file format

    @Test("A links.json from before Phase 2 (no origin) loads as imported links and keeps its format when rewritten")
    func oldFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("links.json")
        let old = #"{ "version": 1, "links": { "i1": { "googleResourceName": "people/c1", "linkedAt": "2027-01-15T08:00:00Z" } } }"#
        try Data(old.utf8).write(to: url)

        let store = LinkStore(url: url)
        let entry = try #require(try store.load().links["i1"])
        #expect(entry.origin == nil && entry.effectiveOrigin == .imported)
        #expect(entry == LinkEntry(googleResourceName: "people/c1", linkedAt: t0, origin: .imported))
        #expect(entry.hashValue == LinkEntry(googleResourceName: "people/c1", linkedAt: t0, origin: .imported).hashValue)
        #expect(entry != LinkEntry(googleResourceName: "people/c1", linkedAt: t0, origin: .matched))

        try store.add([ImportedLink(icloudID: "i2", googleResourceName: "people/c2", origin: .matched)], at: t0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let links = try #require(object["links"] as? [String: [String: Any]])
        #expect(object["version"] as? Int == 1, "no version bump")
        #expect(links["i1"]?["origin"] == nil, "the old entry is not rewritten with a guess")
        #expect(links["i2"]?["origin"] as? String == "matched")
        let reloaded = try LinkStore(url: url).load()
        #expect(reloaded.links["i1"]?.effectiveOrigin == .imported && reloaded.links["i2"]?.origin == .matched)
    }

    @Test("A link's display name round-trips through links.json, is not part of its identity, and old files without it still load")
    func displayNameRoundTrip() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("links.json")
        let old = #"{ "version": 1, "links": { "i1": { "googleResourceName": "people/c1", "linkedAt": "2027-01-15T08:00:00Z", "origin": "matched" } } }"#
        try Data(old.utf8).write(to: url)

        let store = LinkStore(url: url)
        #expect(try store.load().links["i1"]?.displayName == nil)
        try store.add([ImportedLink(icloudID: "i2", googleResourceName: "people/c2", origin: .matched, displayName: "Ann Lee")], at: t0)

        let reloaded = try LinkStore(url: url).load()
        #expect(reloaded.links["i2"]?.displayName == "Ann Lee" && reloaded.links["i1"]?.displayName == nil)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let links = try #require(object["links"] as? [String: [String: Any]])
        #expect(object["version"] as? Int == 1, "no version bump")
        #expect(links["i1"]?["displayName"] == nil && links["i2"]?["displayName"] as? String == "Ann Lee")

        let named = LinkEntry(googleResourceName: "people/c2", linkedAt: t0, origin: .matched, displayName: "Ann Lee")
        let renamed = LinkEntry(googleResourceName: "people/c2", linkedAt: t0, origin: .matched, displayName: "Someone Else")
        #expect(named == renamed && named.hashValue == renamed.hashValue)
        #expect(named == LinkEntry(googleResourceName: "people/c2", linkedAt: t0, origin: .matched))
    }

    @Test("Import writes its links with origin imported; sync links carry theirs")
    func originsAreStored() async throws {
        let links = InMemoryLinkStore()
        let candidate = ImportCandidate(
            record: ContactRecord(id: "people/c1", source: .google, sourceIdentifier: "people/c1", givenName: "Ann", familyName: "Lee"), isSelected: true
        )
        let result = try await ImportExecutor(store: InMemoryContactStore(), receipt: .forTesting(createdAt: t0), links: links)
            .execute([candidate], now: t0)
        #expect(result.links.first?.origin == .imported)
        #expect(try links.load().links["mem-1"]?.origin == .imported, "stored explicitly, not left nil")

        try links.add([
            ImportedLink(icloudID: "a", googleResourceName: "people/c8", origin: .matched),
            ImportedLink(icloudID: "b", googleResourceName: "people/c9", origin: .createdInGoogle),
        ], at: t0)
        let table = try links.load()
        #expect(table.links["a"]?.origin == .matched && table.links["b"]?.origin == .createdInGoogle)
    }

    // MARK: Clean up

    private static let book = [
        ContactRecord(id: "a", source: .icloud, sourceIdentifier: "a", givenName: "Ann", familyName: "Lee"),
        ContactRecord(id: "b", source: .icloud, sourceIdentifier: "b", givenName: "Bob", familyName: "Stone"),
        ContactRecord(id: "c", source: .icloud, sourceIdentifier: "c", givenName: "Cy", familyName: "Moss"),
        ContactRecord(id: "d", source: .icloud, sourceIdentifier: "d", givenName: "Di", familyName: "Park"),
        ContactRecord(id: "e", source: .icloud, sourceIdentifier: "e", givenName: "Ed", familyName: "Ray"),
    ]

    private struct Rig {
        let store: InMemoryContactStore
        let links = InMemoryLinkStore()
        let syncState: InMemorySyncStateStore
        let workflows: ContactWorkflows
        let directory: URL

        init(state: SyncState?, syncStateWired: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-sync-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = InMemoryContactStore(records: LinkOriginTests.book)
            syncState = InMemorySyncStateStore(state ?? SyncState())
            let notes = InMemoryNotesStore()
            let store = store, directory = directory
            let backups = BackupCoordinator(makeSetup: {
                BackupSetup(writer: BackupWriter(store: store, notes: notes, baseDirectory: directory), containerID: "A")
            })
            workflows = ContactWorkflows(
                store: store, google: nil, notes: notes, backups: backups, links: links,
                syncState: syncStateWired ? syncState : nil, dismissals: InMemoryDismissalStore(), containerID: "A"
            )
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private func baseline(_ id: String) -> SyncBaseline {
        let record = LinkOriginTests.book.first { $0.sourceIdentifier == id } ?? LinkOriginTests.book[0]
        return SyncBaseline(icloud: record, google: record, googleEtag: "e1", syncedAt: t0)
    }

    private func link(_ rig: Rig, _ origins: [String: LinkOrigin?]) throws {
        for (index, id) in origins.keys.sorted().enumerated() {
            try rig.links.add([ImportedLink(icloudID: id, googleResourceName: "people/c\(index + 1)", origin: origins[id].flatMap { $0 } ?? .imported)], at: t0)
        }
    }

    @Test("The Imported filter means origin imported: matched and created-by-sync links do not count, an unknown origin does")
    func importedFilter() async throws {
        let rig = try Rig(state: nil)
        defer { rig.cleanUp() }
        try rig.links.add([
            ImportedLink(icloudID: "a", googleResourceName: "people/c1", origin: .imported),
            ImportedLink(icloudID: "b", googleResourceName: "people/c2", origin: .matched),
            ImportedLink(icloudID: "c", googleResourceName: "people/c3", origin: .createdInGoogle),
        ], at: t0)
        let rows = try await rig.workflows.loadCleanupRows()
        #expect(rows.filter(\.isImported).map(\.id) == ["a"])

        // A pre-Phase 2 entry has no origin at all.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("links.json")
        try Data(#"{ "version": 1, "links": { "d": { "googleResourceName": "people/c4", "linkedAt": "2027-01-15T08:00:00Z" } } }"#.utf8).write(to: url)
        let store = InMemoryContactStore(records: LinkOriginTests.book)
        let backups = BackupCoordinator(makeWriter: { BackupWriter(store: store, baseDirectory: directory) })
        let legacy = ContactWorkflows(
            store: store, google: nil, notes: InMemoryNotesStore(), backups: backups, links: LinkStore(url: url), dismissals: InMemoryDismissalStore()
        )
        #expect(try await legacy.loadCleanupRows().filter(\.isImported).map(\.id) == ["d"])
    }

    @Test("Before the first sync is approved Clean up drops the links of what it deletes, as it always did")
    func cleanupBeforeSync() async throws {
        for state in [nil, SyncState(baselines: ["a": baseline("a")], firstSyncApproved: false)] {
            let rig = try Rig(state: state)
            defer { rig.cleanUp() }
            try link(rig, ["a": .imported, "b": .matched])
            #expect(try rig.workflows.googleRemovalsPending(ifDeleting: ["a", "b"]) == 0)
            let run = try await rig.workflows.deleteContacts(ids: ["a", "e"])
            #expect(run.linksRemoved == 1 && run.googleRemovalsPending == 0 && run.followUpWarnings.isEmpty)
            #expect(Array(try rig.links.load().links.keys) == ["b"])
        }
        let unwired = try Rig(state: SyncState(baselines: ["a": baseline("a")], firstSyncApproved: true), syncStateWired: false)
        defer { unwired.cleanUp() }
        try link(unwired, ["a": .imported])
        let run = try await unwired.workflows.deleteContacts(ids: ["a"])
        #expect(run.linksRemoved == 1 && run.googleRemovalsPending == 0, "without a sync state store nothing can be pending")
    }

    @Test("Once syncing is approved the links of deleted contacts stay, so the sync can delete their Google copies")
    func cleanupAfterSync() async throws {
        let state = SyncState(baselines: ["a": baseline("a"), "b": baseline("b"), "c": baseline("c")], firstSyncApproved: true)
        let rig = try Rig(state: state)
        defer { rig.cleanUp() }
        // a, b and c are baselined; d is linked but never baselined; e is not linked.
        try link(rig, ["a": .imported, "b": .matched, "c": .createdInGoogle, "d": .imported])
        #expect(try rig.workflows.googleRemovalsPending(ifDeleting: ["a", "b", "d", "e"]) == 2)

        let run = try await rig.workflows.deleteContacts(ids: ["a", "b", "d", "e"])
        #expect(run.deletedCount == 4 && run.googleRemovalsPending == 2 && run.linksRemoved == 1 && run.followUpWarnings.isEmpty)
        #expect(try rig.links.load().links.keys.sorted() == ["a", "b", "c"], "a and b stay for the sync; d had no baseline; c was not deleted")
        #expect(try rig.syncState.load().baselines.keys.sorted() == ["a", "b", "c"], "baselines are the sync engine's to drop")
        #expect(try await rig.store.fetchAll().map(\.id) == ["c"])
    }

    @Test("An unreadable sync state stops Clean up before anything is deleted")
    func cleanupUnreadableState() async throws {
        struct BrokenState: SyncStateStoring {
            func load() throws -> SyncState { throw SyncStateStoreError.unreadable("locked") }
            func save(_ state: SyncState) throws {}
            func update(_ change: (inout SyncState) throws -> Void) throws -> SyncState { throw SyncStateStoreError.unreadable("locked") }
        }
        let rig = try Rig(state: nil)
        defer { rig.cleanUp() }
        let store = rig.store
        let backups = BackupCoordinator(makeWriter: { BackupWriter(store: store, baseDirectory: rig.directory) })
        let workflows = ContactWorkflows(
            store: store, google: nil, notes: InMemoryNotesStore(), backups: backups, links: rig.links, syncState: BrokenState(),
            dismissals: InMemoryDismissalStore()
        )
        await #expect(throws: SyncStateStoreError.unreadable("locked")) { _ = try await workflows.deleteContacts(ids: ["a"]) }
        #expect(try await rig.store.fetchAll().count == LinkOriginTests.book.count)
    }

    // MARK: plan

    @Test("A plan with contacts still waiting for notes or for a full listing is not empty")
    func planIsEmpty() {
        var plan = SyncPlan(isPreview: false)
        #expect(plan.isEmpty)
        plan.waitingForNotes = 1
        #expect(!plan.isEmpty)
        plan.waitingForNotes = 0
        plan.unlinkedWaitingForFullListing = 2
        #expect(!plan.isEmpty)
        plan.unlinkedWaitingForFullListing = 0
        #expect(plan.isEmpty)
    }
}
