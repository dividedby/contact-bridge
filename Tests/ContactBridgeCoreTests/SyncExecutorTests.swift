import Foundation
import Testing
@testable import ContactBridgeCore

struct SyncExecutorTests {
    // MARK: happy path

    @Test("Updates, creates and deletes run in one pass; baselines come from the people Google returned; the next plan is empty")
    func happyPath() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.setPhone("I1", "415-555-9999")
        try await rig.world.store.delete(ids: ["I2"], backup: .forTesting())
        let carol = try await rig.addICloudContact("Carol", "Newman", phone: "415-555-0100", note: "remember")
        let before = try rig.state

        let plan = try await rig.plan()
        #expect(plan.updates.count == 1 && plan.deletes.count == 1 && plan.creates.count == 1 && plan.pause == nil)
        let report = try await rig.run(plan)

        #expect(report.updated == 1 && report.created == 1 && report.deleted == 1 && report.isComplete && report.checkpointCommitted)
        #expect(report.backup != nil && report.warnings.isEmpty)

        let ann = try await rig.googlePerson("people/c1")
        #expect(ann.phoneNumbers?.map(\.value) == ["415-555-9999"])
        let state = try rig.state
        let annBaseline = try #require(state.baselines["I1"])
        #expect(annBaseline.googleEtag == ann.etag && annBaseline.google == GooglePersonMapper.record(from: ann))
        #expect(annBaseline.icloud.phones.map(\.value) == ["415-555-9999"] && annBaseline.googleEtag != before.baselines["I1"]?.googleEtag)

        let created = try #require(await rig.taggedPeople(carol.sourceIdentifier).first)
        #expect(GooglePersonMapper.note(of: created) == "remember" && created.names?.first?.givenName == "Carol")
        let link = try #require(try rig.links[carol.sourceIdentifier])
        #expect(link.googleResourceName == created.resourceName && link.origin == .createdInGoogle)
        let baseline = try #require(state.baselines[carol.sourceIdentifier])
        #expect(baseline.googleEtag == created.etag && baseline.google == GooglePersonMapper.record(from: created))
        #expect(baseline.icloudNoteHash == NoteHash.hash("remember") && baseline.googleNoteHash == NoteHash.hash("remember"))
        #expect(baseline.icloud == plan.creates.first?.record)

        #expect(try rig.links["I2"] == nil && state.baselines["I2"] == nil)
        #expect((try? await rig.googlePerson("people/c2")) == nil, "deleted in Google")
        #expect(try rig.journal.load().entries.isEmpty)

        let again = try await rig.plan()
        #expect(again.isEmpty && again.mutationCount == 0 && again.review.isEmpty, "our own echoes are not changes: \(again)")
    }

    @Test("The first sync links what matches (origin matched) and creates the rest, only after the preview is approved")
    func firstSync() async throws {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Ann", "Lee", phones: ["415-555-2671"]), SyncFixtures.icloud("I2", "Bob", "Stone", phones: ["415-555-0002"])],
            google: [SyncFixtures.person("Ann", "Lee", phones: ["415-555-2671"])]
        )
        let rig = try ExecutorRig(world)
        defer { rig.cleanUp() }
        let preview = try await rig.plan()
        #expect(preview.isPreview)
        await #expect(throws: SyncExecutorError.previewPlan) { try await rig.run(preview) }
        let peopleBefore = await world.google.allPeople.count
        #expect(try rig.links.isEmpty && rig.backupFolders() == 0 && peopleBefore == 1)

        try rig.stateStore.update { $0.firstSyncApproved = true }
        let report = try await rig.sync()
        #expect(report.linksAdded == 1 && report.created == 1 && report.isComplete)
        #expect(try rig.links["I1"]?.origin == .matched && rig.links["I2"]?.origin == .createdInGoogle)
        #expect(try rig.state.baselines.keys.sorted() == ["I1", "I2"])
        #expect(await rig.taggedPeople("I2").count == 1)
        #expect(try await rig.plan().isEmpty)
    }

    @Test("A new link and dropped links in one plan: the Google contact moves to the survivor, nothing is left behind or duplicated")
    func newLinkAndDroppedLinksTogether() async throws {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("S", "Ann", "Lee", emails: ["ann@example.com"])],
            google: [SyncFixtures.person("Ann", "Lee", emails: ["ann@example.com"])]
        )
        world.state.firstSyncApproved = true
        // Two vanished iCloud contacts: one pointed at the Google contact the survivor now matches, one at a contact Google lost.
        world.links.links["GONE1"] = LinkEntry(googleResourceName: "people/c1", linkedAt: world.clock, displayName: "Ann Lee")
        world.links.links["GONE2"] = LinkEntry(googleResourceName: "people/c99", linkedAt: world.clock, displayName: "Zed Quinn")
        let rig = try ExecutorRig(world)
        defer { rig.cleanUp() }

        let plan = try await rig.plan()
        try #require(plan.links.map(\.icloudID) == ["S"] && plan.links.first?.isNewLink == true)
        try #require(plan.droppedLinks == ["GONE1", "GONE2"])
        let report = try await rig.run(plan)

        #expect(report.linksAdded == 1 && report.linksDropped == 2 && report.isComplete)
        #expect(try rig.links.keys.sorted() == ["S"] && rig.links["S"]?.googleResourceName == "people/c1" && rig.links["S"]?.origin == .matched)
        #expect(try rig.links["S"]?.displayName == "Ann Lee")
        #expect(try rig.state.baselines.keys.sorted() == ["S"])
        #expect(await world.google.allPeople.count == 1, "Google's contact was neither deleted nor copied")
        #expect(try await rig.plan().isEmpty)
    }

    @Test("A plan that is paused, or made before approval, is refused and nothing is touched")
    func refusals() async throws {
        let rig = try await ExecutorRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setPhone("I1", "415-555-9999")
        var plan = try await rig.plan()
        plan.pause = .user
        await #expect(throws: SyncExecutorError.paused(.user)) { try await rig.run(plan) }
        plan.pause = .needsConfirmation(summary: "too many")
        await #expect(throws: SyncExecutorError.paused(.needsConfirmation(summary: "too many"))) { try await rig.run(plan) }

        var preview = try await rig.plan()
        preview.isPreview = true
        await #expect(throws: SyncExecutorError.previewPlan) { try await rig.run(preview) }

        try rig.stateStore.update { $0.firstSyncApproved = false }
        await #expect(throws: SyncExecutorError.previewPlan) { try await rig.run(try await rig.plan()) }
        let firstPhone = await rig.world.google.allPeople.first?.phoneNumbers?.first?.value
        #expect(firstPhone != "415-555-9999" && rig.backupFolders() == 0)
    }

    // MARK: failures

    @Test("A batch where one item fails: the others are applied and baselined, the failure is reported and left for the next run")
    func partialBatchFailure() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        for id in ["I1", "I2", "I3"] { try await rig.setPhone(id, "415-555-77\(id.last!)0") }
        let before = try rig.state
        await rig.world.google.inject(.partialBatch(indices: [1], error: .other(status: 400, message: "bad phone")), on: .batchUpdate)

        let report = try await rig.sync()
        #expect(report.updated == 2 && !report.isComplete && report.halted == nil && !report.checkpointCommitted)
        let skipped = try #require(report.leftForNextRun.first)
        #expect(report.leftForNextRun.count == 1 && skipped.icloudID == "I2")
        guard case .failed = skipped.reason else { Issue.record("expected a failure, got \(skipped.reason)"); return }

        let state = try rig.state
        #expect(state.baselines["I2"] == before.baselines["I2"], "an unconfirmed contact keeps its old baseline")
        #expect(state.baselines["I1"] != before.baselines["I1"] && state.baselines["I3"] != before.baselines["I3"])
        #expect(state.googleSyncToken == before.googleSyncToken && state.icloudChangeToken == before.icloudChangeToken, "no checkpoint")
        #expect(try rig.journal.load().entries.isEmpty)

        let retry = try await rig.sync()
        #expect(retry.updated == 1 && retry.isComplete && retry.checkpointCommitted)
        #expect(try await rig.plan().isEmpty)
    }

    @Test("A rate limit stops the run: later phases are not attempted and no checkpoint is stored")
    func rateLimitHalts() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.setPhone("I1", "415-555-9999")
        try await rig.addICloudContact("Carol", "Newman", phone: "415-555-0100")
        await rig.world.google.inject(.rateLimited(retryAfter: 30), on: .batchUpdate)
        let report = try await rig.sync()
        #expect(report.halted != nil && report.updated == 0 && report.created == 0 && !report.checkpointCommitted)
        #expect(await rig.world.google.allPeople.count == 6)
        #expect(try rig.journal.load().entries.isEmpty)
    }

    @Test("An etag that moved since the plan is re-diffed: the iCloud edit still goes, and the Google edit stays a review")
    func etagMovedBeforeSend() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.setPhone("I1", "415-555-9999")
        let plan = try await rig.plan()
        try await rig.world.editGoogle("people/c1", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Annie")] }

        let report = try await rig.run(plan)
        #expect(report.updated == 1 && report.rediffed == 1 && report.isComplete)
        let ann = try await rig.googlePerson("people/c1")
        #expect(ann.phoneNumbers?.map(\.value) == ["415-555-9999"] && ann.nicknames?.first?.value == "Annie")

        let next = try await rig.plan()
        #expect(next.review.map(\.id) == ["googleEdited|I1|people/c1"], "the Google edit was not swallowed by the baseline")
        #expect(next.updates.isEmpty)
    }

    @Test("An etag mismatch from Google is retried once with a fresh read; a second one is left for the next run")
    func etagMismatchRetry() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.setPhone("I1", "415-555-9999")
        await rig.world.google.inject(.partialBatch(indices: [0], error: .etagMismatch), on: .batchUpdate)
        let report = try await rig.sync()
        #expect(report.updated == 1 && report.rediffed == 1 && report.isComplete)

        try await rig.setPhone("I2", "415-555-9998")
        await rig.world.google.inject(.partialBatch(indices: [0], error: .etagMismatch), on: .batchUpdate, times: 2)
        let stuck = try await rig.sync()
        #expect(stuck.updated == 0 && stuck.leftForNextRun.map(\.reason) == [.etagChanged] && !stuck.checkpointCommitted)
        #expect(try rig.journal.load().entries.isEmpty)
        #expect(try await rig.sync().updated == 1)
    }

    @Test("A conflict that is still waiting for the user survives a push to the same contact")
    func pendingReviewSurvivesPush() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.editICloud("I1") {
            $0.nickname = "Ann-i"
            $0.phones = [Labeled(label: "mobile", value: "415-555-9999")]
        }
        try await rig.world.editGoogle("people/c1", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Ann-g")] }
        let plan = try await rig.plan()
        #expect(plan.updates.map(\.fields) == [[.phones]] && plan.review.map(\.kind) == [.bothEdited])
        _ = try rig.reviews.reconcile(with: plan, at: rig.clock.now())
        let report = try await rig.run(plan)
        #expect(report.updated == 1 && report.checkpointCommitted && report.icloudTokenHeld)

        let next = try await rig.plan()
        #expect(rig.world.lastScan?.status == .changed, "scanned in full while a conflict is open")
        #expect(next.review.map(\.id) == ["bothEdited|I1|people/c1"] && next.updates.isEmpty, "the etag must not hide the unreviewed edit")
        _ = try rig.reviews.reconcile(with: next, at: rig.clock.now())
        #expect(try rig.reviews.load().map(\.id) == ["bothEdited|I1|people/c1"])
    }

    @Test("A Google edit waiting for review is not forgotten, so the contact cannot be deleted from under it")
    func heldGoogleEditSurvivesToDelete() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.editGoogle("people/c1", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Annie")] }
        let before = try #require(try rig.state.baselines["I1"])

        let first = try await rig.plan()
        #expect(first.review.map(\.id) == ["googleEdited|I1|people/c1"] && first.baselineRefreshes.isEmpty && first.updates.isEmpty)
        try rig.reviews.reconcile(with: first, at: rig.clock.now())
        #expect(try await rig.run(first).checkpointCommitted)
        #expect(try rig.state.baselines["I1"]?.googleEtag == before.googleEtag, "the baseline etag must not jump over the unreviewed edit")

        try await rig.setPhone("I3", "415-555-7777")
        let second = try await rig.plan()
        try rig.reviews.reconcile(with: second, at: rig.clock.now())
        #expect(try await rig.run(second).updated == 1)

        let full = try await rig.plan(requireFullListing: true)
        #expect(full.reviewIsComplete && full.review.map(\.id) == ["googleEdited|I1|people/c1"])
        try rig.reviews.reconcile(with: full, at: rig.clock.now())
        #expect(try rig.reviews.load().map(\.id) == ["googleEdited|I1|people/c1"], "a complete plan still sees the conflict")

        try await rig.world.store.delete(ids: ["I1"], backup: .forTesting())
        let deleting = try await rig.plan()
        #expect(deleting.deletes.map(\.icloudID) == ["I1"], "the incremental planner cannot see the Google edit")
        let blocked = try await rig.run(deleting)
        #expect(blocked.deleted == 0 && blocked.blockedByReview == ["I1"])
        #expect((try? await rig.googlePerson("people/c1")) != nil)

        // Even with an empty review list, the executor's own check against the baseline catches it.
        try rig.reviews.remove(ids: try rig.reviews.load().map(\.id))
        let checked = try await rig.run(deleting)
        #expect(checked.deleted == 0 && checked.reviewsAdded == ["deletedInICloudEditedInGoogle|I1|people/c1"])
        #expect((try? await rig.googlePerson("people/c1")) != nil)
    }

    @Test("A conflict that only shows up while writing is reported, becomes a review item, and keeps the iCloud token")
    func conflictFoundWhileWriting() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.editICloud("I1") {
            $0.nickname = "Ann-i"
            $0.phones = [Labeled(label: "mobile", value: "415-555-9999")]
        }
        let plan = try await rig.plan()
        #expect(plan.updates.map(\.fields) == [[.nickname, .phones]] && plan.review.isEmpty)
        try await rig.world.editGoogle("people/c1", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Ann-g")] }
        let tokenBefore = try rig.state.icloudChangeToken

        let report = try await rig.run(plan)
        #expect(report.updated == 1 && report.rediffed == 1 && report.isComplete && report.checkpointCommitted)
        #expect(report.conflictsFound == ["bothEdited|I1|people/c1"] && report.icloudTokenHeld)
        #expect(try rig.state.icloudChangeToken == tokenBefore)
        let item = try #require(try rig.reviews.load().first)
        #expect(item.id == "bothEdited|I1|people/c1" && item.fields == [.nickname])
        let ann = try await rig.googlePerson("people/c1")
        #expect(ann.phoneNumbers?.map(\.value) == ["415-555-9999"] && ann.nicknames?.first?.value == "Ann-g")

        let next = try await rig.plan()
        #expect(rig.world.lastScan?.status == .changed)
        #expect(next.review.map(\.id) == ["bothEdited|I1|people/c1"] && next.updates.isEmpty, "the iCloud edit is still visible")
        #expect(next.review.first?.icloudFingerprint != nil)
    }

    // MARK: ambiguous results and crashes

    @Test("An ambiguous update that was applied is recognised: baseline from Google's contact, nothing to redo")
    func ambiguousApplied() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.setPhone("I1", "415-555-9999")
        rig.faulty.arm(.ambiguousAfterApply, on: .batchUpdate)
        let report = try await rig.sync()
        #expect(report.updated == 1 && report.recovery.applied == 1 && report.isComplete && report.checkpointCommitted)
        let ann = try await rig.googlePerson("people/c1")
        #expect(try rig.state.baselines["I1"]?.googleEtag == ann.etag)
        #expect(try rig.journal.load().entries.isEmpty)
        #expect(try await rig.plan().isEmpty)
    }

    @Test("An ambiguous update that was not applied is left for the next run, with the old baseline")
    func ambiguousNotApplied() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.setPhone("I1", "415-555-9999")
        let before = try rig.state
        await rig.world.google.inject(.error(.other(status: 503, message: "backend error")), on: .batchUpdate)
        let report = try await rig.sync()
        #expect(report.updated == 0 && report.recovery.notApplied == 1 && report.leftForNextRun.map(\.reason) == [.notApplied])
        #expect(try rig.state.baselines["I1"] == before.baselines["I1"] && !report.checkpointCommitted)
        #expect(try await rig.sync().updated == 1)
    }

    @Test("An ambiguous create that was applied is found by its tag and linked; it is never created twice")
    func ambiguousCreateApplied() async throws {
        let rig = try await ExecutorRig.linked(count: 2)
        defer { rig.cleanUp() }
        let carol = try await rig.addICloudContact("Carol", "Newman", phone: "415-555-0100", note: "hello")
        rig.faulty.arm(.ambiguousAfterApply, on: .batchCreate)
        let report = try await rig.sync()
        #expect(report.created == 1 && report.recovery.applied == 1 && report.isComplete)
        #expect(await rig.taggedPeople(carol.sourceIdentifier).count == 1)
        #expect(try rig.links[carol.sourceIdentifier]?.origin == .createdInGoogle)
        let baseline = try #require(try rig.state.baselines[carol.sourceIdentifier])
        #expect(baseline.googleNoteHash == NoteHash.hash("hello") && baseline.icloudNoteHash == NoteHash.hash("hello"))
        let again = try await rig.sync()
        let tagged = await rig.taggedPeople(carol.sourceIdentifier)
        #expect(again.created == 0 && tagged.count == 1)
    }

    @Test("An ambiguous create that left no trace is held for ten minutes, then released to be planned again")
    func ambiguousCreateNotApplied() async throws {
        let rig = try await ExecutorRig.linked(count: 2)
        defer { rig.cleanUp() }
        let carol = try await rig.addICloudContact("Carol", "Newman", phone: "415-555-0100")
        await rig.world.google.inject(.error(.other(status: 500, message: "oops")), on: .batchCreate)
        let report = try await rig.sync()
        #expect(report.created == 0 && report.leftForNextRun.map(\.reason) == [.unconfirmed] && !report.checkpointCommitted)
        #expect(await rig.taggedPeople(carol.sourceIdentifier).isEmpty)
        #expect(try rig.journal.load().entries.map(\.kind) == [.create], "kept: a listing this soon proves nothing")

        rig.clock.advance(minutes: 9)
        let early = try await rig.sync()
        #expect(early.created == 0 && early.leftForNextRun.map(\.reason) == [.unconfirmed])
        #expect(await rig.taggedPeople(carol.sourceIdentifier).isEmpty)

        rig.clock.advance(minutes: 2)
        let settled = try await rig.makeExecutor().recoverInterruptedRun()
        #expect(try settled.notApplied == 1 && rig.journal.load().entries.isEmpty)
        #expect(try await rig.sync().created == 1)
        #expect(await rig.taggedPeople(carol.sourceIdentifier).count == 1)
    }

    @Test("A create whose listing lags is never repeated: held while the tag is missing, linked once it shows up")
    func createListingLag() async throws {
        let rig = try await ExecutorRig.linked(count: 2)
        defer { rig.cleanUp() }
        let carol = try await rig.addICloudContact("Carol", "Newman", phone: "415-555-0100", note: "hi")
        let id = carol.sourceIdentifier
        let stale = try await rig.plan()
        #expect(stale.creates.map(\.icloudID) == [id])
        rig.faulty.setListingLag(true)
        rig.faulty.arm(.ambiguousAfterApply, on: .batchCreate)

        let first = try await rig.run(stale)
        #expect(first.created == 0 && first.leftForNextRun.map(\.reason) == [.unconfirmed] && first.recovery.unresolved == 1)
        let created = await rig.taggedPeople(id)
        #expect(try created.count == 1 && rig.links[id] == nil)
        let held = try #require(try rig.journal.load().entries.first)
        #expect(held.recheckedAt != nil && held.attemptedAt != nil)

        // A planner whose own listing lags would plan the same create again: it is held, not sent.
        rig.clock.advance(minutes: 1)
        let again = try await rig.run(stale)
        #expect(again.created == 0 && again.leftForNextRun.map(\.reason) == [.unconfirmed] && !again.checkpointCommitted)
        rig.clock.advance(minutes: 5)
        #expect(try await rig.makeExecutor().recoverInterruptedRun().unresolved == 1)
        #expect(await rig.taggedPeople(id).count == 1)

        // The listing catches up: the contact is found by its tag and linked from what Google holds.
        rig.faulty.setListingLag(false)
        let found = try await rig.makeExecutor().recoverInterruptedRun()
        #expect(try found.applied == 1 && rig.journal.load().entries.isEmpty)
        let person = try #require(await rig.taggedPeople(id).first)
        let baseline = try #require(try rig.state.baselines[id])
        #expect(try rig.links[id]?.googleResourceName == person.resourceName && rig.links[id]?.origin == .createdInGoogle)
        #expect(baseline.googleEtag == person.etag && baseline.googleNoteHash == NoteHash.hash("hi"))
        let last = try await rig.sync()
        let tagged = await rig.taggedPeople(id)
        #expect(last.created == 0 && tagged.count == 1)
    }

    @Test("Once the grace period is over, a listing that still lacks the tag releases the create")
    func createLagGraceOver() async throws {
        let rig = try await ExecutorRig.linked(count: 2)
        defer { rig.cleanUp() }
        let carol = try await rig.addICloudContact("Carol", "Newman", phone: "415-555-0100")
        rig.faulty.setListingLag(true)
        rig.faulty.arm(.ambiguousAfterApply, on: .batchCreate)
        try await rig.sync()
        rig.clock.advance(minutes: 9)
        #expect(try await rig.makeExecutor().recoverInterruptedRun().unresolved == 1)
        rig.clock.advance(minutes: 2)
        let released = try await rig.makeExecutor().recoverInterruptedRun()
        #expect(try released.notApplied == 1 && released.unresolved == 0 && rig.journal.load().entries.isEmpty)
        #expect(await rig.taggedPeople(carol.sourceIdentifier).count == 1, "the lagging fake really holds it; the release is the accepted risk")
    }

    @Test("If the planner linked a held create from a later listing, recovery leaves that newer baseline alone")
    func heldCreateLinkedByPlanner() async throws {
        let rig = try await ExecutorRig.linked(count: 2)
        defer { rig.cleanUp() }
        let carol = try await rig.addICloudContact("Carol", "Newman", phone: "415-555-0100")
        let id = carol.sourceIdentifier
        rig.faulty.setListingLag(true)
        rig.faulty.arm(.ambiguousAfterApply, on: .batchCreate)
        try await rig.sync()
        #expect(try rig.journal.load().entries.count == 1)

        let linking = try await rig.plan()
        #expect(linking.links.map(\.icloudID) == [id] && linking.creates.isEmpty)
        let report = try await rig.run(linking)
        #expect(report.linksAdded == 1)
        let before = try #require(try rig.state.baselines[id])
        rig.faulty.setListingLag(false)
        #expect(try await rig.makeExecutor().recoverInterruptedRun().applied == 1)
        #expect(try rig.state.baselines[id] == before && rig.journal.load().entries.isEmpty)
    }

    @Test("An ambiguous delete is settled by asking Google: gone means done")
    func ambiguousDelete() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.store.delete(ids: ["I2"], backup: .forTesting())
        rig.faulty.arm(.ambiguousAfterApply, on: .batchDelete)
        let report = try await rig.sync()
        #expect(report.deleted == 1 && report.recovery.applied == 1 && report.isComplete)
        #expect(try rig.links["I2"] == nil && rig.state.baselines["I2"] == nil)
    }

    @Test("A crash after Google applied the creates: recovery finds them by tag, links them, and nothing is duplicated")
    func crashMidRun() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.setPhone("I1", "415-555-9999")
        try await rig.world.store.delete(ids: ["I2"], backup: .forTesting())
        let carol = try await rig.addICloudContact("Carol", "Newman", phone: "415-555-0100", note: "remember")
        rig.faulty.arm(.crashAfterApply, on: .batchCreate)

        let crashing = try await rig.plan()
        await #expect(throws: FaultyGoogle.Crash.self) { try await rig.run(crashing) }
        // The update was committed before the crash; the create is applied in Google but unrecorded; the delete never ran.
        #expect(try rig.state.baselines["I1"]?.icloud.phones.map(\.value) == ["415-555-9999"])
        #expect(try rig.links[carol.sourceIdentifier] == nil && rig.state.baselines[carol.sourceIdentifier] == nil)
        #expect(await rig.taggedPeople(carol.sourceIdentifier).count == 1)
        #expect(try rig.journal.load().entries.map(\.kind) == [.create])
        #expect(await rig.world.google.allPeople.contains { $0.resourceName == "people/c2" })

        // A fresh executor (the app restarted) refuses to run until the journal is settled.
        await #expect(throws: SyncExecutorError.interruptedRunPending(entries: 1)) { try await rig.run(try await rig.plan()) }
        let recovered = try await rig.makeExecutor().recoverInterruptedRun()
        #expect(recovered.applied == 1 && recovered.notApplied == 0 && recovered.unresolved == 0)
        #expect(try rig.journal.load().entries.isEmpty)
        let link = try #require(try rig.links[carol.sourceIdentifier])
        let created = try #require(await rig.taggedPeople(carol.sourceIdentifier).first)
        #expect(link.googleResourceName == created.resourceName && link.origin == .createdInGoogle)
        let baseline = try #require(try rig.state.baselines[carol.sourceIdentifier])
        #expect(baseline.googleEtag == created.etag && baseline.google == GooglePersonMapper.record(from: created))
        #expect(baseline.googleNoteHash == NoteHash.hash("remember") && baseline.icloudNoteHash == NoteHash.hash("remember"))

        let rest = try await rig.sync()
        #expect(rest.created == 0 && rest.deleted == 1 && rest.isComplete && rest.checkpointCommitted)
        let tagged = await rig.taggedPeople(carol.sourceIdentifier)
        let total = await rig.world.google.allPeople.count
        #expect(tagged.count == 1 && total == 6)
        #expect(try await rig.plan().isEmpty)
    }

    @Test("A crash after an update was applied: recovery recognises it by the contact's content and advances the baseline")
    func crashAfterUpdate() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.setPhone("I1", "415-555-9999")
        rig.faulty.arm(.crashAfterApply, on: .batchUpdate)
        await #expect(throws: FaultyGoogle.Crash.self) { try await rig.sync() }
        let recovered = try await rig.makeExecutor().recoverInterruptedRun()
        #expect(recovered.applied == 1)
        let ann = try await rig.googlePerson("people/c1")
        #expect(try rig.state.baselines["I1"]?.googleEtag == ann.etag)
        #expect(try await rig.plan().updates.isEmpty)
    }

    @Test("A crash before the update reached Google: recovery sees the old etag and leaves it for the next plan")
    func crashBeforeUpdateApplied() async throws {
        let rig = try await ExecutorRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setPhone("I1", "415-555-9999")
        let before = try rig.state
        // Journal written, nothing sent: as if the process died between the two.
        let plan = try await rig.plan()
        let update = try #require(plan.updates.first)
        try rig.journal.append([SyncJournalEntry(
            opID: "op1", kind: .update, icloudID: "I1", resourceName: update.resourceName, tag: "I1", baseEtag: update.etag,
            payloadHash: "x", fields: [.phones], baseline: update.baseline
        )])
        let recovered = try await rig.makeExecutor().recoverInterruptedRun()
        #expect(recovered.notApplied == 1 && recovered.applied == 0)
        #expect(try rig.state.baselines["I1"] == before.baselines["I1"] && rig.journal.load().entries.isEmpty)
        #expect(try await rig.sync().updated == 1)
    }

    @Test("Recovery cannot decide while Google is unreachable: the entry stays in the journal")
    func recoveryUnresolved() async throws {
        let rig = try await ExecutorRig.linked(count: 2)
        defer { rig.cleanUp() }
        try rig.journal.append([SyncJournalEntry(
            opID: "op1", kind: .delete, icloudID: "I1", resourceName: "people/c1", tag: "I1", baseEtag: "e1", payloadHash: nil,
            fields: [], baseline: nil
        )])
        await rig.world.google.inject(.error(.other(status: 503, message: "down")), on: .getPerson)
        let recovered = try await rig.makeExecutor().recoverInterruptedRun()
        #expect(recovered.unresolved == 1 && recovered.applied == 0)
        #expect(try rig.journal.load().entries.count == 1)
        let retried = try await rig.makeExecutor().recoverInterruptedRun()
        #expect(retried.notApplied == 1, "Google still has the contact, so the delete did not happen")
        #expect(try rig.journal.load().entries.isEmpty && rig.links["I1"] != nil)
    }

    // MARK: deletes

    @Test("If Google changed the contact since the baseline, the delete becomes a review item and nothing is deleted")
    func deleteTurnsIntoReview() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.store.delete(ids: ["I2"], backup: .forTesting())
        let plan = try await rig.plan()
        #expect(plan.deletes.map(\.icloudID) == ["I2"], "the planner saw nothing wrong")
        // Google moves on after the planning (or in a feed page the planner never saw).
        try await rig.world.editGoogle("people/c2", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Bobby")] }

        let report = try await rig.run(plan)
        #expect(report.deleted == 0 && report.reviewsAdded == ["deletedInICloudEditedInGoogle|I2|people/c2"] && report.isComplete)
        #expect((try? await rig.googlePerson("people/c2")) != nil)
        #expect(try rig.links["I2"] != nil && rig.state.baselines["I2"] != nil)
        let item = try #require(try rig.reviews.load().first)
        #expect(item.kind == .deletedInICloudEditedInGoogle && item.icloudID == "I2" && item.resourceName == "people/c2")
        let bob = try await rig.googlePerson("people/c2")
        #expect(item.googleEtag == bob.etag)
    }

    @Test("A churned etag with identical content is not an edit: the delete goes ahead")
    func deleteIgnoresEtagChurn() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.store.delete(ids: ["I2"], backup: .forTesting())
        let plan = try await rig.plan()
        try await rig.world.editGoogle("people/c2", mask: "names") { _ in }
        let report = try await rig.run(plan)
        #expect(report.deleted == 1 && report.reviewsAdded.isEmpty)
        #expect((try? await rig.googlePerson("people/c2")) == nil)
    }

    @Test("An open review item for the contact blocks its delete, and no second item is added")
    func openReviewBlocksDelete() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        _ = try rig.reviews.add([ReviewCandidate(kind: .googleEdited, icloudID: "I2", resourceName: "people/c2", googleEtag: "e9", fields: [.nickname])], at: rig.clock.now())
        try await rig.world.store.delete(ids: ["I2"], backup: .forTesting())
        let report = try await rig.sync()
        #expect(report.deleted == 0 && report.blockedByReview == ["I2"] && report.reviewsAdded.isEmpty && report.isComplete)
        #expect((try? await rig.googlePerson("people/c2")) != nil)
        #expect(try rig.reviews.load().count == 1 && rig.links["I2"] != nil)
    }

    @Test("A contact that is already gone from Google (404) is not an error: link and baseline are dropped")
    func deleteAlreadyGone() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.store.delete(ids: ["I2"], backup: .forTesting())
        let plan = try await rig.plan()
        try await rig.world.google.deleteContact(resourceName: "people/c2")
        let report = try await rig.run(plan)
        #expect(report.deleted == 0 && report.alreadyGone == 1 && report.isComplete && report.leftForNextRun.isEmpty)
        #expect(try rig.links["I2"] == nil && rig.state.baselines["I2"] == nil)
    }

    @Test("Only a Google contact that links.json and a baseline tie to the deleted iCloud contact is ever deleted")
    func neverDeletesUnlinked() async throws {
        let rig = try await ExecutorRig.linked(count: 3)
        defer { rig.cleanUp() }
        let stranger = try await rig.world.google.createContact(SyncFixtures.person("Zed", "Quinn", phones: ["415-555-0099"]))
        let baseline = try #require(try rig.state.baselines["I1"])
        var plan = SyncPlan(isPreview: false)
        plan.deletes = [
            PlannedDelete(icloudID: "NOPE", resourceName: try #require(stranger.resourceName), baseline: baseline),
            PlannedDelete(icloudID: "I1", resourceName: try #require(stranger.resourceName), baseline: baseline),
            PlannedDelete(icloudID: "I1", resourceName: "people/c2", baseline: baseline),
        ]
        let report = try await rig.run(plan)
        #expect(report.deleted == 0 && report.leftForNextRun.map(\.reason) == [.notLinked, .notLinked, .notLinked])
        #expect(await rig.world.google.allPeople.count == 4)
    }

    // MARK: backups and history

    @Test("Google writes need a Google backup from the last 24 hours: reused inside that, renewed after")
    func backupFreshness() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try await rig.setPhone("I1", "415-555-1001")
        let first = try await rig.sync()
        let receipt = try #require(first.backup)
        #expect(rig.backupFolders() == 1 && receipt.manifest.sources.contains("google"))

        rig.clock.advance(hours: 3)
        try await rig.setPhone("I1", "415-555-1002")
        let reused = try await rig.sync()
        #expect(reused.backup == receipt && reused.updated == 1 && rig.backupFolders() == 1, "3 hours old is fine for Google writes")

        rig.clock.advance(hours: 25)
        try await rig.setPhone("I1", "415-555-1003")
        let renewed = try await rig.sync()
        #expect(renewed.backup != receipt && renewed.updated == 1 && rig.backupFolders() == 2)
        #expect(renewed.backup?.isFresh(maxAge: SyncExecutor.maxBackupAge, now: rig.clock.now()) == true)
    }

    @Test("A plan with no Google writes takes no backup")
    func noBackupWithoutWrites() async throws {
        let rig = try await ExecutorRig.linked(count: 2)
        defer { rig.cleanUp() }
        let report = try await rig.sync()
        #expect(report.backup == nil && rig.backupFolders() == 0 && report.googleWrites == 0)
    }

    @Test("A failed backup stops the run before anything is written")
    func backupFailure() async throws {
        let world = try await SyncWorld.linked(count: 2)
        let rig = try ExecutorRig(world)
        defer { rig.cleanUp() }
        try await rig.setPhone("I1", "415-555-9999")
        let plan = try await rig.plan()
        await world.google.inject(.error(.other(status: 500, message: "backup read failed")), on: .listConnections)
        await #expect(throws: (any Error).self) { try await rig.run(plan) }
        let firstPhone = await world.google.allPeople.first?.phoneNumbers?.first?.value
        #expect(firstPhone != "415-555-9999")
        #expect(try rig.journal.load().entries.isEmpty)
    }

    @Test("Every update and delete is written to the history before and after, and old days are pruned")
    func historyFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SyncHistoryStore(directory: directory, timeZone: TimeZone(identifier: "UTC") ?? .current)
        let rig = try await ExecutorRig.linked(history: history)
        defer { rig.cleanUp() }
        try await rig.setPhone("I1", "415-555-9999")
        try await rig.world.store.delete(ids: ["I2"], backup: .forTesting())
        let beforeAnn = try await rig.googlePerson("people/c1")
        let beforeBob = try await rig.googlePerson("people/c2")
        try await rig.sync()

        let day = ISO8601DateFormatter().string(from: SyncFixtures.t0).prefix(10)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["\(day).jsonl"])
        let entries = try history.entries()
        let update = try #require(entries.first { $0.operation == .update && $0.confirmed })
        let afterAnn = try await rig.googlePerson("people/c1")
        #expect(update.before == beforeAnn && update.after == afterAnn && update.icloudID == "I1")
        let attempt = try #require(entries.first { $0.operation == .update && !$0.confirmed })
        #expect(attempt.before == beforeAnn && attempt.after == nil)
        let delete = try #require(entries.first { $0.operation == .delete && $0.confirmed })
        #expect(delete.before == beforeBob && delete.after == nil && delete.resourceName == "people/c2")
        #expect(entries.count == 4)

        // The next run, 31 days on, prunes the old day.
        rig.clock.advance(hours: 31 * 24)
        try await rig.setPhone("I3", "415-555-0303")
        try await rig.sync()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining.count == 1 && remaining != ["\(day).jsonl"])
    }
}
