import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

struct BulkMergeTests {
    private final class Clock: Sendable {
        private let time = Mutex(1_800_000_000.0)
        func now() -> Date { Date(timeIntervalSince1970: time.withLock { $0 }) }
        func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
    }

    private final class Flag: Sendable {
        private let value = Mutex(false)
        var isSet: Bool { value.withLock { $0 } }
        func set() { value.withLock { $0 = true } }
    }

    /// Three clean duplicate pairs (a, b, c), each a safe group.
    private struct Rig {
        let directory: URL
        let clock = Clock()
        let store: InMemoryContactStore
        let notes: InMemoryNotesStore
        let backups: BackupCoordinator
        let dismissals = InMemoryDismissalStore()
        let workflows: ContactWorkflows

        init(records: [ContactRecord]? = nil, notes noteText: [String: String] = [:], writeError: (any Error)? = nil, withNotes: Bool = true, writerNotes: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = InMemoryContactStore(records: records ?? Self.pairs)
            notes = InMemoryNotesStore(notes: noteText, writeError: writeError)
            let store = store, notesStore = notes, directory = directory, clock = clock
            backups = BackupCoordinator(makeSetup: {
                BackupSetup(
                    writer: BackupWriter(store: store, notes: writerNotes ? notesStore : nil, baseDirectory: directory, now: { clock.now() }),
                    containerID: "A"
                )
            }, now: { clock.now() })
            workflows = ContactWorkflows(
                store: store, google: nil, notes: withNotes ? notesStore : nil, backups: backups, links: InMemoryLinkStore(),
                dismissals: dismissals, containerID: "A", now: { clock.now() }
            )
        }

        static let pairs = [
            person("a1", "Ann", "Lee", phone: "415-555-0101"), person("a2", "Ann", "Lee", phone: "415-555-0101"),
            person("b1", "Bob", "Stone", phone: "415-555-0202"), person("b2", "Bob", "Stone", phone: "415-555-0202"),
            person("c1", "Cara", "Dune", phone: "415-555-0303"), person("c2", "Cara", "Dune", phone: "415-555-0303"),
        ]

        var backupFolders: Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.count
        }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }

        func drafts() async throws -> [MergeDraft] {
            try await workflows.loadDuplicates().clusters.map(MergeDraft.init)
        }
    }

    private static func person(_ id: String, _ given: String, _ family: String, phone: String? = nil, email: String? = nil, org: String = "") -> ContactRecord {
        ContactRecord(
            id: id, source: .icloud, sourceIdentifier: id, givenName: given, familyName: family, organization: org,
            phones: phone.map { [Labeled(label: "mobile", value: $0)] } ?? [], emails: email.map { [Labeled(label: "home", value: $0)] } ?? []
        )
    }

    private func clusters(_ records: [ContactRecord]) -> [DuplicateCluster] { DuplicateMatcher().analyze(records).clusters }

    // MARK: eligibility

    @Test("High confidence with no flags and no disagreeing fields is safe")
    func safe() throws {
        let cluster = try #require(clusters(Rig.pairs).first)
        #expect(cluster.bulkEligibility == .safe && MergeDraft(cluster: cluster).bulkEligibility == .safe)
    }

    @Test("Medium confidence, or an informational flag alone, is eligible but not safe")
    func eligible() throws {
        let medium = clusters([Self.person("o1", "Owen", "Hayes", phone: "415-555-0255"), Self.person("o2", "Owen", "Hayes", email: "o@example.com")])
        let first = try #require(medium.first)
        #expect(first.level == .medium && first.flags.isEmpty && first.bulkEligibility == .eligible)

        let warning = clusters([
            Self.person("p1", "Priscilla", "Wong", phone: "415-555-0266", email: "p@example.com"),
            Self.person("p2", "", "", phone: "415-555-0266", org: "Wong Bakery"),
        ])
        let second = try #require(warning.first)
        #expect(second.flags == [.sharedIdentifierUnnamedRecord] && second.bulkEligibility == .eligible)
    }

    @Test("A conflict flag, or fields that disagree, needs review even at high confidence")
    func needsReview() throws {
        let household = clusters([Self.person("j1", "John", "Carter", phone: "415-555-0142"), Self.person("j2", "Jane", "Carter", phone: "415-555-0142")])
        let flagged = try #require(household.first)
        #expect(flagged.flags.contains(where: \.isConflict) && flagged.bulkEligibility == .needsReview)

        let nickname = clusters([Self.person("r1", "Robert", "Smith", email: "b@example.com"), Self.person("r2", "Bob", "Smith", email: "b@example.com")])
        let disagreeing = try #require(nickname.first)
        #expect(disagreeing.level == .high && disagreeing.flags.isEmpty)
        #expect(!MergeDraft(cluster: disagreeing).conflicts.isEmpty && disagreeing.bulkEligibility == .needsReview)
    }

    // MARK: bulk merge

    @Test("A bulk merge takes one brand-new backup up front even when a recent one exists, then merges every group with it")
    func success() async throws {
        let rig = try Rig(notes: ["a1": "First", "a2": "Second"])
        defer { rig.cleanUp() }
        let earlier = try await rig.backups.backUpNow()
        rig.clock.advance(10)
        let drafts = try await rig.drafts()
        #expect(drafts.count == 3 && drafts.allSatisfy { $0.bulkEligibility == .safe })

        let log = Mutex<[BulkProgress]>([])
        let report = try await rig.workflows.runBulkMerge(drafts, progress: { update in log.withLock { $0.append(update) } })
        #expect(report.isComplete && report.mergedCount == 3 && report.deletedCount == 3 && report.notRunCount == 0)
        #expect(report.receipts.count == 1)
        let receipt = try #require(report.receipt)
        #expect(receipt.id != earlier.id && rig.backupFolders == 2)
        #expect(rig.store.mutationLog.count == 3 && rig.store.mutationLog.allSatisfy { $0.kind == .merge && $0.receiptID == receipt.id })
        #expect(try await rig.store.fetchAll().map(\.id) == ["a1", "b1", "c1"])
        #expect(rig.notes.writes.map(\.note) == ["First\n\nSecond"])
        #expect(log.withLock { $0.first } == BulkProgress(phase: .backingUp, completed: 0, total: 3))
        #expect(log.withLock { $0.last } == BulkProgress(phase: .merging, completed: 3, total: 3))
        #expect(log.withLock { $0.filter { $0.phase == .merging }.map(\.completed) } == [0, 1, 2, 3])
    }

    @Test("A bulk merge that outlives the backup's freshness takes another backup between groups")
    func longRunRefreshesBackup() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let drafts = try await rig.drafts()
        let report = try await rig.workflows.runBulkMerge(drafts, progress: { update in
            if update.phase == .merging, update.completed == 1 { rig.clock.advance(4000) }
        })
        #expect(report.isComplete && report.mergedCount == 3)
        #expect(report.receipts.count == 2 && rig.backupFolders == 2)
        let ids = rig.store.mutationLog.map(\.receiptID)
        #expect(ids == [report.receipts[0].id, report.receipts[1].id, report.receipts[1].id])
    }

    @Test("A failed group stops the run: it is reported, the rest are not run, and nothing later is touched")
    func stopsOnFirstError() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let drafts = try await rig.drafts()
        let report = try await rig.workflows.runBulkMerge(drafts, progress: { update in
            // Reading notes fails from the second group on, before that group's merge.
            if update.phase == .merging, update.completed == 1 { rig.notes.setReadError(NotesAccessError.notAuthorized) }
        })
        #expect(report.stop == .stoppedOnProblem && report.mergedCount == 1 && report.notRunCount == 1)
        guard case .merged = report.entries[0].outcome, case .failed = report.entries[1].outcome else {
            Issue.record("unexpected outcomes \(report.entries.map(\.outcome))")
            return
        }
        #expect(report.entries[2].outcome == .notRun)
        #expect(try await rig.store.fetchAll().count == 5 && rig.store.mutationLog.count == 1)
    }

    @Test("A group whose contacts have gone since the scan is a failure and nothing after it runs")
    func membersGone() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let drafts = try await rig.drafts()
        let victim = try #require(drafts[1].others.first)
        try await rig.store.delete(ids: [victim.sourceIdentifier], backup: .forTesting(createdAt: rig.clock.now()))
        let report = try await rig.workflows.runBulkMerge(drafts)
        #expect(report.stop == .stoppedOnProblem && report.mergedCount == 1 && report.notRunCount == 1)
        guard case .failed(let reason) = report.entries[1].outcome else {
            Issue.record("unexpected outcomes \(report.entries.map(\.outcome))")
            return
        }
        #expect(reason.contains(victim.displayName))
        #expect(rig.store.mutationLog.filter { $0.kind == .merge }.count == 1)
    }

    @Test("A combined note that could not be saved counts as a problem: the merge stands, later groups are not run")
    func noteWriteFailureStops() async throws {
        struct NoteError: Error, LocalizedError { var errorDescription: String? { "disk full" } }
        let rig = try Rig(notes: ["a1": "A", "b1": "B1", "b2": "B2", "c1": "C"], writeError: NoteError())
        defer { rig.cleanUp() }
        let report = try await rig.workflows.runBulkMerge(try await rig.drafts())
        // Group a has one note and nothing to add, so it is unchanged; group b's combined note cannot be saved.
        #expect(report.stop == .stoppedOnProblem && report.mergedCount == 2 && report.notRunCount == 1)
        guard case .merged(_, _, let outcome, _) = report.entries[1].outcome, case .writeFailed(let combined, let reason) = outcome else {
            Issue.record("unexpected outcomes \(report.entries.map(\.outcome))")
            return
        }
        #expect(combined == "B1\n\nB2" && reason == "disk full")
        #expect(report.entries[2].outcome == .notRun)
        #expect(try await rig.store.fetchAll().map(\.id) == ["a1", "b1", "c1", "c2"])
    }

    @Test("Stop takes effect after the current group")
    func cancellation() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let stop = Flag()
        let report = try await rig.workflows.runBulkMerge(
            try await rig.drafts(),
            progress: { update in if update.phase == .merging, update.completed == 0 { stop.set() } },
            isCancelled: { stop.isSet }
        )
        // Stop was requested while the first group was starting: that group finishes, the others do not run.
        #expect(report.stop == .stoppedByUser && report.mergedCount == 1 && report.notRunCount == 2)
        #expect(try await rig.store.fetchAll().count == 5)
    }

    @Test("If the new backup fails, nothing is merged and the report says so")
    func backupFailureMergesNothing() async throws {
        let rig = try Rig(writerNotes: false)
        defer { rig.cleanUp() }
        let report = try await rig.workflows.runBulkMerge(try await rig.drafts())
        guard case .backupFailed = report.stop else {
            Issue.record("unexpected stop \(report.stop)")
            return
        }
        #expect(report.mergedCount == 0 && report.notRunCount == 3 && report.receipts.isEmpty)
        #expect(try await rig.store.fetchAll().count == 6 && rig.store.mutationLog.isEmpty)
    }

    @Test("Groups that need review are refused before any backup or change")
    func refusesNeedsReview() async throws {
        let rig = try Rig(records: Rig.pairs + [
            Self.person("r1", "Robert", "Smith", email: "b@example.com"), Self.person("r2", "Bob", "Smith", email: "b@example.com"),
        ])
        defer { rig.cleanUp() }
        let drafts = try await rig.drafts()
        let review = try #require(drafts.first { $0.bulkEligibility == .needsReview })
        await #expect(throws: WorkflowError.needsReview(groupIDs: [review.cluster.id])) { _ = try await rig.workflows.runBulkMerge(drafts) }
        #expect(rig.backupFolders == 0 && rig.store.mutationLog.isEmpty)
    }

    @Test("Nothing to merge, or no notes store, is refused before anything happens")
    func refusals() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        await #expect(throws: WorkflowError.nothingToMerge) { _ = try await rig.workflows.runBulkMerge([]) }
        let drafts = try await rig.drafts()

        let withoutNotes = try Rig(withNotes: false)
        defer { withoutNotes.cleanUp() }
        await #expect(throws: WorkflowError.notesUnavailable) { _ = try await withoutNotes.workflows.runBulkMerge(drafts) }
        #expect(rig.backupFolders == 0 && withoutNotes.backupFolders == 0)
    }

    // MARK: bulk dismiss

    private final class CountingDismissals: DismissalStoring {
        let inner = InMemoryDismissalStore()
        let calls = Mutex((single: 0, group: 0))
        func load() throws -> DismissalTable { try inner.load() }
        func dismiss(memberIDs: [String], at date: Date) throws {
            calls.withLock { $0.single += 1 }
            try inner.dismiss(memberIDs: memberIDs, at: date)
        }
        func dismiss(groups: [[String]], at date: Date) throws {
            calls.withLock { $0.group += 1 }
            try inner.dismiss(groups: groups, at: date)
        }
        func clear() throws { try inner.clear() }
        func forget(ids: [String]) throws -> Int { try inner.forget(ids: ids) }
    }

    @Test("Not duplicates for several groups is one write that hides them all")
    func bulkDismissIsOneWrite() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let dismissals = CountingDismissals()
        let workflows = ContactWorkflows(
            store: rig.store, google: nil, notes: rig.notes, backups: rig.backups, links: InMemoryLinkStore(), dismissals: dismissals
        )
        let drafts = try await workflows.loadDuplicates().clusters.map(MergeDraft.init)
        try workflows.dismiss(Array(drafts.prefix(2)))
        #expect(dismissals.calls.withLock { $0.single == 0 && $0.group == 1 })
        let scan = try await workflows.loadDuplicates()
        #expect(scan.clusters.count == 1 && scan.hiddenCount == 2)
        #expect(try dismissals.load().dismissed.count == 2)
    }

    @Test("The file-backed store saves several groups together and leaves the file alone when nothing is new")
    func fileStoreBulkDismiss() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-dismiss-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DismissalStore(url: url)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try store.dismiss(groups: [["a", "b"], ["c", "d", "e"], ["x"]], at: date)
        #expect(try store.load().dismissed.map(\.memberIDs) == [["a", "b"], ["c", "d", "e"]])
        let before = try Data(contentsOf: url)
        try store.dismiss(groups: [["b", "a"]], at: date.addingTimeInterval(60))
        #expect(try Data(contentsOf: url) == before)
    }
}
