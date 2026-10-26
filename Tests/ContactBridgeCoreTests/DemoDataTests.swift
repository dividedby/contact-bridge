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
        let seeded = try demo.syncState.load()
        await engine.start()
        await engine.refreshPreview()

        let shown = await engine.current
        let preview = try #require(shown.preview)
        #expect(!shown.firstSyncApproved && preview.pause == nil)
        #expect(!preview.links.isEmpty && preview.creates.count >= 5)
        let kinds = Set(preview.reviews.map(\.kind))
        #expect(kinds.isSuperset(of: [.bothEdited, .possibleLink, .newInGoogle]))
        #expect(preview.reviews.allSatisfy { $0.name != "Unknown contact" })
        #expect(preview.links.contains { $0.name == "Ann Lee" } && preview.reviews.contains { $0.kind == .newInGoogle && $0.name == "Priya Patel" })
        let before = await demo.google.allPeople.count
        #expect(try demo.syncState.load() == seeded && demo.links.load().links.count == 8, "the preview changed nothing")

        #expect(await engine.approveFirstSync() == .started)
        let after = await engine.current
        #expect(after.firstSyncApproved && after.status == .idle && after.preview == nil)
        #expect(after.lastRun?.created == preview.creates.count)
        #expect(after.pendingReviews == preview.reviews.count)
        let people = await demo.google.allPeople.count
        #expect(people == before + preview.creates.count)
        await engine.stop()
    }

    @Test("The forget-links demo: Start syncing asks twice, the second question names the six contacts whose old links would go, and two confirms finish it")
    func forgetLinksDemo() async throws {
        let demo = DemoData.make(forgottenLinks: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-forget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = engine(demo, directory: directory)
        await engine.start()
        await engine.refreshPreview()
        let preview = try #require(await engine.current.preview)
        guard case .needsConfirmation(let first)? = preview.pause else {
            Issue.record("expected the preview to carry the Google-missing confirmation, got \(String(describing: preview.pause))")
            return
        }
        #expect(first.hasPrefix(SyncPlanner.googleMissingSummaryPrefix), "that guard fires first, so the preview itself is empty")

        _ = await engine.approveFirstSync()
        var shown = await engine.current
        #expect(shown.confirmationSummary == first && shown.pauseDetails.isEmpty)
        await engine.confirmAndContinue()
        shown = await engine.current
        #expect(shown.confirmationSummary?.contains("forget 6 of 14 links to contacts gone from both sides") == true)
        #expect(shown.pauseDetails.map(\.name) == ["Alan Cooper", "Beth Ward", "Chris Doyle", "Dina Moss", "Eli Park", "Fay Ross"])
        #expect(try demo.links.load().links.count == 14, "nothing is forgotten until the user confirms")

        await engine.confirmAndContinue()
        shown = await engine.current
        #expect(shown.status == .idle && shown.confirmationSummary == nil && shown.pauseDetails.isEmpty)
        #expect(try demo.links.load().links.keys.contains { $0.hasPrefix("demo-gone") } == false)
        await engine.stop()
    }

    private func approved(_ demo: DemoEnvironment, directory: URL) async -> SyncEngine {
        let engine = engine(demo, directory: directory)
        await engine.start()
        await engine.refreshPreview()
        _ = await engine.approveFirstSync()
        return engine
    }

    private func workflows(_ demo: DemoEnvironment, directory: URL) -> ReviewWorkflows {
        let store = demo.store, google = demo.google, notes = demo.notes
        let backups = BackupCoordinator(makeSetup: {
            BackupSetup(writer: BackupWriter(store: store, google: google, notes: notes, baseDirectory: directory), containerID: "demo-icloud")
        })
        return ReviewWorkflows(
            store: store, google: google, notes: notes, backups: backups, links: demo.links, state: demo.syncState, reviews: demo.reviews,
            journal: demo.journal, history: demo.history, gate: WriteGate(), containerID: "demo-icloud"
        )
    }

    @Test("After Start syncing the demo's review list holds one of every kind a person can decide on")
    func reviewKinds() async throws {
        let demo = DemoData.make()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-review-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = await approved(demo, directory: directory)
        let items = await engine.current.reviewItems
        func has(_ kind: ReviewKind, _ name: String) -> Bool { items.contains { $0.kind == kind && $0.name == name } }

        #expect(has(.googleEdited, "Leo Fischer"), "edited in Google")
        #expect(has(.deletedInGoogle, "Mia Chen"), "deleted in Google")
        #expect(has(.bothEdited, "David Brown"), "edited on both sides")
        #expect(has(.newInGoogle, "Priya Patel"), "new in Google")
        #expect(items.contains { $0.kind == .possibleLink }, "a possible match")
        #expect(items.contains { $0.kind == .bothEdited && $0.isFirstLink }, "a conflict from linking two contacts for the first time")
        #expect(items.filter { $0.kind == .bothEdited && !$0.isFirstLink }.map(\.name) == ["David Brown"])
        #expect(items.allSatisfy { $0.name != "Unknown contact" })
        await engine.stop()
    }

    @Test("Leo's review shows a phone removed in Google, a Google-only email and a new one, and deciding on it settles the demo")
    func leoReview() async throws {
        let demo = DemoData.make()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-leo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = await approved(demo, directory: directory)
        let workflows = workflows(demo, directory: directory)
        let item = try #require(try demo.reviews.load().first { $0.kind == .googleEdited })
        #expect(item.fields == [.organization, .phones, .emails])

        let detail = try await workflows.loadDetail(item)
        let draft = try #require(detail.draft)
        let phones = try #require(draft.lists.first { $0.field == .phones }).rows
        #expect(phones.contains { $0.status == .removedInGoogle })
        let emails = try #require(draft.lists.first { $0.field == .emails }).rows
        #expect(emails.contains { $0.status == .googleOnly } && emails.contains { $0.status == .addedInGoogle })

        #expect(try await workflows.apply(detail) == .done(warnings: []))
        await engine.syncNow()
        let leo = try #require(try await demo.store.fetchAll().first { $0.givenName == "Leo" })
        #expect(leo.organization == "Fischer Design" && leo.phones.map(\.value) == ["415-555-0401"])
        #expect(leo.emails.map(\.value).contains("leo.f@gmail.example") && !leo.emails.map(\.value).contains("leo@fischerdesign.example"))
        let after = await engine.current
        #expect(!after.reviewItems.contains { $0.kind == .googleEdited } && after.lastRun?.updated == 0)
        await engine.stop()
    }

    @Test("Every kind of demo review can be decided, and the next run finds nothing left to send back for it")
    func decideEachKind() async throws {
        let demo = DemoData.make()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-each-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = await approved(demo, directory: directory)
        let workflows = workflows(demo, directory: directory)
        func item(_ kind: ReviewKind, _ name: String? = nil) async throws -> ReviewItem {
            let open = Set(try demo.reviews.load().map(\.id))
            let summaries = await engine.current.reviewItems.filter { open.contains($0.id) }
            let id = try #require(summaries.first { $0.kind == kind && (name == nil || $0.name == name) }?.id)
            return try #require(try demo.reviews.load().first { $0.id == id })
        }

        // David: both edited, iCloud's company wins.
        let david = try await workflows.loadDetail(try await item(.bothEdited, "David Brown"))
        #expect(try await workflows.apply(david) == .done(warnings: []))
        // Mia: deleted in Google, so she is deleted here too.
        let mia = try await workflows.loadDetail(try await item(.deletedInGoogle))
        #expect(try await workflows.deleteFromICloud(mia) == .done(warnings: []))
        // Priya: imported.
        let priya = try await workflows.loadDetail(try await item(.newInGoogle, "Priya Patel"))
        #expect(try await workflows.importToICloud(priya) == .done(warnings: []))
        // Tom: ignored.
        try await workflows.ignore(try await item(.newInGoogle, "Tom Nguyen"))
        // Janet resembles both Carters; she is kept apart from each.
        try await workflows.keepSeparate(try await item(.possibleLink))
        try await workflows.keepSeparate(try await item(.possibleLink))
        await engine.syncNow()

        let records = try await demo.store.fetchAll()
        #expect(records.contains { $0.givenName == "Priya" } && !records.contains { $0.givenName == "Mia" })
        #expect(records.first { $0.givenName == "David" }?.organization == "Brown & Co")
        let people = await demo.google.allPeople
        #expect(people.first { $0.names?.first?.givenName == "David" }?.organizations?.first?.name == "Brown & Co")
        let remaining = await engine.current.reviewItems
        #expect(!remaining.contains { $0.name == "David Brown" || $0.name == "Mia Chen" || $0.name == "Priya Patel" || $0.name == "Tom Nguyen" })
        #expect(!remaining.contains { $0.kind == .possibleLink } && remaining.contains { $0.kind == .newInGoogle && $0.name == "Janet Carter" })
        let state = try demo.syncState.load()
        #expect(state.ignoredGoogle.count == 1 && state.keepSeparate.count == 2)
        await engine.stop()
    }
}
