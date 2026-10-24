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

    @Test("The demo environment is self-contained and starts authorized with a single iCloud container")
    func environment() async throws {
        let demo = DemoData.make()
        #expect(await demo.store.authorizationStatus() == .authorized)
        #expect(ContainerSelection.choose(from: demo.containers) == .selected(demo.containers[0]))
        #expect(try demo.links.load().links.isEmpty && demo.dismissals.load().dismissed.isEmpty)
        #expect(demo.accountEmail.contains("@"))
    }
}
