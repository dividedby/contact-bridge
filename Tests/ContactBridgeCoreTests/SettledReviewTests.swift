import Foundation
import Testing
@testable import ContactBridgeCore

/// A first-link conflict is pinned, because nothing derives it again. When the two sides turn out to agree, the planner says so.
struct SettledReviewTests {
    private let t0 = SyncFixtures.t0

    private func item(fields: [SyncField] = [.phones], kind: ReviewKind = .bothEdited, pinned: Bool = true) -> ReviewItem {
        ReviewItem(
            candidate: ReviewCandidate(kind: kind, icloudID: "I1", resourceName: "people/c1", googleEtag: "e1", fields: fields), pinned: pinned, at: t0
        )
    }

    /// Ann is linked and synced; Bob is there to move the iCloud token.
    private func world() async throws -> SyncWorld {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Ann", "Lee", phones: ["415-555-2671"]), SyncFixtures.icloud("I2", "Bob", "Stone", phones: ["415-555-0002"])],
            google: [SyncFixtures.person("Ann", "Lee", phones: ["415-555-2671"]), SyncFixtures.person("Bob", "Stone", phones: ["415-555-0002"])]
        )
        try await world.settle()
        return world
    }

    @Test("A pinned conflict whose sides agree is settled; one that does not is kept")
    func settledWhenTheSidesAgree() async throws {
        let world = try await world()
        let stored = item()
        let plan = try await world.plan(.syncNow, requireFullListing: true, reviews: [stored])
        #expect(plan.settledReviews == [stored.id] && plan.review.isEmpty)
        #expect(plan.updates.isEmpty && plan.creates.isEmpty && plan.deletes.isEmpty && plan.baselineRefreshes.isEmpty && plan.links.isEmpty)

        try await world.editGoogle("people/c1", mask: "phoneNumbers") {
            $0.phoneNumbers = (($0.phoneNumbers ?? []) + [GooglePhoneNumber(value: "415-555-0003", type: "home")])
        }
        let moved = try await world.plan(.syncNow, requireFullListing: true, reviews: [stored])
        #expect(moved.settledReviews.isEmpty, "Google added a phone since the link: there is something to look at")
        #expect(moved.review.map(\.kind) == [.googleEdited])
    }

    @Test("Only pinned edit conflicts are settled")
    func onlyPinnedEditItems() async throws {
        let world = try await world()
        let others = [
            item(pinned: false), item(kind: .googleEdited, pinned: false),
            ReviewItem(candidate: ReviewCandidate(kind: .deletedInGoogle, icloudID: "I1", resourceName: "people/c1"), pinned: true, at: t0),
        ]
        let plan = try await world.plan(.syncNow, requireFullListing: true, reviews: others)
        #expect(plan.settledReviews.isEmpty)

        let pinnedGoogleEdited = item(kind: .googleEdited)
        #expect(try await world.plan(.syncNow, requireFullListing: true, reviews: [pinnedGoogleEdited]).settledReviews == [pinnedGoogleEdited.id])
    }

    @Test("Nothing is settled from data this run did not read")
    func keptWithoutData() async throws {
        let world = try await world()
        let stored = item()

        let unscanned = try await world.plan(.scheduled, reviews: [stored])
        #expect(world.lastScan?.status == .unchanged && unscanned.settledReviews.isEmpty, "iCloud was not read")

        // iCloud changed (so it was read), but Google's incremental feed does not mention Ann.
        try await world.editICloud("I2") { $0.nickname = "Bobby" }
        let incremental = try await world.plan(.scheduled, reviews: [stored])
        #expect(world.lastScan?.status == .changed && world.lastFeed?.people["people/c1"] == nil)
        #expect(incremental.settledReviews.isEmpty)

        // The caller read Ann by hand.
        let ann = try await world.google.getPerson(resourceName: "people/c1")
        let given = try await world.plan(.scheduled, reviews: [stored], googleExtra: ["people/c1": ann])
        #expect(given.settledReviews == [stored.id])
    }

    @Test("A note conflict is kept while the note could not be read, other conflicts are not held back by it")
    func noteNotRead() async throws {
        let world = try await world()
        try await world.editICloud("I2") { $0.nickname = "Bobby" }
        let note = item(fields: [.note])
        let phones = item(fields: [.phones])
        let plan = try await world.plan(.scheduled, requireFullListing: true, reviews: [note, phones])
        #expect(world.lastScan?.notes == .notRead)
        #expect(plan.settledReviews == [phones.id])

        let read = try await world.plan(.syncNow, requireFullListing: true, reviews: [note, phones])
        #expect(Set(read.settledReviews) == [note.id, phones.id], "the notes agree")
    }

    @Test("A note that still differs keeps its conflict")
    func noteDiffers() async throws {
        let world = try await world()
        try await world.notes.setNote("only here", forID: "I1")
        let plan = try await world.plan(.syncNow, requireFullListing: true, reviews: [item(fields: [.note])])
        #expect(plan.settledReviews.isEmpty)
    }

    @Test("A pair that is being linked in this run has no baseline to judge against")
    func notBaselined() async throws {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Ann", "Lee", phones: ["415-555-2671"])], google: [SyncFixtures.person("Ann", "Lee", phones: ["415-555-2671"])]
        )
        let plan = try await world.plan(reviews: [item()])
        #expect(plan.links.count == 1 && plan.settledReviews.isEmpty)
    }
}
