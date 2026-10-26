import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

struct ContactWorkflowsTests {
    private struct Rig {
        let directory: URL
        let store: InMemoryContactStore
        let google: FakeGoogleClient
        let notes: InMemoryNotesStore
        let links = InMemoryLinkStore()
        let dismissals = InMemoryDismissalStore()
        let backups: BackupCoordinator
        let container = Box()
        let notesForWorkflows: InMemoryNotesStore?

        /// What the coordinator's writer reports as the current container.
        final class Box: Sendable {
            private let value = Mutex<String?>("A")
            var current: String? {
                get { value.withLock { $0 } }
                set { value.withLock { $0 = newValue } }
            }
        }

        var workflows: ContactWorkflows { workflows(containerID: "A") }

        func workflows(containerID: String?) -> ContactWorkflows {
            ContactWorkflows(
                store: store, google: google, notes: notesForWorkflows, backups: backups, links: links, dismissals: dismissals,
                containerID: containerID
            )
        }

        /// - Parameters:
        ///   - withNotes: the workflows have a notes store.
        ///   - writerNotes: the backup writer includes notes (defaults to `withNotes`).
        ///   - writerGoogle: the backup writer includes Google.
        init(
            records: [ContactRecord], people: [GooglePerson] = [], others: [GooglePerson] = [], notes: [String: String] = [:],
            withNotes: Bool = true, writerNotes: Bool? = nil, writerGoogle: Bool = true
        ) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = InMemoryContactStore(records: records)
            google = FakeGoogleClient(people: people, otherContacts: others)
            self.notes = InMemoryNotesStore(notes: notes)
            let store = store, google = google, directory = directory
            let notesStore = self.notes
            let box = container
            let includeNotes = writerNotes ?? withNotes
            backups = BackupCoordinator(makeSetup: {
                BackupSetup(
                    writer: BackupWriter(
                        store: store, google: writerGoogle ? google : nil, notes: includeNotes ? notesStore : nil, baseDirectory: directory
                    ),
                    containerID: box.current
                )
            })
            notesForWorkflows = withNotes ? notesStore : nil
        }

        var backupFolders: Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.count
        }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private func icloud(_ id: String, _ given: String, _ family: String, phone: String? = nil, email: String? = nil) -> ContactRecord {
        ContactRecord(
            id: id, source: .icloud, sourceIdentifier: id, givenName: given, familyName: family,
            phones: phone.map { [Labeled(label: "mobile", value: $0)] } ?? [], emails: email.map { [Labeled(label: "home", value: $0)] } ?? []
        )
    }

    private func gperson(_ given: String, _ family: String, phone: String? = nil, email: String? = nil) -> GooglePerson {
        GooglePersonMapper.createPayload(for: icloud("x", given, family, phone: phone, email: email))
    }

    // MARK: import

    @Test("Import plan comes from the store and both Google lists")
    func importPlan() async throws {
        let rig = try Rig(
            records: [icloud("i1", "Ann", "Lee", phone: "415-555-2671")],
            people: [gperson("Ann", "Lee", phone: "+14155552671"), gperson("Bob", "Stone", phone: "415-555-0002")],
            others: [gperson("Cara", "Dune", email: "cara@example.com")]
        )
        defer { rig.cleanUp() }
        let plan = try await rig.workflows.loadImportPlan()
        #expect(plan.links.count == 1 && plan.toImport.map(\.record.givenName) == ["Bob"] && plan.otherContactCandidates.map(\.record.givenName) == ["Cara"])
    }

    @Test("The import plan uses saved links: an imported contact is never offered again, even if it no longer matches")
    func importPlanUsesSavedLinks() async throws {
        let rig = try Rig(records: [icloud("i9", "", "")], people: [gperson("Ann", "Lee", phone: "415-555-2671")])
        defer { rig.cleanUp() }
        let resourceName = try #require(try await rig.google.listConnections(syncToken: nil, pageToken: nil).people.first?.resourceName)
        try rig.links.add([ImportedLink(icloudID: "i9", googleResourceName: resourceName)], at: Date())
        let plan = try await rig.workflows.loadImportPlan()
        #expect(plan.toImport.isEmpty)
        #expect(plan.links.map(\.icloudID) == ["i9"])
    }

    @Test("Without Google there is nothing to plan")
    func importWithoutGoogle() async throws {
        let rig = try Rig(records: [])
        defer { rig.cleanUp() }
        let workflows = ContactWorkflows(
            store: rig.store, google: nil, notes: nil,
            backups: BackupCoordinator(makeWriter: { BackupWriter(store: rig.store, baseDirectory: rig.directory) }),
            links: rig.links, dismissals: rig.dismissals
        )
        await #expect(throws: GoogleAuthError.notSignedIn) { _ = try await workflows.loadImportPlan() }
    }

    @Test("Running an import takes a backup first, creates the selection and records links; a second run reuses the backup")
    func runImport() async throws {
        let rig = try Rig(records: [], people: [gperson("Ann", "Lee", phone: "415-555-2671"), gperson("Bob", "Stone", phone: "415-555-0002")])
        defer { rig.cleanUp() }
        let plan = try await rig.workflows.loadImportPlan()
        #expect(rig.backupFolders == 0)
        let run = try await rig.workflows.runImport(plan.toImport)
        #expect(run.result.isComplete && run.result.created.count == 2)
        #expect(rig.backupFolders == 1)
        #expect(rig.store.mutationLog.allSatisfy { $0.receiptID == run.receipt.id })
        #expect(try rig.links.load().links.count == 2)

        _ = try await rig.workflows.runImport([plan.toImport[0]])
        #expect(rig.backupFolders == 1)
    }

    // MARK: dedupe

    @Test("Duplicate scan hides dismissed clusters and counts them")
    func scanHidesDismissed() async throws {
        let rig = try Rig(records: [
            icloud("a1", "Ann", "Lee", phone: "415-555-2671"), icloud("a2", "Ann", "Lee", phone: "415-555-2671"),
            icloud("b1", "Bob", "Stone", email: "bob@example.com"), icloud("b2", "Bob", "Stone", email: "bob@example.com"),
        ])
        defer { rig.cleanUp() }
        let first = try await rig.workflows.loadDuplicates()
        #expect(first.clusters.count == 2 && first.hiddenCount == 0 && first.records.count == 4)

        try rig.workflows.dismiss(MergeDraft(cluster: first.clusters[0]))
        let second = try await rig.workflows.loadDuplicates()
        #expect(second.clusters.count == 1 && second.hiddenCount == 1)
        #expect(second.clusters[0].id != first.clusters[0].id)

        try rig.workflows.restoreDismissed()
        #expect(try await rig.workflows.loadDuplicates().clusters.count == 2)
    }

    @Test("Merging takes a backup, merges contacts and notes, and reports the outcome")
    func runMerge() async throws {
        let rig = try Rig(
            records: [icloud("a1", "Ann", "Lee", phone: "415-555-2671"), icloud("a2", "Ann", "Lee", phone: "415-555-2671", email: "ann@example.com")],
            notes: ["a1": "First note", "a2": "Second note"]
        )
        defer { rig.cleanUp() }
        let scan = try await rig.workflows.loadDuplicates()
        var draft = MergeDraft(cluster: try #require(scan.clusters.first))
        draft.chooseSurvivor("a1")
        let run = try await rig.workflows.runMerge(draft)
        #expect(run.outcome.notes == .written)
        #expect(run.survivor.id == "a1" && run.deleted.map(\.id) == ["a2"])
        #expect(rig.backupFolders == 1)
        let remaining = try await rig.store.fetchAll()
        #expect(remaining.map(\.id) == ["a1"] && remaining[0].emails.map(\.value) == ["ann@example.com"])
        #expect(rig.notes.writes.map(\.note) == ["First note\n\nSecond note"])
    }

    @Test("A notes failure before the merge leaves every contact in place")
    func mergeAbortsWhenNotesUnreadable() async throws {
        let rig = try Rig(records: [icloud("a1", "Ann", "Lee", phone: "415-555-2671"), icloud("a2", "Ann", "Lee", phone: "415-555-2671")], withNotes: true)
        defer { rig.cleanUp() }
        let scan = try await rig.workflows.loadDuplicates()
        let draft = MergeDraft(cluster: try #require(scan.clusters.first))
        rig.notes.setReadError(NotesAccessError.notAuthorized)
        await #expect(throws: (any Error).self) { _ = try await rig.workflows.runMerge(draft) }
        #expect(try await rig.store.fetchAll().count == 2)
    }

    @Test("Notes for the preview come from one read of the given ids")
    func loadNotes() async throws {
        let rig = try Rig(records: [], notes: ["a1": "x", "zz": "y"])
        defer { rig.cleanUp() }
        #expect(try await rig.workflows.loadNotes(ids: ["a1", "a2"]) == ["a1": "x"])
    }

    @Test("Without a notes store the preview has no notes and a merge is refused before anything happens")
    func noNotesStore() async throws {
        let rig = try Rig(records: [icloud("a1", "Ann", "Lee", phone: "415-555-2671"), icloud("a2", "Ann", "Lee", phone: "415-555-2671")], withNotes: false)
        defer { rig.cleanUp() }
        #expect(try await rig.workflows.loadNotes(ids: ["a1"]).isEmpty)
        let scan = try await rig.workflows.loadDuplicates()
        let draft = MergeDraft(cluster: try #require(scan.clusters.first))
        await #expect(throws: WorkflowError.notesUnavailable) { _ = try await rig.workflows.runMerge(draft) }
        #expect(try await rig.store.fetchAll().count == 2)
        #expect(rig.backupFolders == 0)
    }

    @Test("A merge is refused if the backup could not include notes, and nothing is merged")
    func mergeNeedsNotesInBackup() async throws {
        let rig = try Rig(
            records: [icloud("a1", "Ann", "Lee", phone: "415-555-2671"), icloud("a2", "Ann", "Lee", phone: "415-555-2671")],
            writerNotes: false
        )
        defer { rig.cleanUp() }
        let scan = try await rig.workflows.loadDuplicates()
        let draft = MergeDraft(cluster: try #require(scan.clusters.first))
        await #expect(throws: BackupCoordinatorError.self) { _ = try await rig.workflows.runMerge(draft) }
        #expect(try await rig.store.fetchAll().count == 2)
    }

    @Test("An import is refused if the backup did not include Google")
    func importNeedsGoogleInBackup() async throws {
        let rig = try Rig(records: [], people: [gperson("Bob", "Stone", phone: "415-555-0002")], writerGoogle: false)
        defer { rig.cleanUp() }
        let plan = try await rig.workflows.loadImportPlan()
        await #expect(throws: BackupCoordinatorError.self) { _ = try await rig.workflows.runImport(plan.toImport) }
        #expect(try await rig.store.fetchAll().isEmpty)
    }

    @Test("After the container changes, an import or merge takes a backup of the new one")
    func containerChangeForcesNewBackup() async throws {
        let rig = try Rig(records: [], people: [gperson("Bob", "Stone", phone: "415-555-0002")])
        defer { rig.cleanUp() }
        let plan = try await rig.workflows.loadImportPlan()
        _ = try await rig.workflows.runImport(plan.toImport)
        #expect(rig.backupFolders == 1)
        rig.container.current = "B"
        _ = try await rig.workflows(containerID: "B").runImport(plan.toImport)
        #expect(rig.backupFolders == 2)
    }

    @Test("Not duplicates dismisses the members that remain in the draft, not ones the user removed")
    func dismissUsesRemainingMembers() async throws {
        let rig = try Rig(records: [
            icloud("m1", "Maria", "Garcia", email: "m@example.com"), icloud("m2", "Maria", "Garcia", email: "m@example.com"),
            icloud("m3", "Maria", "Garcia", email: "m@example.com"),
        ])
        defer { rig.cleanUp() }
        let scan = try await rig.workflows.loadDuplicates()
        var draft = MergeDraft(cluster: try #require(scan.clusters.first))
        #expect(draft.members.count == 3)
        let removed = draft.remove(memberID: "m3")
        #expect(removed)
        try rig.workflows.dismiss(draft)
        #expect(try rig.dismissals.load().dismissed.map(\.memberIDs) == [["m1", "m2"]])
        // The three-way cluster is not a subset of the dismissed pair, so it is still offered.
        #expect(try await rig.workflows.loadDuplicates().clusters.first?.members.count == 3)
    }
}
