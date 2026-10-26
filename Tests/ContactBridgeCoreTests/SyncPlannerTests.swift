import Foundation
import Testing
@testable import ContactBridgeCore

struct SyncPlannerTests {
    private let phone = "415-555-2671"

    /// iCloud and Google both hold Ann Lee (and Bob Stone), already linked and synced.
    private func syncedPair(notes: [String: String] = [:], googleNote: String? = nil) async throws -> SyncWorld {
        let world = SyncWorld(
            icloud: [
                SyncFixtures.icloud("I1", "Ann", "Lee", phones: [phone]),
                SyncFixtures.icloud("I2", "Bob", "Stone", phones: ["415-555-0002"]),
            ],
            google: [
                SyncFixtures.person("Ann", "Lee", phones: [phone], note: googleNote),
                SyncFixtures.person("Bob", "Stone", phones: ["415-555-0002"]),
            ],
            notes: notes
        )
        let first = try await world.settle()
        try #require(first.links.count == 2)
        return world
    }

    private func review(_ plan: SyncPlan, _ kind: ReviewKind) -> [ReviewCandidate] { plan.review.filter { $0.kind == kind } }

    // MARK: linking pass

    @Test("A confident match is linked, with baselines from both sides as they are, and a first sync is a preview")
    func confidentMatch() async throws {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Ann", "Lee", phones: [phone])], google: [SyncFixtures.person("Ann", "Lee", phones: [phone])],
            notes: ["I1": "same"]
        )
        let plan = try await world.plan()
        let link = try #require(plan.links.first)
        #expect(plan.links.count == 1 && plan.isPreview && plan.pause == nil)
        #expect(link.icloudID == "I1" && link.resourceName == "people/c1" && link.origin == .matched && link.isNewLink)
        #expect(link.baseline.icloud == world.lastScan?.records.first)
        #expect(link.baseline.google.sourceIdentifier == "people/c1" && link.baseline.googleEtag == "e1")
        #expect(link.baseline.icloudNoteHash == NoteHash.hash("same"))
        #expect(link.baseline.googleNoteHash == NoteHash.hash(""), "Google has no biographies: a known empty note")
        #expect(plan.creates.isEmpty && plan.updates.isEmpty && plan.deletes.isEmpty)
        // iCloud has a note and Google none, so the pair differs in exactly the note.
        #expect(plan.review.map(\.kind) == [.bothEdited] && plan.review[0].fields == [.note])
        #expect(plan.reviewIsComplete && plan.createsVerifiedAgainstFullListing)
    }

    @Test("Field groups that differ when first linked become one bothEdited candidate; equal ones do not")
    func differingFields() async throws {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Ann", "Lee", phones: [phone], emails: ["ann@example.com"], nickname: "Annie")],
            google: [SyncFixtures.person("Ann", "Lee", phones: ["+1 (415) 555-2671"], emails: ["other@example.com"])]
        )
        let plan = try await world.plan()
        #expect(plan.links.count == 1)
        let candidate = try #require(review(plan, .bothEdited).first)
        #expect(candidate.fields == [.nickname, .emails], "phones agree after normalizing; the note is empty on both sides")
        #expect(candidate.icloudID == "I1" && candidate.resourceName == "people/c1" && candidate.googleEtag == "e1")
        #expect(candidate.icloudFingerprint == ContactFingerprint.of(try #require(world.lastScan?.records.first)))
        #expect(candidate.id == "bothEdited|I1|people/c1")
    }

    @Test("A name-only match becomes a possibleLink and nothing is created or linked for it")
    func nameOnly() async throws {
        let world = SyncWorld(icloud: [SyncFixtures.icloud("I1", "Ann", "Lee")], google: [SyncFixtures.person("Ann", "Lee")])
        let plan = try await world.plan()
        #expect(plan.links.isEmpty && plan.creates.isEmpty)
        #expect(plan.review.map(\.id) == ["possibleLink|I1|people/c1"])
        #expect(review(plan, .newInGoogle).isEmpty)
    }

    @Test("A low-confidence pair is a possibleLink too; keeping it separate lets both sides stand alone")
    func possibleThenKeptSeparate() async throws {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "John", "Smith", emails: ["family@example.com"])],
            google: [SyncFixtures.person("Jane", "Smith", emails: ["family@example.com"])]
        )
        let plan = try await world.plan()
        #expect(plan.review.map(\.kind) == [.possibleLink] && plan.creates.isEmpty && plan.links.isEmpty)

        world.planner = SyncPlanner()
        let scan = try #require(world.lastScan)
        let feed = try #require(world.lastFeed)
        let kept = world.planner.plan(
            icloud: scan, google: feed, state: world.state, links: world.links, keepSeparate: ["I1|people/c1"], now: world.clock
        )
        #expect(kept.creates.map(\.icloudID) == ["I1"])
        #expect(kept.review.map(\.id) == ["newInGoogle||people/c1"])
    }

    @Test("An iCloud contact with no match is created, carrying its note; unclaimed Google contacts are new in Google")
    func noMatch() async throws {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Bob", "Stone", phones: ["415-555-0002"])],
            google: [SyncFixtures.person("Zed", "Quinn", phones: ["415-555-0099"])], notes: ["I1": "remember"]
        )
        let plan = try await world.plan()
        let create = try #require(plan.creates.first)
        #expect(plan.creates.count == 1 && plan.links.isEmpty)
        #expect(create.icloudID == "I1" && create.note == "remember" && create.icloudNoteHash == NoteHash.hash("remember"))
        #expect(plan.review.map(\.id) == ["newInGoogle||people/c1"])
    }

    @Test("A Google contact already tagged with the iCloud id is linked, not created again")
    func tagIndexPreventsDuplicate() async throws {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Bob", "Stone", phones: ["415-555-0002"])],
            google: [SyncFixtures.person("Robert", "Stonehenge", phones: ["415-555-0777"], tag: "I1")]
        )
        let plan = try await world.plan()
        #expect(plan.creates.isEmpty)
        let link = try #require(plan.links.first)
        #expect(plan.links.count == 1 && link.origin == .createdInGoogle && link.isNewLink && link.resourceName == "people/c1")
        #expect(review(plan, .newInGoogle).isEmpty && review(plan, .possibleLink).isEmpty)
        #expect(review(plan, .bothEdited).first?.fields == [.name, .phones], "the tag wins over the matcher; the differences go to review")
    }

    @Test("When the listing is partial, nothing is created from it and the plan says it must list in full")
    func partialListingDefersCreates() async throws {
        let world = try await syncedPair()
        _ = try await world.store.create(SyncFixtures.icloud("x", "Cy", "Moss", phones: ["415-555-0003"]), backup: .forTesting())
        let scan = try await ICloudScanner(store: world.store, notes: world.notes, now: { world.clock }).scan(state: world.state)
        #expect(SyncPlanner.requiresFullGoogleListing(icloud: scan, links: world.links, state: world.state))
        let partial = try await GoogleChangeFeed(client: world.google, fieldsVersion: SyncFixtures.fieldsVersion).fetch(state: world.state)
        #expect(!partial.isFullListing)
        let plan = SyncPlanner().plan(icloud: scan, google: partial, state: world.state, links: world.links, now: world.clock)
        #expect(plan.creates.isEmpty && plan.unlinkedWaitingForFullListing == 1 && !plan.createsVerifiedAgainstFullListing)
        #expect(plan.checkpoint == nil, "the iCloud token must not move past contacts that are still waiting")
        #expect(!plan.reviewIsComplete)

        let full = try await world.plan()
        #expect(full.creates.map(\.record.givenName) == ["Cy"] && full.unlinkedWaitingForFullListing == 0)
    }

    @Test("A link from an earlier import with no baseline is adopted: baseline from both sides, link kept")
    func adoptsPhase1Link() async throws {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Ann", "Lee", phones: [phone])], google: [SyncFixtures.person("Ann", "Lee", phones: [phone])]
        )
        world.links.links["I1"] = LinkEntry(googleResourceName: "people/c1", linkedAt: world.clock)
        let plan = try await world.plan()
        let link = try #require(plan.links.first)
        #expect(plan.links.count == 1 && !link.isNewLink && link.origin == .imported && link.resourceName == "people/c1")
        #expect(plan.creates.isEmpty && plan.review.isEmpty)
    }

    @Test("Ignored Google contacts are neither matched nor offered, even after they are edited")
    func ignoredStaysIgnored() async throws {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Ann", "Lee", phones: [phone])],
            google: [SyncFixtures.person("Ann", "Lee", phones: [phone]), SyncFixtures.person("Zed", "Quinn", phones: ["415-555-0099"])]
        )
        world.state.ignoredGoogle = ["people/c1", "people/c2"]
        let plan = try await world.plan()
        #expect(plan.links.isEmpty && plan.review.isEmpty)
        #expect(plan.creates.map(\.icloudID) == ["I1"])

        world.commit(plan)
        try await world.editGoogle("people/c2", mask: "names") { $0.names = [GoogleName(givenName: "Zedd", familyName: "Quinn")] }
        let later = try await world.plan()
        #expect(world.lastFeed?.mode == .incremental && world.lastFeed?.people.keys.contains("people/c2") == true)
        #expect(later.review.isEmpty)
    }

    @Test("A Google contact that appears later is new in Google; the plan is a preview until sync is approved")
    func newInGoogleIncremental() async throws {
        let world = try await syncedPair()
        let created = try await world.google.createContact(SyncFixtures.person("Cy", "Moss", phones: ["415-555-0003"]))
        let plan = try await world.plan()
        #expect(!plan.isPreview)
        #expect(plan.review.map(\.id) == ["newInGoogle||\(try #require(created.resourceName))"])
        #expect(plan.links.isEmpty && plan.mutationCount == 0 && world.lastScan?.status == .unchanged)
    }

    // MARK: linked contacts

    @Test("An iCloud-only edit is pushed with a mask of just that group, against the baseline etag")
    func icloudEditPushes() async throws {
        let world = try await syncedPair()
        try await world.editICloud("I1") { $0.nickname = "Annie" }
        let plan = try await world.plan()
        let update = try #require(plan.updates.first)
        #expect(plan.updates.count == 1 && plan.review.isEmpty && plan.deletes.isEmpty && plan.creates.isEmpty)
        #expect(update.icloudID == "I1" && update.resourceName == "people/c1" && update.fields == [.nickname])
        #expect(update.desired.nickname == "Annie" && update.existing == nil && update.note == nil)
        #expect(update.etag == world.state.baselines["I1"]?.googleEtag)
        #expect(update.baseline.icloud.nickname == "Annie")
        #expect(world.lastScan?.changedIDs == ["I1"])
    }

    @Test("A Google-only edit is a googleEdited review and writes nothing")
    func googleEditReviews() async throws {
        let world = try await syncedPair()
        try await world.editGoogle("people/c1", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Annie")] }
        let plan = try await world.plan()
        let item = try #require(plan.review.first)
        #expect(plan.review.count == 1 && plan.mutationCount == 0)
        #expect(item.kind == .googleEdited && item.fields == [.nickname] && item.icloudID == "I1")
        #expect(item.googleEtag == world.lastFeed?.people["people/c1"]?.etag)
        #expect(world.lastScan?.status == .unchanged)
    }

    @Test("The same group edited differently on both sides is a bothEdited review; other iCloud edits still push")
    func bothEdited() async throws {
        let world = try await syncedPair()
        try await world.editICloud("I1") {
            $0.nickname = "Ann-i"
            $0.emails = [Labeled(label: "home", value: "ann@example.com")]
        }
        try await world.editGoogle("people/c1", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Ann-g")] }
        let plan = try await world.plan()
        let item = try #require(plan.review.first)
        #expect(plan.review.count == 1 && item.kind == .bothEdited && item.fields == [.nickname])
        #expect(plan.updates.map(\.fields) == [[.emails]])
    }

    @Test("A churned etag with an identical projection is neither an edit nor a review; only the baseline etag moves")
    func etagChurn() async throws {
        let world = try await syncedPair()
        try await world.editGoogle("people/c1", mask: "names") { _ in }
        let plan = try await world.plan()
        let refreshed = try #require(plan.baselineRefreshes["I1"])
        #expect(plan.review.isEmpty && plan.mutationCount == 0 && plan.baselineRefreshes.count == 1)
        #expect(refreshed.googleEtag == world.lastFeed?.people["people/c1"]?.etag)
        #expect(refreshed.googleEtag != world.state.baselines["I1"]?.googleEtag)
    }

    @Test("A note edit in iCloud is pushed with the note text when the notes were read; clearing it pushes a known empty note")
    func noteEdits() async throws {
        let world = try await syncedPair(notes: ["I1": "Hello"], googleNote: "Hello")
        world.contactsRunning = true
        try await world.notes.setNote("Hello world", forID: "I1")
        try await world.editICloud("I1") { _ in }
        let edited = try await world.plan()
        #expect(edited.updates.map(\.fields) == [[.note]] && edited.updates.first?.note == "Hello world")
        #expect(world.lastScan?.notesReason == .contactsRunning)

        try await world.notes.setNote(nil, forID: "I1")
        try await world.editICloud("I1") { _ in }
        let cleared = try await world.plan()
        #expect(cleared.updates.first?.fields == [.note] && cleared.updates.first?.note == "")
    }

    @Test("When the notes cannot be read the run carries no note changes, whatever happened to them")
    func unreadableNotesNeverPush() async throws {
        let world = try await syncedPair(notes: ["I1": "Hello"], googleNote: "Hello")
        try await world.notes.setNote(nil, forID: "I1")
        world.notes.setReadError(NotesAccessError.notAuthorized)
        try await world.editICloud("I1") { $0.nickname = "Annie" }
        let plan = try await world.plan(.syncNow)
        #expect(plan.notesUnavailable && plan.notesReason == .syncNow)
        #expect(plan.updates.map(\.fields) == [[.nickname]], "other fields still sync; the note is left alone")
        #expect(plan.updates.first?.note == nil)
    }

    @Test("A note edited only in Google is a googleEdited review of the note")
    func googleNoteEdit() async throws {
        let world = try await syncedPair(notes: ["I1": "Hello"], googleNote: "Hello")
        try await world.editGoogle("people/c1", mask: "biographies") {
            $0.extras["biographies"] = .array([.object(["value": .string("Changed in Google")])])
        }
        let plan = try await world.plan()
        #expect(plan.review.map(\.kind) == [.googleEdited] && plan.review.first?.fields == [.note])
        #expect(plan.mutationCount == 0)
    }

    // MARK: deletions

    @Test("A contact deleted in iCloud and untouched in Google is deleted from Google")
    func icloudDeleteDeletesGoogle() async throws {
        let world = try await syncedPair()
        try await world.store.delete(ids: ["I2"], backup: .forTesting())
        let plan = try await world.plan()
        let delete = try #require(plan.deletes.first)
        #expect(plan.deletes.count == 1 && delete.icloudID == "I2" && delete.resourceName == "people/c2")
        #expect(plan.review.isEmpty && plan.pause == nil)
        #expect(delete.baseline == world.state.baselines["I2"])
    }

    @Test("Deleted in iCloud but edited in Google is a review, never a delete")
    func icloudDeleteGoogleEdited() async throws {
        let world = try await syncedPair()
        try await world.editGoogle("people/c2", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Bobby")] }
        try await world.store.delete(ids: ["I2"], backup: .forTesting())
        let plan = try await world.plan()
        #expect(plan.deletes.isEmpty)
        #expect(plan.review.map(\.id) == ["deletedInICloudEditedInGoogle|I2|people/c2"])
    }

    @Test("A deletion marker for a linked contact becomes a deletedInGoogle review; the iCloud contact is not touched")
    func googleDeleteMarker() async throws {
        let world = try await syncedPair()
        try await world.google.deleteContact(resourceName: "people/c2")
        let plan = try await world.plan()
        #expect(world.lastFeed?.deleted == ["people/c2"] && world.lastFeed?.isFullListing == false)
        #expect(plan.review.map(\.id) == ["deletedInGoogle|I2|people/c2"])
        #expect(plan.mutationCount == 0 && plan.droppedLinks.isEmpty && plan.review.first?.icloudFingerprint != nil)
    }

    @Test("After a full listing a linked contact that is missing counts as deleted in Google")
    func googleDeleteByAbsence() async throws {
        let world = try await syncedPair()
        try await world.google.deleteContact(resourceName: "people/c2")
        await world.google.expireSyncTokens()
        let quiet = try await world.plan()
        #expect(world.lastFeed?.mode == .full(.tokenExpired))
        #expect(quiet.review.map(\.id) == ["deletedInGoogle|I2|people/c2"])
        #expect(!quiet.reviewIsComplete, "iCloud was not looked at, so unlinked contacts are unknown")

        try await world.editICloud("I1") { _ in }
        let plan = try await world.plan()
        #expect(plan.review.map(\.id) == ["deletedInGoogle|I2|people/c2"] && plan.reviewIsComplete)
    }

    @Test("Gone from both sides: the link and baseline are dropped, nothing is written")
    func goneEverywhere() async throws {
        let world = try await syncedPair()
        try await world.google.deleteContact(resourceName: "people/c2")
        try await world.store.delete(ids: ["I2"], backup: .forTesting())
        let plan = try await world.plan()
        #expect(plan.droppedLinks == ["I2"] && plan.mutationCount == 0 && plan.review.isEmpty)
    }

    // MARK: orphaned links (a Dedupe merge deleted the linked iCloud contact)

    /// "GONE" was linked to Google's Ann Lee by an earlier import and has since been merged away in iCloud.
    private func orphanWorld(icloud: [ContactRecord], google: [GooglePerson]) -> SyncWorld {
        let world = SyncWorld(icloud: icloud, google: google)
        world.links.links["GONE"] = LinkEntry(googleResourceName: "people/c1", linkedAt: world.clock, origin: .imported, displayName: "Ann Lee")
        return world
    }

    @Test("An orphaned import link releases its Google contact so the surviving iCloud contact is matched to it, not duplicated")
    func orphanReleasedAndRematched() async throws {
        let world = orphanWorld(
            icloud: [SyncFixtures.icloud("S", "Ann", "Lee", emails: ["ann@example.com"])],
            google: [SyncFixtures.person("Ann", "Lee", emails: ["ann@example.com"])]
        )
        let plan = try await world.plan()
        let link = try #require(plan.links.first)
        #expect(plan.droppedLinks == ["GONE"] && plan.droppedLinkInfo["GONE"]?.isReleased == true)
        #expect(plan.links.count == 1 && link.icloudID == "S" && link.resourceName == "people/c1" && link.origin == .matched && link.isNewLink)
        #expect(plan.creates.isEmpty, "no second copy of Ann in Google")
        #expect(review(plan, .newInGoogle).isEmpty && review(plan, .possibleLink).isEmpty)
        #expect(plan.forgottenLinkInfo.isEmpty)

        // The executor's local step ends with one owner for the Google contact.
        world.commit(plan)
        #expect(world.links.links.keys.sorted() == ["S"] && world.state.baselines.keys.sorted() == ["S"])
    }

    @Test("An orphaned link whose Google contact matches nothing leaves the survivor to be created, as before")
    func orphanWithoutMatch() async throws {
        let world = orphanWorld(
            icloud: [SyncFixtures.icloud("S", "Bob", "Stone", phones: ["415-555-0002"])],
            google: [SyncFixtures.person("Ann", "Lee", emails: ["ann@example.com"])]
        )
        let plan = try await world.plan()
        #expect(plan.droppedLinks == ["GONE"] && plan.links.isEmpty && plan.creates.map(\.icloudID) == ["S"])
        #expect(plan.mutationCount == 1 && plan.deletes.isEmpty, "Google's copy of the vanished contact is never deleted")
        // The released contact is no longer hidden from the new-in-Google list, which a later full listing would show anyway.
        #expect(plan.review.map(\.id) == ["newInGoogle||people/c1"])
    }

    @Test("An orphaned link whose Google contact only matches the survivor by name becomes a possibleLink, never an automatic link")
    func orphanNameOnlyIsPossibleLink() async throws {
        let world = orphanWorld(icloud: [SyncFixtures.icloud("S", "Ann", "Lee")], google: [SyncFixtures.person("Ann", "Lee")])
        let plan = try await world.plan()
        #expect(plan.links.isEmpty && plan.creates.isEmpty)
        #expect(plan.review.map(\.id) == ["possibleLink|S|people/c1"])
        #expect(plan.droppedLinks == ["GONE"])
    }

    @Test("A link whose Google contact is gone too is not released, whatever the survivor looks like")
    func orphanGoneEverywhereIsNotReleased() async throws {
        let world = orphanWorld(
            icloud: [SyncFixtures.icloud("S", "Ann", "Lee", emails: ["ann@example.com"])],
            google: [SyncFixtures.person("Zed", "Quinn", phones: ["415-555-0099"])]
        )
        world.links.links["GONE"] = LinkEntry(googleResourceName: "people/c9", linkedAt: world.clock)
        let plan = try await world.plan()
        #expect(plan.droppedLinkInfo["GONE"]?.isReleased == false && plan.droppedLinkInfo["GONE"]?.reason == .goneFromBothSides)
        #expect(plan.forgottenLinkInfo.count == 1 && plan.links.isEmpty)
    }

    // MARK: pauses

    @Test("Nothing changed anywhere: an empty plan that still advances the checkpoint")
    func quiet() async throws {
        let world = try await syncedPair()
        let plan = try await world.plan()
        #expect(plan.isEmpty && plan.pause == nil && !plan.isPreview)
        #expect(plan.checkpoint != nil && world.lastScan?.status == .unchanged && world.lastFeed?.mode == .incremental)
    }

    @Test("A container change, an emptied container and an account change each pause with an empty plan")
    func pauses() async throws {
        let world = try await syncedPair()
        world.store.setContainerID("another")
        let container = try await world.plan()
        #expect(container.pause == .containerChanged && container.isEmpty && container.checkpoint == nil)

        world.store.setContainerID("mem-container")
        try await world.store.delete(ids: ["I1", "I2"], backup: .forTesting())
        let emptied = try await world.plan()
        #expect(emptied.pause == .containerChanged && emptied.deletes.isEmpty && emptied.review.isEmpty)

        let other = try await syncedPair()
        other.account = "someone@else.com"
        let account = try await other.plan()
        #expect(account.pause == .accountChanged && account.isEmpty)
    }

    @Test("A full Google listing that comes back empty while contacts are linked pauses: no reviews, no writes")
    func emptyGoogleListing() async throws {
        let world = try await syncedPair()
        try await world.google.deleteContact(resourceName: "people/c1")
        try await world.google.deleteContact(resourceName: "people/c2")
        try await world.editICloud("I1") { $0.nickname = "Annie" }
        let plan = try await world.plan(requireFullListing: true)
        #expect(world.lastFeed?.isFullListing == true && world.lastFeed?.people.isEmpty == true)
        #expect(plan.pause == .googleEmpty)
        #expect(plan.isEmpty && plan.checkpoint == nil)

        // An unlinked setup is not affected: an empty Google account is normal before the first sync.
        let fresh = SyncWorld(icloud: [SyncFixtures.icloud("I1", "Ann", "Lee", phones: [phone])])
        let first = try await fresh.plan()
        #expect(first.pause == nil && first.creates.count == 1)
    }

    @Test("A full listing missing more than max(5, 2% of linked) linked contacts pauses for confirmation instead of flooding reviews")
    func massMissingGoogle() async throws {
        let world = try await SyncWorld.linked(count: 400)  // 2% of 400 = 8
        for n in 1...8 { try await world.google.deleteContact(resourceName: "people/c\(n)") }
        let atLimit = try await world.plan(requireFullListing: true)
        #expect(atLimit.pause == nil && atLimit.review.filter { $0.kind == .deletedInGoogle }.count == 8)

        try await world.google.deleteContact(resourceName: "people/c9")
        let over = try await world.plan(requireFullListing: true)
        guard case .needsConfirmation(let summary)? = over.pause else {
            Issue.record("expected confirmation, got \(String(describing: over.pause))")
            return
        }
        #expect(summary.contains("9 of 400"))
        #expect(over.isEmpty && over.checkpoint == nil, "nothing is derived from a listing that may be incomplete")

        // Incremental deletion markers are real deletions and are not held back by this check.
        let marker = try await world.plan()
        #expect(marker.pause == nil && marker.review.filter { $0.kind == .deletedInGoogle }.count == 9)

        let scan = try #require(world.lastScan)
        let feed = try await GoogleChangeFeed(client: world.google, fieldsVersion: SyncFixtures.fieldsVersion)
            .fetch(state: world.state, requireFullListing: true)
        let confirmed = SyncPlanner().plan(
            icloud: scan, google: feed, state: world.state, links: world.links, allowMassGoogleDeletions: true, now: world.clock
        )
        #expect(confirmed.pause == nil && confirmed.review.filter { $0.kind == .deletedInGoogle }.count == 9)
    }

    @Test("A new contact gets its note read even when the notes would otherwise be skipped, so the baseline has note hashes")
    func newContactReadsNotes() async throws {
        let world = try await syncedPair()
        _ = try await world.store.create(SyncFixtures.icloud("x", "Cy", "Moss", phones: ["415-555-0003"]), backup: .forTesting())
        try await world.notes.setNote("mine", forID: "mem-1")
        let plan = try await world.plan()
        #expect(world.lastScan?.notesReason == .newContacts && world.lastScan?.notes == .read)
        let create = try #require(plan.creates.first)
        #expect(plan.creates.count == 1 && create.note == "mine" && create.icloudNoteHash == NoteHash.hash("mine"))
        #expect(plan.waitingForNotes == 0 && plan.checkpoint != nil)
    }

    @Test("A new contact matched to an existing Google one is linked with both note hashes")
    func newMatchedContactHasHashes() async throws {
        let world = try await syncedPair()
        _ = try await world.google.createContact(SyncFixtures.person("Cy", "Moss", phones: ["415-555-0003"]))
        _ = try await world.store.create(SyncFixtures.icloud("x", "Cy", "Moss", phones: ["415-555-0003"]), backup: .forTesting())
        let plan = try await world.plan()
        let link = try #require(plan.links.first)
        #expect(plan.links.count == 1 && link.baseline.icloudNoteHash == NoteHash.hash("") && link.baseline.googleNoteHash == NoteHash.hash(""))
    }

    @Test("When the notes of a new contact cannot be read it is neither created nor linked, and the checkpoint waits")
    func unreadableNotesHoldNewContacts() async throws {
        let world = try await syncedPair()
        world.notes.setReadError(NotesAccessError.notAuthorized)
        _ = try await world.google.createContact(SyncFixtures.person("Di", "Park", phones: ["415-555-0004"]))
        _ = try await world.store.create(SyncFixtures.icloud("x", "Cy", "Moss", phones: ["415-555-0003"]), backup: .forTesting())
        _ = try await world.store.create(SyncFixtures.icloud("y", "Di", "Park", phones: ["415-555-0004"]), backup: .forTesting())
        let held = try await world.plan()
        #expect(held.notesUnavailable && held.waitingForNotes == 2)
        #expect(held.creates.isEmpty && held.links.isEmpty && held.checkpoint == nil)
        #expect(held.review.isEmpty, "the matched Google contact is not offered as new either")

        world.notes.setReadError(nil)
        let later = try await world.plan()
        #expect(later.waitingForNotes == 0 && later.creates.map(\.record.givenName) == ["Cy"] && later.links.map(\.baseline.icloudNoteHash) == [NoteHash.hash("")])
    }

    @Test("A link from an earlier import is also held while its notes are unreadable")
    func unreadableNotesHoldAdoption() async throws {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Ann", "Lee", phones: [phone])], google: [SyncFixtures.person("Ann", "Lee", phones: [phone])]
        )
        world.links.links["I1"] = LinkEntry(googleResourceName: "people/c1", linkedAt: world.clock)
        world.notes.setReadError(NotesAccessError.notAuthorized)
        let plan = try await world.plan()
        #expect(plan.links.isEmpty && plan.waitingForNotes == 1 && plan.checkpoint == nil)
    }

    @Test("An empty fetch pauses when only links exist (no baselines), in the scanner and in the planner")
    func emptyFetchWithOnlyLinks() async throws {
        let world = SyncWorld(icloud: [], google: [SyncFixtures.person("Ann", "Lee", phones: [phone])])
        world.links.links["I1"] = LinkEntry(googleResourceName: "people/c1", linkedAt: world.clock)
        let plan = try await world.plan()
        #expect(world.lastScan?.status == .paused(.containerChanged))
        #expect(plan.pause == .containerChanged && plan.droppedLinks.isEmpty)

        // A scan from a caller that did not pass the links is caught by the planner too.
        let scan = try await ICloudScanner(store: world.store, notes: world.notes).scan(state: world.state)
        let feed = try #require(world.lastFeed)
        #expect(scan.status == .changed && scan.records.isEmpty)
        let guarded = SyncPlanner().plan(icloud: scan, google: feed, state: world.state, links: world.links, now: world.clock)
        #expect(guarded.pause == .containerChanged && guarded.droppedLinks.isEmpty && guarded.isEmpty)
    }

    @Test("Forgetting more than max(5, 2% of linked) links to contacts gone from both sides needs confirmation")
    func droppedLinksGuard() async throws {
        let world = try await SyncWorld.linked(count: 400)  // 2% of 400 = 8
        func goneEverywhere(_ range: ClosedRange<Int>) async throws {
            for n in range {
                try await world.google.deleteContact(resourceName: "people/c\(n)")
                try await world.store.delete(ids: ["I\(n)"], backup: .forTesting())
            }
        }
        try await goneEverywhere(1...8)
        let atLimit = try await world.plan()
        #expect(atLimit.droppedLinks.count == 8 && atLimit.pause == nil)

        try await goneEverywhere(9...9)
        let over = try await world.plan()
        guard case .needsConfirmation(let summary)? = over.pause else {
            Issue.record("expected confirmation")
            return
        }
        #expect(over.droppedLinks.count == 9 && summary.contains("forget 9 of 400"))
        #expect(summary.contains("links to contacts gone from both sides"))
        #expect(over.guardedForgottenLinks.count == 9 && over.guardedForgottenLinks.allSatisfy { $0.reason == .goneFromBothSides })
        #expect(over.guardedForgottenLinks.map(\.name).first == "First1 Last1", "named from the baseline, sorted by name")
        #expect(!summary.contains("First1"), "the summary is saved and compared as text: it stays name-free")
    }

    @Test("Dropped links are named from the baseline, else the Google contact, else the name stored with the link, else the resource name")
    func droppedLinkNames() async throws {
        // Baselined, gone from both sides: the baseline's iCloud name wins over a different name stored on the link.
        let world = try await SyncWorld.linked(count: 3)
        world.links.links["I1"]?.displayName = "Stale Name"
        try await world.google.deleteContact(resourceName: "people/c1")
        try await world.store.delete(ids: ["I1"], backup: .forTesting())
        // Unbaselined links: Google's contact survives (named from the feed), or is gone (named from the link, or not at all).
        _ = try await world.google.createContact(SyncFixtures.person("Dora", "Feed"))
        world.links.links["O1"] = LinkEntry(googleResourceName: "people/c4", linkedAt: world.clock, displayName: "Old Dora")
        world.links.links["O2"] = LinkEntry(googleResourceName: "people/c77", linkedAt: world.clock, displayName: "Kept On Link")
        world.links.links["O3"] = LinkEntry(googleResourceName: "people/c88", linkedAt: world.clock)
        let plan = try await world.plan()

        #expect(plan.droppedLinks == ["I1", "O1", "O2", "O3"])
        let info = plan.droppedLinkInfo
        #expect(info["I1"]?.name == "First1 Last1" && info["I1"]?.reason == .goneFromBothSides && info["I1"]?.isReleased == false)
        #expect(info["O1"]?.name == "Dora Feed" && info["O1"]?.isReleased == true && info["O1"]?.resourceName == "people/c4")
        #expect(info["O2"]?.name == "Kept On Link" && info["O2"]?.reason == .goneFromBothSides && info["O2"]?.isReleased == false)
        #expect(info["O3"]?.name == "people/c88")
        #expect(plan.forgottenLinkInfo.map(\.icloudID) == ["I1", "O2", "O3"].sorted { (info[$0]!.name, $0) < (info[$1]!.name, $1) })
    }

    @Test("Released links do not count towards the forget-links guard; a pause for a link that was deleted in iCloud says so")
    func releasedLinksAreNotGuarded() async throws {
        let world = SyncWorld(icloud: [SyncFixtures.icloud("S", "Zed", "Quinn", phones: ["415-555-0099"])], google: [])
        for n in 1...7 {
            _ = try await world.google.createContact(SyncFixtures.person("Gone\(n)", "Person", phones: ["415-555-01\(String(format: "%02d", n))"]))
            world.links.links["GONE\(n)"] = LinkEntry(googleResourceName: "people/c\(n)", linkedAt: world.clock)
        }
        let released = try await world.plan()
        #expect(released.droppedLinks.count == 7 && released.forgottenLinkInfo.isEmpty && released.pause == nil)

        // Seen through an incremental feed that did not list them, the same links are forgotten, and the pause says why.
        let scan = try #require(world.lastScan)
        var feed = try #require(world.lastFeed)
        feed.mode = .incremental
        feed.people = [:]
        let partial = SyncPlanner().plan(icloud: scan, google: feed, state: world.state, links: world.links, now: world.clock)
        guard case .needsConfirmation(let summary)? = partial.pause else {
            Issue.record("expected confirmation, got \(String(describing: partial.pause))")
            return
        }
        #expect(summary.contains("forget 7 of 7 links to contacts deleted in iCloud"))
        #expect(partial.guardedForgottenLinks.allSatisfy { $0.reason == .iCloudGone && !$0.isReleased })
    }

    @Test("A paused feed or scan never yields deletions even with deletion-looking data")
    func pauseBeatsDeletes() async throws {
        let world = try await syncedPair()
        try await world.store.delete(ids: ["I2"], backup: .forTesting())
        world.account = "someone@else.com"
        let plan = try await world.plan()
        #expect(plan.pause == .accountChanged && plan.deletes.isEmpty)
    }

    // MARK: guards and cap

    @Test("More than max(5, 2% of linked) Google deletes need confirmation; exactly the limit does not")
    func deleteGuard() async throws {
        let world = try await SyncWorld.linked(count: 400)  // 2% of 400 = 8
        try await world.store.delete(ids: (1...8).map { "I\($0)" }, backup: .forTesting())
        let atLimit = try await world.plan()
        #expect(atLimit.deletes.count == 8 && atLimit.pause == nil && !atLimit.needsConfirmation)

        try await world.store.delete(ids: ["I9"], backup: .forTesting())
        let over = try await world.plan()
        #expect(over.deletes.count == 9 && over.needsConfirmation)
        guard case .needsConfirmation(let summary)? = over.pause else {
            Issue.record("expected confirmation")
            return
        }
        #expect(summary.contains("delete 9 of 400"))
        #expect(over.checkpoint != nil, "the plan still lists everything it would do")
    }

    @Test("A small book still allows five deletes")
    func deleteFloor() async throws {
        let world = try await SyncWorld.linked(count: 30)
        try await world.store.delete(ids: (1...5).map { "I\($0)" }, backup: .forTesting())
        #expect(try await world.plan().pause == nil)
        try await world.store.delete(ids: ["I6"], backup: .forTesting())
        #expect(try await world.plan().needsConfirmation)
    }

    @Test("More than max(50, 25% of linked) updates need confirmation")
    func updateGuard() async throws {
        let world = try await SyncWorld.linked(count: 100)
        for n in 1...50 { try await world.editICloud("I\(n)") { $0.nickname = "Nick" } }
        let atLimit = try await world.plan()
        #expect(atLimit.updates.count == 50 && atLimit.pause == nil)

        try await world.editICloud("I51") { $0.nickname = "Nick" }
        let over = try await world.plan()
        #expect(over.updates.count == 51 && over.needsConfirmation)
        guard case .needsConfirmation(let summary)? = over.pause else {
            Issue.record("expected confirmation")
            return
        }
        #expect(summary.contains("update 51 of 100"))
    }

    @Test("The default cap is 1,000 Google writes")
    func defaultCap() {
        #expect(SyncPlanner.Limits().maxMutations == 1000)
    }

    @Test("Writes beyond the cap are deferred (updates, then deletes, then creates), the guard sees the whole plan, and the checkpoint waits")
    func cap() async throws {
        let world = try await SyncWorld.linked(count: 100)
        world.planner.limits.maxMutations = 10
        for n in 1...60 { try await world.editICloud("I\(n)") { $0.nickname = "Nick" } }
        let plan = try await world.plan()
        #expect(plan.updates.count == 10 && plan.deferred.updates == 50 && plan.deferred.deletes == 0)
        #expect(plan.updates.map(\.icloudID) == Array((1...60).map { "I\($0)" }.sorted().prefix(10)), "lowest identifiers first")
        #expect(plan.needsConfirmation, "60 updates is judged before the cap")
        #expect(plan.checkpoint == nil)

        let fresh = SyncWorld(icloud: (1...25).map { SyncFixtures.icloud("N\($0)", "Name\($0)", "Fam\($0)", phones: ["415-555-01\(String(format: "%02d", $0))"]) })
        fresh.planner.limits.maxMutations = 10
        let creates = try await fresh.plan()
        #expect(creates.creates.count == 10 && creates.deferred.creates == 15 && creates.mutationCount == 10)
        #expect(creates.checkpoint == nil && !creates.deferred.isEmpty)
        #expect(creates.creates.map(\.icloudID) == creates.creates.map(\.icloudID).sorted())
    }

    // MARK: determinism

    @Test("The same inputs give the same plan, whatever order the records arrive in")
    func deterministic() async throws {
        let world = SyncWorld(
            icloud: [
                SyncFixtures.icloud("I1", "Ann", "Lee", phones: [phone]), SyncFixtures.icloud("I2", "Bob", "Stone", phones: ["415-555-0002"]),
                SyncFixtures.icloud("I3", "Cy", "Moss", phones: ["415-555-0003"]), SyncFixtures.icloud("I4", "Di", "Park", phones: ["415-555-0004"]),
                SyncFixtures.icloud("I5", "John", "Smith", emails: ["family@example.com"]),
            ],
            google: [
                SyncFixtures.person("Ann", "Lee", phones: [phone], emails: ["a@example.com"]), SyncFixtures.person("Zed", "Quinn", phones: ["415-555-0099"]),
                SyncFixtures.person("Jane", "Smith", emails: ["family@example.com"]), SyncFixtures.person("Bob", "Stone", phones: ["415-555-0002"]),
            ]
        )
        let plan = try await world.plan()
        #expect(plan.links.count == 2 && plan.creates.count == 2 && plan.review.count >= 3)
        let scan = try #require(world.lastScan)
        let feed = try #require(world.lastFeed)
        var shuffled = scan
        shuffled.records.reverse()
        #expect(SyncPlanner().plan(icloud: shuffled, google: feed, state: world.state, links: world.links, now: world.clock) == plan)
        #expect(SyncPlanner().plan(icloud: scan, google: feed, state: world.state, links: world.links, now: world.clock) == plan)
        #expect(plan.review.map(\.id) == plan.review.map(\.id).sorted())
    }
}
