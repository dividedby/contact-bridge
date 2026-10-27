import Foundation
import Testing
@testable import ContactBridgeCore

/// Photo questions, decided: what each button does to the two contacts, the baselines and the review list.
final class PhotoReviewRig: @unchecked Sendable {
    let photos: PhotoRig
    let gate = WriteGate()
    let workflows: ReviewWorkflows

    init(_ photos: PhotoRig) {
        self.photos = photos
        let base = photos.base
        let clock = base.clock
        let support = SyncPhotoSupport(fetcher: photos.fetcher, history: photos.photoHistory, sleep: { _ in })
        workflows = ReviewWorkflows(
            store: base.world.store, google: base.faulty, notes: base.world.notes, backups: base.backups, links: base.linkStore,
            state: base.stateStore, reviews: base.reviews, journal: base.journal, history: base.history, gate: gate,
            now: { clock.now() }, photos: support
        )
    }

    static func linked(count: Int = 3) async throws -> PhotoReviewRig { PhotoReviewRig(try await PhotoRig.linked(count: count)) }

    /// Plans the photos as a run would and files the questions it finds.
    @discardableResult
    func ask() async throws -> [ReviewItem] {
        let plan = try await photos.look(.syncNow, fullListing: true).plan
        _ = try photos.base.reviews.reconcile(with: plan, ignoredGoogle: [], at: photos.base.clock.now())
        return try items()
    }

    func items() throws -> [ReviewItem] { try photos.base.reviews.load().filter { $0.kind == .photoConflict } }
    func item(_ icloudID: String) throws -> ReviewItem { try #require(try items().first { $0.icloudID == icloudID }) }
    func detail(_ icloudID: String) async throws -> ReviewDetail { try await workflows.loadDetail(try item(icloudID)) }

    /// The pair's photos have been looked at and agree; then `change` happens and the removal is seen twice, five minutes on.
    func settled(_ id: String = "I1", picture: Data) async throws {
        try await photos.setICloudPhoto(id, picture)
        try await photos.sync()
    }

    func removalSeenTwice() async throws {
        try await photos.sync()
        photos.base.clock.advance(minutes: 6)
        try await ask()
    }

    /// A run of the sync as the engine makes it, to see that nothing is asked or written again.
    func expectSettled(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let plan = try await photos.look(.syncNow, fullListing: true).plan
        #expect(plan.review.filter { $0.kind == .photoConflict }.isEmpty, sourceLocation: sourceLocation)
        #expect(plan.photoOps.allSatisfy { $0.kind == .recordBaseline }, sourceLocation: sourceLocation)
    }

    func similar(_ data: Data?, to original: Data) -> Bool {
        guard let data, let a = ImageIOPhotoFingerprinter().fingerprint(of: data), let b = ImageIOPhotoFingerprinter().fingerprint(of: original) else { return false }
        return a.isSimilar(to: b)
    }
}

struct PhotoReviewWorkflowTests {
    private let one = PhotoPictures.picture(1)
    private let two = PhotoPictures.picture(2)
    private let three = PhotoPictures.picture(3)

    private func done(_ outcome: ReviewOutcome) -> Bool { outcome == .done(warnings: []) }

    // MARK: words

    @Test("Each question offers the choices the spec lists, in its own words")
    func draftOptions() {
        func titles(_ reason: PhotoConflictReason) -> [String] { PhotoReviewDraft(reason: reason).options.map(\.title) }
        #expect(titles(.firstSightDiffers) == ["Keep iCloud's photo", "Keep Google's photo"])
        #expect(titles(.bothChanged) == ["Keep iCloud's photo", "Keep Google's photo"])
        #expect(titles(.removedOneChangedOther) == ["Keep iCloud's version", "Keep Google's version"])
        #expect(titles(.removedInICloud) == ["Add Google's photo back to iCloud", "Delete it from Google too", "Do nothing"])
        #expect(titles(.removedInGoogle) == ["Add iCloud's photo back to Google", "Delete it from iCloud too", "Do nothing"])
        #expect(titles(.profileRemovedInICloud) == ["Add their Google profile photo back", "Do nothing (stop using their profile photo for this contact)"])
        #expect(PhotoReviewDraft(reason: .profileRemovedInICloud).explanation.contains("can't be removed from Google"))
        #expect(PhotoReviewDraft(reason: .removedInICloud).options.map(\.isDestructive) == [false, true, false])
        #expect(PhotoReviewDraft(reason: .removedInGoogle).options.map(\.choice) == [.keepICloud, .keepGoogle, .doNothing])
    }

    @Test("The open item shows both pictures and the reason, and its stored stamp follows the live photos")
    func detailShowsPictures() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.photos.setICloudPhoto("I1", one)
        try await rig.photos.setGooglePhoto(1, two)
        try await rig.ask()

        let detail = try await rig.detail("I1")
        let photos = try #require(detail.photos)
        let google = await rig.photos.googlePhoto(1)
        #expect(photos.draft.reason == .firstSightDiffers && photos.icloud == one && photos.google == google && photos.profile == nil)
        #expect(detail.name == "First1 Last1")
        let stored = try rig.item("I1").photoStamp
        #expect(detail.stamp.photoStamp == stored)
    }

    // MARK: conflicts

    @Test("First sight, different photos: keeping iCloud's sends it to Google, saves Google's old one, and nothing is asked again")
    func keepICloudAtFirstSight() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.photos.setICloudPhoto("I1", one)
        try await rig.photos.setGooglePhoto(1, two)
        let old = await rig.photos.googlePhoto(1)
        try await rig.ask()
        let detail = try await rig.detail("I1")

        #expect(done(try await rig.workflows.applyPhoto(detail, choice: .keepICloud)))
        let onGoogle = await rig.photos.googlePhoto(1)
        #expect(rig.similar(onGoogle, to: one) && onGoogle != old)
        #expect(try rig.photos.photoHistory.entries().map(\.photo) == [try #require(old)])
        #expect(try rig.items().isEmpty)
        let baseline = try #require(try rig.photos.photoBaseline("I1"))
        #expect(baseline.icloud != nil && baseline.google != nil && baseline.googleURLKey != nil && baseline.failure == nil)
        try await rig.expectSettled()
    }

    @Test("First sight, different photos: keeping Google's puts it in iCloud behind a backup")
    func keepGoogleAtFirstSight() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.photos.setICloudPhoto("I1", one)
        try await rig.photos.setGooglePhoto(1, two)
        try await rig.ask()
        let detail = try await rig.detail("I1")

        #expect(done(try await rig.workflows.applyPhoto(detail, choice: .keepGoogle)))
        let onICloud = try await rig.photos.icloudPhoto("I1")
        let onGoogle = await rig.photos.googlePhoto(1)
        let left = try rig.items()
        #expect(onICloud == onGoogle && rig.photos.base.backupFolders() == 1 && left.isEmpty)
        try await rig.expectSettled()
    }

    @Test("Changed on both sides: the chosen side wins")
    func bothChanged() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.settled(picture: one)
        try await rig.photos.setICloudPhoto("I1", two)
        try await rig.photos.setGooglePhoto(1, three)
        try await rig.ask()
        #expect(try rig.item("I1").photoReason == .bothChanged)

        #expect(done(try await rig.workflows.applyPhoto(try await rig.detail("I1"), choice: .keepICloud)))
        let onGoogle = await rig.photos.googlePhoto(1)
        #expect(rig.similar(onGoogle, to: two))
        try await rig.expectSettled()
    }

    @Test("Removed on one side and changed on the other: keeping the side with no photo removes the other's, after saving it")
    func removedAndChanged() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.settled(picture: one)
        try await rig.photos.setICloudPhoto("I1", nil)
        try await rig.photos.setGooglePhoto(1, two)
        let theirs = await rig.photos.googlePhoto(1)
        try await rig.ask()
        #expect(try rig.item("I1").photoReason == .removedOneChangedOther)

        #expect(done(try await rig.workflows.applyPhoto(try await rig.detail("I1"), choice: .keepICloud)))
        let onGoogle = await rig.photos.googlePhoto(1)
        #expect(onGoogle == nil)
        let history = try rig.photos.photoHistory.entries()
        #expect(history.last?.operation == .delete && history.last?.photo == theirs)
        try await rig.expectSettled()
    }

    // MARK: removals

    @Test("Removed in iCloud, Google still has one: add it back")
    func removedInICloudAddBack() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.settled(picture: one)
        try await rig.photos.setICloudPhoto("I1", nil)
        try await rig.removalSeenTwice()
        #expect(try rig.item("I1").photoReason == .removedInICloud)

        #expect(done(try await rig.workflows.applyPhoto(try await rig.detail("I1"), choice: .keepGoogle)))
        let onICloud = try await rig.photos.icloudPhoto("I1")
        let onGoogle = await rig.photos.googlePhoto(1)
        #expect(onICloud != nil && onICloud == onGoogle)
        try await rig.expectSettled()
    }

    @Test("Removed in iCloud: deleting it from Google too saves the photo first")
    func removedInICloudDeleteFromGoogle() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.settled(picture: one)
        let old = await rig.photos.googlePhoto(1)
        try await rig.photos.setICloudPhoto("I1", nil)
        try await rig.removalSeenTwice()

        #expect(done(try await rig.workflows.applyPhoto(try await rig.detail("I1"), choice: .keepICloud)))
        let onGoogle = await rig.photos.googlePhoto(1)
        let saved = try rig.photos.photoHistory.entries().last?.photo
        #expect(onGoogle == nil && saved == old)
        try await rig.expectSettled()
    }

    @Test("Removed in iCloud: doing nothing records the state, and the question only comes back when a photo changes")
    func removedInICloudDoNothing() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.settled(picture: one)
        let google = await rig.photos.googlePhoto(1)
        try await rig.photos.setICloudPhoto("I1", nil)
        try await rig.removalSeenTwice()

        #expect(done(try await rig.workflows.applyPhoto(try await rig.detail("I1"), choice: .doNothing)))
        let after = await rig.photos.googlePhoto(1)
        let icloud = try await rig.photos.icloudPhoto("I1")
        let left = try rig.items()
        #expect(after == google && icloud == nil && left.isEmpty)
        let baseline = try #require(try rig.photos.photoBaseline("I1"))
        #expect(baseline.icloud == nil && baseline.google != nil && baseline.pendingRemoval == nil)
        try await rig.expectSettled()

        // Either side changing brings the question back (here: Google's photo).
        try await rig.photos.setGooglePhoto(1, two)
        let plan = try await rig.photos.look(.syncNow, fullListing: true).plan
        #expect(plan.photoOps.contains { $0.icloudID == "I1" && $0.kind == .copyToICloud(source: .googleContact) })
    }

    @Test("Removed in Google, iCloud still has one: add it back to Google")
    func removedInGoogleAddBack() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.settled(picture: one)
        try await rig.photos.setGooglePhoto(1, nil)
        try await rig.removalSeenTwice()
        #expect(try rig.item("I1").photoReason == .removedInGoogle)

        #expect(done(try await rig.workflows.applyPhoto(try await rig.detail("I1"), choice: .keepICloud)))
        let onGoogle = await rig.photos.googlePhoto(1)
        #expect(rig.similar(onGoogle, to: one))
        try await rig.expectSettled()
    }

    @Test("Removed in Google: deleting it from iCloud too takes a backup first")
    func removedInGoogleDeleteFromICloud() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.settled(picture: one)
        try await rig.photos.setGooglePhoto(1, nil)
        try await rig.removalSeenTwice()

        #expect(done(try await rig.workflows.applyPhoto(try await rig.detail("I1"), choice: .keepGoogle)))
        let onICloud = try await rig.photos.icloudPhoto("I1")
        #expect(onICloud == nil && rig.photos.base.backupFolders() == 1 && rig.photos.store.mutationLog.last?.kind == .photo)
        try await rig.expectSettled()
    }

    @Test("Removed in Google: doing nothing leaves both alone and records it")
    func removedInGoogleDoNothing() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.settled(picture: one)
        try await rig.photos.setGooglePhoto(1, nil)
        try await rig.removalSeenTwice()

        #expect(done(try await rig.workflows.applyPhoto(try await rig.detail("I1"), choice: .doNothing)))
        let onICloud = try await rig.photos.icloudPhoto("I1")
        let onGoogle = await rig.photos.googlePhoto(1)
        let left = try rig.items()
        #expect(onICloud != nil && onGoogle == nil && left.isEmpty)
        try await rig.expectSettled()
    }

    // MARK: profile photos

    private func profileRemovedRig() async throws -> PhotoReviewRig {
        let rig = try await PhotoReviewRig.linked()
        try rig.photos.base.stateStore.update { $0.useGoogleProfilePhotos = true }
        try await rig.photos.setGoogleProfile(1, two)
        try await rig.photos.sync()
        try #require(try rig.photos.photoBaseline("I1")?.icloudOrigin == .googleProfile)
        try await rig.photos.setICloudPhoto("I1", nil)
        try await rig.removalSeenTwice()
        try #require(try rig.item("I1").photoReason == .profileRemovedInICloud)
        return rig
    }

    @Test("A removed profile copy: add their profile photo back")
    func profileAddBack() async throws {
        let rig = try await profileRemovedRig()
        defer { rig.photos.cleanUp() }
        let detail = try await rig.detail("I1")
        #expect(detail.photos?.profile != nil)

        #expect(done(try await rig.workflows.applyPhoto(detail, choice: .keepGoogle)))
        let onICloud = try await rig.photos.icloudPhoto("I1")
        let writes = await rig.photos.google.photoWrites
        #expect(onICloud != nil && writes.isEmpty)
        let origin = try rig.photos.photoBaseline("I1")?.icloudOrigin
        let optOut = try rig.photos.state.profilePhotoOptOut
        #expect(origin == .googleProfile && optOut.isEmpty)
        try await rig.expectSettled()
    }

    @Test("A removed profile copy: doing nothing stops using their profile photo for this contact")
    func profileOptOut() async throws {
        let rig = try await profileRemovedRig()
        defer { rig.photos.cleanUp() }

        #expect(done(try await rig.workflows.applyPhoto(try await rig.detail("I1"), choice: .doNothing)))
        let optOut = try rig.photos.state.profilePhotoOptOut
        #expect(optOut == ["I1"])
        let onICloud = try await rig.photos.icloudPhoto("I1")
        #expect(onICloud == nil)
        let plan = try await rig.photos.look(.syncNow, fullListing: true).plan
        #expect(!plan.photoOps.contains { $0.icloudID == "I1" && $0.kind != .recordBaseline }, "no profile photo comes back")
    }

    // MARK: moved since shown

    @Test("A photo that changed after the item was opened: nothing is written, and the item is refreshed")
    func changedSinceShown() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.photos.setICloudPhoto("I1", one)
        try await rig.photos.setGooglePhoto(1, two)
        try await rig.ask()
        let detail = try await rig.detail("I1")
        let stamp = detail.stamp.photoStamp
        try await rig.photos.setGooglePhoto(1, three)
        let theirs = await rig.photos.googlePhoto(1)

        let outcome = try await rig.workflows.applyPhoto(detail, choice: .keepICloud)
        guard case .changedSinceShown(let fresh?) = outcome else {
            Issue.record("expected changedSinceShown with a fresh item, got \(outcome)")
            return
        }
        let after = await rig.photos.googlePhoto(1)
        let writes = await rig.photos.google.photoWrites
        #expect(after == theirs && writes.isEmpty && fresh.photos?.google == theirs)
        let storedStamp = try rig.item("I1").photoStamp
        #expect(fresh.stamp.photoStamp != stamp && storedStamp == fresh.stamp.photoStamp)
    }

    @Test("A contact that is gone: the question is dropped and nothing is written")
    func contactGone() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.photos.setICloudPhoto("I1", one)
        try await rig.photos.setGooglePhoto(1, two)
        try await rig.ask()
        let detail = try await rig.detail("I1")
        try await rig.photos.store.delete(ids: ["I1"], backup: .forTesting())

        #expect(try await rig.workflows.applyPhoto(detail, choice: .keepICloud) == .changedSinceShown(nil))
        #expect(try rig.items().isEmpty)
        let writes = await rig.photos.google.photoWrites
        #expect(writes.isEmpty)
    }

    @Test("Any decision clears a stored failure marker")
    func decisionClearsFailure() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.photos.setICloudPhoto("I1", one)
        try await rig.photos.setGooglePhoto(1, two)
        try await rig.ask()
        try rig.photos.base.stateStore.update {
            $0.baselines["I1"]?.photo = PhotoBaseline(syncedAt: SyncFixtures.t0, failure: PhotoBaseline.Failure(stamp: "x", message: "bad", at: SyncFixtures.t0))
        }
        #expect(done(try await rig.workflows.applyPhoto(try await rig.detail("I1"), choice: .doNothing)))
        #expect(try rig.photos.photoBaseline("I1")?.failure == nil)
    }

    @Test("A rate limit while deciding is reported, and the question stays")
    func halted() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.photos.setICloudPhoto("I1", one)
        try await rig.photos.setGooglePhoto(1, two)
        try await rig.ask()
        let detail = try await rig.detail("I1")
        await rig.photos.google.inject(.rateLimited(), on: .updateContactPhoto)

        await #expect(throws: ReviewWorkflowError.self) { try await rig.workflows.applyPhoto(detail, choice: .keepICloud) }
        #expect(try rig.items().count == 1)
    }

    // MARK: in bulk

    @Test("Keep iCloud for all: every photo question goes iCloud's way, removals included")
    func bulkKeepICloud() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        try await rig.photos.setICloudPhoto("I1", one)
        try await rig.photos.setGooglePhoto(1, two)           // first sight, different
        try await rig.settled("I2", picture: three)
        try await rig.photos.setICloudPhoto("I2", nil)       // removed in iCloud: iCloud's "no photo" wins
        try await rig.removalSeenTwice()
        let items = try rig.items()
        try #require(items.count == 2)

        let report = try await rig.workflows.keepICloudPhotosForAll(items)
        #expect(report.applied.sorted() == items.map(\.id).sorted() && report.needsConfirmation == nil && report.failed.isEmpty)
        let first = await rig.photos.googlePhoto(1)
        let second = await rig.photos.googlePhoto(2)
        let left = try rig.items()
        #expect(rig.similar(first, to: one) && second == nil && left.isEmpty)
    }

    @Test("Keep Google for all: every photo question goes Google's way")
    func bulkKeepGoogle() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        for index in 1...2 {
            try await rig.photos.setICloudPhoto("I\(index)", one)
            try await rig.photos.setGooglePhoto(index, two)
        }
        let items = try await rig.ask()
        try #require(items.count == 2)

        let report = try await rig.workflows.keepGooglePhotosForAll(items)
        #expect(report.applied.count == 2)
        for id in ["I1", "I2"] {
            let onICloud = try await rig.photos.icloudPhoto(id)
            #expect(rig.similar(onICloud, to: two))
        }
        #expect(try rig.items().isEmpty)
    }

    @Test("A question that moved on is left in the list by a bulk action")
    func bulkSkipsMoved() async throws {
        let rig = try await PhotoReviewRig.linked()
        defer { rig.photos.cleanUp() }
        for index in 1...2 {
            try await rig.photos.setICloudPhoto("I\(index)", one)
            try await rig.photos.setGooglePhoto(index, two)
        }
        let items = try await rig.ask()
        try await rig.photos.setGooglePhoto(2, three)

        let report = try await rig.workflows.keepICloudPhotosForAll(items)
        #expect(report.applied == ["photoConflict|I1|people/c1"] && report.changedSinceShown == ["photoConflict|I2|people/c2"])
        #expect(try rig.items().map(\.icloudID) == ["I2"])
    }

    @Test("A bulk action that would write more photos than the limit allows asks first, and does nothing until confirmed")
    func bulkGuard() async throws {
        let rig = try await PhotoReviewRig.linked(count: 30)
        defer { rig.photos.cleanUp() }
        for index in 1...21 {
            try await rig.photos.setICloudPhoto("I\(index)", one)
            try await rig.photos.setGooglePhoto(index, two)
        }
        let items = try await rig.ask()
        try #require(items.count == 21)

        let asked = try await rig.workflows.keepICloudPhotosForAll(items)
        #expect(asked.needsConfirmation?.contains("write 21 of 30 contact photos to Google") == true && asked.applied.isEmpty)
        let writes = await rig.photos.google.photoWrites
        let left = try rig.items().count
        #expect(writes.isEmpty && left == 21)

        let confirmed = try await rig.workflows.keepICloudPhotosForAll(items, confirmed: true)
        #expect(confirmed.applied.count == 21 && confirmed.needsConfirmation == nil)
    }

    @Test("Deleting photos from Google in bulk is guarded by the lower delete limit")
    func bulkDeleteGuard() async throws {
        let rig = try await PhotoReviewRig.linked(count: 30)
        defer { rig.photos.cleanUp() }
        for index in 1...6 { try await rig.photos.setICloudPhoto("I\(index)", one) }
        try await rig.photos.sync()
        for index in 1...6 { try await rig.photos.setICloudPhoto("I\(index)", nil) }
        try await rig.removalSeenTwice()
        let items = try rig.items()
        try #require(items.count == 6)

        let asked = try await rig.workflows.keepICloudPhotosForAll(items)
        #expect(asked.needsConfirmation?.contains("remove 6 of 30 contact photos from Google") == true)
        let stillThere = await rig.photos.googlePhoto(1)
        #expect(stillThere != nil)
        let confirmed = try await rig.workflows.keepICloudPhotosForAll(items, confirmed: true)
        #expect(confirmed.applied.count == 6)
    }

    @Test("At most 60 Google photo writes happen per bulk action; the rest stay in the list")
    func bulkCarries() async throws {
        let rig = try await PhotoReviewRig.linked(count: 62)
        defer { rig.photos.cleanUp() }
        for index in 1...62 {
            try await rig.photos.setICloudPhoto("I\(index)", one)
            try await rig.photos.setGooglePhoto(index, two)
        }
        let items = try await rig.ask()
        try #require(items.count == 62)

        let report = try await rig.workflows.keepICloudPhotosForAll(items, confirmed: true)
        #expect(report.applied.count == 60 && report.carried.count == 2)
        #expect(try rig.items().count == 2)
    }

    // MARK: the engine's list

    @Test("The list names the kind of photo question, and hides them all while photo sync is off (without deleting them)")
    func listHidesWhenOff() async throws {
        let photos = try await PhotoRig.linked(count: 2)
        defer { photos.cleanUp() }
        let support = SyncPhotoSupport(fetcher: photos.fetcher, history: photos.photoHistory, sleep: { _ in })
        let engine = EngineRig(photos.base, photos: support)
        try await photos.setICloudPhoto("I1", one)
        try await photos.setGooglePhoto(1, two)
        _ = await engine.startAndRun()

        var snapshot = await engine.snapshot
        #expect(snapshot.reviewItems.map(\.kind) == [.photoConflict] && snapshot.reviewItems.first?.photoReason == .firstSightDiffers)

        try photos.base.stateStore.update { $0.syncPhotos = false }
        await engine.engine.syncNow()
        snapshot = await engine.snapshot
        #expect(snapshot.reviewItems.isEmpty)
        #expect(try photos.base.reviews.load().map(\.kind) == [.photoConflict], "kept, not deleted")

        try photos.base.stateStore.update { $0.syncPhotos = true }
        await engine.engine.syncNow()
        snapshot = await engine.snapshot
        #expect(snapshot.reviewItems.count == 1)
        await engine.engine.stop()
    }
}
