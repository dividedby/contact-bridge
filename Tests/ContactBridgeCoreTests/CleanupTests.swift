import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

struct CleanupTests {
    private static func person(
        _ id: String, _ given: String = "", _ family: String = "", org: String = "", nickname: String = "", phones: [String] = [],
        emails: [String] = []
    ) -> ContactRecord {
        ContactRecord(
            id: id, source: .icloud, sourceIdentifier: id, givenName: given, familyName: family, nickname: nickname, organization: org,
            phones: phones.map { Labeled(label: "mobile", value: $0) }, emails: emails.map { Labeled(label: "home", value: $0) }
        )
    }

    private static func rows(_ records: [ContactRecord], imported: Set<String> = []) -> [CleanupRow] {
        records.map { CleanupRow(record: $0, isImported: imported.contains($0.sourceIdentifier)) }
    }

    /// sms: short-code sender; blank: nothing at all; nameless: a phone only; bare: a name only; ann: complete and imported.
    private static let book = [
        person("sms", org: "Acme Rewards", phones: ["72727"]),
        person("blank"),
        person("nameless", phones: ["415-555-0300"]),
        person("bare", "Henry", "Walsh"),
        person("ann", "Ann", "Lee", phones: ["(415) 555-2671"], emails: ["Ann.Lee@Example.com"]),
        person("zoe", "Zoë", "Müller", org: "Café Müller", emails: ["zoe@example.com"]),
    ]

    private func ids(_ filter: CleanupFilter, imported: Set<String> = ["ann"]) -> [String] {
        filter.apply(to: Self.rows(Self.book, imported: imported)).map(\.id)
    }

    // MARK: rows

    @Test("A row's name is the person, else the nickname, else the organization, else No name; detail is the first phone or email")
    func rowFields() {
        let rows = Self.rows(Self.book + [Self.person("nick", nickname: "Bunny", emails: ["b@example.com"])])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID["ann"]?.displayName == "Ann Lee" && byID["ann"]?.detail == "(415) 555-2671")
        #expect(byID["sms"]?.displayName == "Acme Rewards" && byID["sms"]?.detail == "72727")
        #expect(byID["blank"]?.displayName == "No name" && byID["blank"]?.detail == "")
        #expect(byID["nick"]?.displayName == "Bunny" && byID["nick"]?.detail == "b@example.com")
        #expect(byID["zoe"]?.detail == "zoe@example.com")
    }

    // MARK: filters

    @Test("Text-message senders: short-code phones with no person name")
    func textMessageSenders() {
        #expect(ids(CleanupFilter(textMessageSenders: true)) == ["sms"])
    }

    @Test("No name: no name parts and no organization (an organization alone counts as a name)")
    func noName() {
        #expect(ids(CleanupFilter(noName: true)) == ["blank", "nameless"])
    }

    @Test("No phone or email: neither a phone nor an email; blank entries do not count")
    func noPhoneOrEmail() {
        #expect(ids(CleanupFilter(noPhoneOrEmail: true)) == ["blank", "bare"])
        let blankEntries = CleanupRow(record: Self.person("x", "Xi", phones: [" "], emails: [""]), isImported: false)
        #expect(blankEntries.hasNoPhoneOrEmail)
    }

    @Test("Imported by Contact Bridge: the id is in the link table")
    func imported() {
        #expect(ids(CleanupFilter(importedByContactBridge: true)) == ["ann"])
        #expect(ids(CleanupFilter(importedByContactBridge: true), imported: []) == [])
    }

    @Test("No option on shows everything; several combine with AND")
    func combine() {
        #expect(ids(CleanupFilter()) == Self.book.map(\.id))
        #expect(!CleanupFilter().hasActiveOptions && CleanupFilter(noName: true).hasActiveOptions)
        #expect(ids(CleanupFilter(noName: true, noPhoneOrEmail: true)) == ["blank"])
        #expect(ids(CleanupFilter(textMessageSenders: true, noName: true)) == [])
        #expect(ids(CleanupFilter(noPhoneOrEmail: true, importedByContactBridge: true)) == [])
        #expect(ids(CleanupFilter(textMessageSenders: true, noName: true, noPhoneOrEmail: true, importedByContactBridge: true)) == [])
    }

    // MARK: search

    @Test("Search ignores case and diacritics across name, organization, phones and emails")
    func search() {
        #expect(ids(CleanupFilter(search: "ANN")) == ["ann"])
        #expect(ids(CleanupFilter(search: "zoe muller")) == ["zoe"])
        #expect(ids(CleanupFilter(search: "cafe")) == ["zoe"])
        #expect(ids(CleanupFilter(search: "MÜLLER")) == ["zoe"])
        #expect(ids(CleanupFilter(search: "acme")) == ["sms"])
        #expect(ids(CleanupFilter(search: "ann.lee@example")) == ["ann"])
        #expect(ids(CleanupFilter(search: "   ")) == Self.book.map(\.id))
        #expect(ids(CleanupFilter(search: "nobody")) == [])
    }

    @Test("A phone is found by its digits however it is written")
    func searchPhoneDigits() {
        #expect(ids(CleanupFilter(search: "4155552671")) == ["ann"])
        #expect(Set(ids(CleanupFilter(search: "415-555"))) == ["ann", "nameless"])
        #expect(ids(CleanupFilter(search: "(415) 555-0300")) == ["nameless"])
        #expect(ids(CleanupFilter(search: "727")) == ["sms"])
    }

    @Test("Every word has to match, in any order; search and options combine")
    func searchWordsAndOptions() {
        #expect(ids(CleanupFilter(search: "lee ann")) == ["ann"])
        #expect(ids(CleanupFilter(search: "ann walsh")) == [])
        #expect(ids(CleanupFilter(noPhoneOrEmail: true, search: "walsh")) == ["bare"])
        #expect(ids(CleanupFilter(importedByContactBridge: true, search: "walsh")) == [])
    }

    // MARK: delete workflow

    private final class Clock: Sendable {
        private let time = Mutex(1_800_000_000.0)
        func now() -> Date { Date(timeIntervalSince1970: time.withLock { $0 }) }
        func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
    }

    private struct Failure: Error, LocalizedError {
        var errorDescription: String? { "disk full" }
    }

    private final class FailingLinks: LinkStoring {
        let inner = InMemoryLinkStore()
        func load() throws -> LinkTable { try inner.load() }
        func add(_ links: [ImportedLink], at date: Date) throws { try inner.add(links, at: date) }
        func remove(icloudIDs: [String]) throws { throw Failure() }
    }

    private final class FailingDismissals: DismissalStoring {
        let inner = InMemoryDismissalStore()
        func load() throws -> DismissalTable { try inner.load() }
        func dismiss(memberIDs: [String], at date: Date) throws { try inner.dismiss(memberIDs: memberIDs, at: date) }
        func dismiss(groups: [[String]], at date: Date) throws { try inner.dismiss(groups: groups, at: date) }
        func clear() throws { try inner.clear() }
        func forget(ids: [String]) throws -> Int { throw Failure() }
    }

    private struct Rig {
        let directory: URL
        let clock = Clock()
        let store: InMemoryContactStore
        let notes: InMemoryNotesStore
        let backups: BackupCoordinator
        let links: any LinkStoring
        let dismissals: any DismissalStoring
        let workflows: ContactWorkflows

        init(
            records: [ContactRecord] = CleanupTests.book, links: any LinkStoring = InMemoryLinkStore(),
            dismissals: any DismissalStoring = InMemoryDismissalStore(), withNotes: Bool = true, writerNotes: Bool = true
        ) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = InMemoryContactStore(records: records)
            notes = InMemoryNotesStore(notes: ["sms": "Verification codes", "blank": "Who is this?"])
            self.links = links
            self.dismissals = dismissals
            let store = store, notesStore = notes, directory = directory, clock = clock
            backups = BackupCoordinator(makeSetup: {
                BackupSetup(
                    writer: BackupWriter(store: store, notes: writerNotes ? notesStore : nil, baseDirectory: directory, now: { clock.now() }),
                    containerID: "A"
                )
            }, now: { clock.now() })
            workflows = ContactWorkflows(
                store: store, google: nil, notes: withNotes ? notesStore : nil, backups: backups, links: links, dismissals: dismissals,
                containerID: "A", now: { clock.now() }
            )
        }

        var backupFolders: Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.count
        }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test("Rows come from the store, flag linked contacts, and are sorted by name")
    func loadRows() async throws {
        let links = InMemoryLinkStore()
        try links.add([ImportedLink(icloudID: "ann", googleResourceName: "people/c1")], at: Date())
        let rig = try Rig(links: links)
        defer { rig.cleanUp() }
        let rows = try await rig.workflows.loadCleanupRows()
        #expect(rows.count == Self.book.count)
        #expect(rows.map(\.displayName) == ["Acme Rewards", "Ann Lee", "Henry Walsh", "No name", "No name", "Zoë Müller"])
        #expect(rows.filter(\.isImported).map(\.id) == ["ann"])
    }

    @Test("A delete takes a brand-new backup with notes even when a recent one exists, then deletes in one call")
    func deletes() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let earlier = try await rig.backups.backUpNow()
        rig.clock.advance(10)
        let phases = Mutex<[CleanupPhase]>([])
        let run = try await rig.workflows.deleteContacts(ids: ["sms", "blank", "sms"], progress: { phase in phases.withLock { $0.append(phase) } })
        #expect(run.deletedIDs == ["sms", "blank"] && run.deletedCount == 2 && run.followUpWarnings.isEmpty)
        #expect(run.receipt.id != earlier.id && run.receipt.manifest.notesIncluded && rig.backupFolders == 2)
        #expect(try await rig.store.fetchAll().map(\.id) == ["nameless", "bare", "ann", "zoe"])
        #expect(rig.store.mutationLog == [StoreMutation(kind: .delete, ids: ["sms", "blank"], receiptID: run.receipt.id)])
        #expect(phases.withLock { $0 } == [.backingUp, .deleting])
    }

    @Test("If the backup fails nothing is deleted")
    func backupFailureDeletesNothing() async throws {
        let rig = try Rig(writerNotes: false)
        defer { rig.cleanUp() }
        await #expect(throws: BackupCoordinatorError.requirementNotMet("notes")) { _ = try await rig.workflows.deleteContacts(ids: ["sms"]) }
        #expect(try await rig.store.fetchAll().count == Self.book.count && rig.store.mutationLog.isEmpty)
    }

    @Test("Without notes access, or with nothing chosen, it is refused before any backup")
    func refusals() async throws {
        let rig = try Rig(withNotes: false)
        defer { rig.cleanUp() }
        await #expect(throws: WorkflowError.notesUnavailable) { _ = try await rig.workflows.deleteContacts(ids: ["sms"]) }
        let ready = try Rig()
        defer { ready.cleanUp() }
        await #expect(throws: WorkflowError.nothingToDelete) { _ = try await ready.workflows.deleteContacts(ids: []) }
        #expect(rig.backupFolders == 0 && ready.backupFolders == 0)
        #expect(rig.store.mutationLog.isEmpty && ready.store.mutationLog.isEmpty)
    }

    @Test("A contact that has gone since the list was loaded stops everything: no backup, no deletion")
    func missingIDs() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        await #expect(throws: ContactStoreError.notFound(["ghost"])) { _ = try await rig.workflows.deleteContacts(ids: ["sms", "ghost"]) }
        #expect(try await rig.store.fetchAll().count == Self.book.count && rig.store.mutationLog.isEmpty && rig.backupFolders == 0)
    }

    @Test("Deleted contacts leave the import links; other links stay")
    func linksRemoved() async throws {
        let links = InMemoryLinkStore()
        try links.add([
            ImportedLink(icloudID: "sms", googleResourceName: "people/c1"), ImportedLink(icloudID: "ann", googleResourceName: "people/c2"),
        ], at: Date())
        let rig = try Rig(links: links)
        defer { rig.cleanUp() }
        let run = try await rig.workflows.deleteContacts(ids: ["sms", "blank"])
        #expect(run.linksRemoved == 1 && run.followUpWarnings.isEmpty)
        #expect(Array(try links.load().links.keys) == ["ann"])
    }

    @Test("Dismissed groups lose deleted members and are dropped below two")
    func dismissalsPruned() async throws {
        let dismissals = InMemoryDismissalStore()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try dismissals.dismiss(memberIDs: ["ann", "bare", "sms"], at: date)
        try dismissals.dismiss(memberIDs: ["sms", "blank"], at: date)
        try dismissals.dismiss(memberIDs: ["zoe", "nameless"], at: date)
        let rig = try Rig(dismissals: dismissals)
        defer { rig.cleanUp() }
        let run = try await rig.workflows.deleteContacts(ids: ["sms"])
        #expect(run.dismissalsPruned == 2 && run.followUpWarnings.isEmpty)
        #expect(try dismissals.load().dismissed.map(\.memberIDs).sorted { $0.joined() < $1.joined() } == [["ann", "bare"], ["nameless", "zoe"]])
    }

    @Test("The file-backed dismissal store trims sets and leaves the file alone when nothing matches")
    func fileStoreForget() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-dismiss-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DismissalStore(url: url)
        try store.dismiss(groups: [["a", "b", "c"], ["c", "d"]], at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try store.forget(ids: ["c"]) == 2)
        #expect(try store.load().dismissed.map(\.memberIDs) == [["a", "b"]])
        let before = try Data(contentsOf: url)
        #expect(try store.forget(ids: ["zzz"]) == 0)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("If tidying up fails after the delete, the contacts stay deleted and the run says what failed")
    func followUpFailures() async throws {
        let links = FailingLinks()
        try links.add([ImportedLink(icloudID: "sms", googleResourceName: "people/c1")], at: Date())
        let rig = try Rig(links: links, dismissals: FailingDismissals())
        defer { rig.cleanUp() }
        let run = try await rig.workflows.deleteContacts(ids: ["sms", "blank"])
        #expect(run.deletedCount == 2 && run.linksRemoved == 0 && run.dismissalsPruned == 0)
        #expect(run.followUpWarnings.count == 2 && run.followUpWarnings.allSatisfy { $0.contains("deleted") && $0.contains("disk full") })
        #expect(run.followUpWarnings[0].contains("import links") && run.followUpWarnings[1].contains("not duplicates"))
        #expect(try await rig.store.fetchAll().map(\.id) == ["nameless", "bare", "ann", "zoe"])
    }
}
