import Foundation
import Testing
@testable import ContactBridgeCore

/// The demo exists to exercise every screen, so it must really contain what each screen needs.
struct DemoDataTests {
    @Test("The demo book has a clear duplicate, a household-phone conflict, a three-way cluster and merge conflicts")
    func dedupeScenarios() async throws {
        let demo = DemoData.make()
        let records = try await demo.store.fetchAll()
        let clusters = DuplicateMatcher().analyze(records).clusters
        #expect(clusters.contains { $0.level == .high && $0.flags.isEmpty })
        #expect(clusters.contains { $0.flags.contains(.sharedPhoneDifferentNames) })
        #expect(clusters.contains { $0.members.count >= 3 })
        let plans = clusters.map { MergePlan.build(survivor: $0.members[0], others: Array($0.members.dropFirst())) }
        #expect(plans.contains { !$0.conflicts.isEmpty })
        #expect(plans.contains { !$0.droppedLabels.isEmpty })
        let notes = try await demo.notes.fetchNotes(ids: records.map(\.sourceIdentifier))
        #expect(notes.count >= 2)
    }

    @Test("The demo book has safe groups, tick-by-hand groups and groups that need review for bulk actions")
    func bulkScenarios() async throws {
        let demo = DemoData.make()
        let clusters = DuplicateMatcher().analyze(try await demo.store.fetchAll()).clusters
        #expect(clusters.filter { $0.bulkEligibility == .safe }.count >= 3)
        #expect(clusters.contains { $0.bulkEligibility == .eligible })
        #expect(clusters.contains { $0.bulkEligibility == .needsReview })
    }

    @Test("The demo book gives every Clean up filter something to show, and keeps those contacts out of Dedupe")
    func cleanupScenarios() async throws {
        let demo = DemoData.make()
        let records = try await demo.store.fetchAll()
        let imported = Set(try demo.links.load().links.keys)
        let rows = records.map { CleanupRow(record: $0, isImported: imported.contains($0.sourceIdentifier)) }
        #expect(CleanupFilter(textMessageSenders: true).apply(to: rows).count >= 2)
        #expect(CleanupFilter(noName: true).apply(to: rows).count >= 2)
        #expect(CleanupFilter(noPhoneOrEmail: true).apply(to: rows).count >= 2)
        #expect(CleanupFilter(importedByContactBridge: true).apply(to: rows).count >= 2)
        #expect(CleanupFilter(textMessageSenders: true, noName: true).apply(to: rows).count >= 1)

        let clean = Set(CleanupFilter(textMessageSenders: true).apply(to: rows).map(\.id))
            .union(CleanupFilter(noName: true).apply(to: rows).map(\.id))
            .union(CleanupFilter(noPhoneOrEmail: true).apply(to: rows).map(\.id))
        let grouped = Set(DuplicateMatcher().analyze(records).clusters.flatMap { $0.members.map(\.id) })
        #expect(clean.isDisjoint(with: grouped))
    }

    @Test("The demo Google account yields links, imports, other-contact candidates and a possible match")
    func importScenarios() async throws {
        let demo = DemoData.make()
        let plan = ImportPlanner().plan(
            icloud: try await demo.store.fetchAll(),
            googleConnections: try await demo.google.allConnections(),
            googleOtherContacts: try await demo.google.allOtherContacts()
        )
        #expect(!plan.links.isEmpty)
        #expect(plan.toImport.count >= 2)
        #expect(plan.otherContactCandidates.count >= 2)
        #expect(!plan.possibleMatches.isEmpty)
    }

    @Test("The demo import list has a business and a text-message sender, so both selection shortcuts visibly do something")
    func importSelectionShortcuts() async throws {
        let demo = DemoData.make()
        let plan = ImportPlanner().plan(
            icloud: try await demo.store.fetchAll(),
            googleConnections: try await demo.google.allConnections(),
            googleOtherContacts: try await demo.google.allOtherContacts()
        )
        let everyone = Set(plan.toImport.map(\.id))
        #expect(plan.toImport.contains { !$0.isPerson && !$0.isShortCodeSender })
        #expect(plan.toImport.contains { $0.isShortCodeSender })
        #expect(ImportSelection.peopleOnly(plan.toImport).count < everyone.count)
        #expect(ImportSelection.excludingTextMessageSenders(everyone, from: plan.toImport).count < everyone.count)
    }

    @Test("The demo environment is self-contained and starts authorized with a single iCloud container")
    func environment() async throws {
        let demo = DemoData.make()
        #expect(await demo.store.authorizationStatus() == .authorized)
        #expect(ContainerSelection.choose(from: demo.containers) == .selected(demo.containers[0]))
        #expect(try demo.dismissals.load().dismissed.isEmpty)
        #expect(demo.accountEmail.contains("@"))
    }
}

/// The Sync screen's demo: the real engine over the demo fakes must show a first sync with something of each kind in it.
struct DemoSyncTests {
    private func engine(_ demo: DemoEnvironment, directory: URL) -> SyncEngine {
        let store = demo.store, google = demo.google, notes = demo.notes, email = demo.accountEmail
        let backups = BackupCoordinator(makeSetup: {
            BackupSetup(writer: BackupWriter(store: store, google: google, notes: notes, baseDirectory: directory), containerID: "demo-icloud")
        })
        return SyncEngine(
            environment: { .ready(SyncEnvironment(store: store, notes: notes, google: google, accountEmail: email, containerID: "demo-icloud")) },
            links: demo.links, state: demo.syncState, reviews: demo.reviews, journal: demo.journal, history: demo.history, backups: backups
        )
    }

    @Test("The demo's first-sync preview links, creates and asks about each kind of review; Start syncing then really runs it")
    func firstSync() async throws {
        let demo = DemoData.make()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = engine(demo, directory: directory)
        await engine.start()
        await engine.refreshPreview()

        let shown = await engine.current
        let preview = try #require(shown.preview)
        #expect(!shown.firstSyncApproved && preview.pause == nil)
        #expect(preview.links.count >= 3 && preview.creates.count >= 5)
        let kinds = Set(preview.reviews.map(\.kind))
        #expect(kinds.isSuperset(of: [.bothEdited, .possibleLink, .newInGoogle]))
        #expect(preview.reviews.allSatisfy { $0.name != "Unknown contact" })
        #expect(preview.links.contains { $0.name == "Ann Lee" } && preview.reviews.contains { $0.kind == .newInGoogle && $0.name == "Priya Patel" })
        let before = await demo.google.allPeople.count
        #expect(try demo.syncState.load() == SyncState() && demo.links.load().links.count == 3, "the preview changed nothing")

        #expect(await engine.approveFirstSync() == .started)
        let after = await engine.current
        #expect(after.firstSyncApproved && after.status == .idle && after.preview == nil)
        #expect(after.lastRun?.created == preview.creates.count)
        #expect(after.pendingReviews == preview.reviews.count)
        let people = await demo.google.allPeople.count
        #expect(people == before + preview.creates.count)
        await engine.stop()
    }
}
