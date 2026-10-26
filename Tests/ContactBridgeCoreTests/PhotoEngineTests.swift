import Foundation
import Testing
@testable import ContactBridgeCore

/// Photo sync through the real engine: observe, plan, field writes, photo writes, tokens, confirmations and follow-ups.
struct PhotoEngineTests {
    private let one = PhotoPictures.picture(1)
    private let two = PhotoPictures.picture(2)

    private struct Setup {
        var photos: PhotoRig
        var engine: EngineRig
    }

    private func setup(count: Int = 3, planner: SyncPlanner = SyncPlanner()) async throws -> Setup {
        let photos = try await PhotoRig.linked(count: count)
        let support = SyncPhotoSupport(fetcher: photos.fetcher, history: photos.photoHistory, sleep: { _ in })
        return Setup(photos: photos, engine: EngineRig(photos.base, planner: planner, photos: support))
    }

    @Test("Photos go each way in a run, the summary says so, and a second run changes nothing and reads no picture")
    func flowsBothWaysAndSettles() async throws {
        let rig = try await setup()
        defer { rig.photos.cleanUp() }
        try await rig.photos.setICloudPhoto("I1", one)
        try await rig.photos.setGooglePhoto(2, two)
        try await rig.photos.setICloudPhoto("I3", PhotoPictures.picture(3))
        try await rig.photos.setGooglePhoto(3, PhotoPictures.picture(4))
        _ = await rig.engine.startAndRun()

        let snapshot = await rig.engine.snapshot
        let run = try #require(snapshot.lastRun)
        #expect(run.photosToGoogle == 1 && run.photosToICloud == 1 && run.text == "Copied 1 photo to Google, 1 to iCloud.")
        let onGoogle = await rig.photos.googlePhoto(1)
        let onICloud = try await rig.photos.icloudPhoto("I2")
        #expect(onGoogle != nil && onICloud != nil)
        let conflicts = try rig.photos.base.reviews.load().filter { $0.kind == .photoConflict }
        #expect(conflicts.map(\.id) == ["photoConflict|I3|people/c3"] && conflicts.first?.photoReason == .firstSightDiffers)
        #expect(snapshot.reviewItems.map(\.kind) == [.photoConflict])
        #expect(try rig.engine.state.baselines.values.allSatisfy { $0.photo != nil } == false, "the pair with a question has no baseline yet")

        // The timer's run: iCloud is unchanged (our own write moved the token, and it was stepped past), nothing is read.
        let reads = rig.photos.store.photoReads
        let requested = await rig.photos.fetcher.requested.count
        await rig.engine.advance(899)
        await rig.engine.advance(1)
        await rig.engine.clock.waitForSleepers(2)
        await rig.engine.advance(10)
        await rig.engine.engine.waitForRuns(2)
        let after = rig.photos.store.photoReads
        let downloads = await rig.photos.fetcher.requested.count
        let writes = await rig.photos.google.photoWrites.count
        #expect(after.data == reads.data && after.signatures == reads.signatures && downloads == requested)
        #expect(writes == 1)
        await rig.engine.engine.stop()
    }

    @Test("More than the limit of photo writes asks first; confirming writes them once, and the next run does not ask again")
    func confirmation() async throws {
        let rig = try await setup(count: 30)
        defer { rig.photos.cleanUp() }
        for index in 1...21 { try await rig.photos.setICloudPhoto("I\(index)", one) }
        _ = await rig.engine.startAndRun()

        let paused = await rig.engine.snapshot
        guard case .paused(.needsConfirmation(let summary)) = paused.status else {
            Issue.record("expected a confirmation pause, got \(paused.status)")
            return
        }
        #expect(summary.contains("write 21 of 30 contact photos to Google") && paused.confirmationSummary == summary)
        #expect(await rig.photos.google.photoWrites.isEmpty)

        await rig.engine.engine.confirmAndContinue()
        let done = await rig.engine.snapshot
        #expect(done.status == .idle && done.lastRun?.photosToGoogle == 21)
        #expect(await rig.photos.google.photoWrites.count == 21)

        await rig.engine.engine.syncNow()
        let again = await rig.engine.snapshot
        let writes = await rig.photos.google.photoWrites.count
        #expect(again.status == .idle && writes == 21 && again.lastRun?.didAnything == false)
        await rig.engine.engine.stop()
    }

    @Test("A photo write that fails for a moment keeps the run's tokens where they were, so the next run does it")
    func transientFailureRestoresTokens() async throws {
        let rig = try await setup(count: 2)
        defer { rig.photos.cleanUp() }
        let tokensBefore = try rig.engine.state
        try await rig.photos.setICloudPhoto("I1", one)
        await rig.photos.google.inject(.error(.other(status: 500, message: "try later")), on: .updateContactPhoto)
        _ = await rig.engine.startAndRun()

        let first = await rig.engine.snapshot
        #expect(first.lastRun?.photosToGoogle == 0 && first.lastRun?.leftForNextRun == 1)
        let held = try rig.engine.state
        #expect(held.icloudChangeToken == tokensBefore.icloudChangeToken && held.googleSyncToken == tokensBefore.googleSyncToken)
        #expect(await rig.photos.googlePhoto(1) == nil)

        await rig.engine.engine.syncNow()
        #expect(await rig.photos.googlePhoto(1) != nil)
        let settled = try rig.engine.state
        #expect(settled.icloudChangeToken != tokensBefore.icloudChangeToken)
        await rig.engine.engine.stop()
    }

    @Test("A new contact created in Google gets its photo in the follow-up run the engine asks for")
    func followUpAfterCreate() async throws {
        let rig = try await setup(count: 2)
        defer { rig.photos.cleanUp() }
        let carol = try await rig.photos.base.addICloudContact("Carol", "Newman", phone: "415-555-0100", note: "n")
        try await rig.photos.setICloudPhoto(carol.sourceIdentifier, one)
        _ = await rig.engine.startAndRun()
        #expect(await rig.engine.snapshot.lastRun?.created == 1)
        let carolPerson = try #require(await rig.photos.base.taggedPeople(carol.sourceIdentifier).first)
        #expect(GooglePersonMapper.photos(of: carolPerson).contact == nil, "the first run only created her")

        await rig.engine.clock.waitForSleepers(2) // the timer, and the follow-up's debounce
        await rig.engine.advance(10)
        let after = try #require(await rig.photos.base.taggedPeople(carol.sourceIdentifier).first)
        #expect(GooglePersonMapper.photos(of: after).contact != nil)
        #expect(await rig.engine.snapshot.lastRun?.photosToGoogle == 1)
        await rig.engine.engine.stop()
    }

    @Test("The first-sync preview lists the photos it would copy, and approving still goes through with the same counts")
    func previewShowsPhotos() async throws {
        let rig = try await setup(count: 2)
        defer { rig.photos.cleanUp() }
        try rig.photos.base.stateStore.update { $0.firstSyncApproved = false }
        try await rig.photos.setICloudPhoto("I1", one)
        await rig.engine.start()
        await rig.engine.engine.refreshPreview()

        let preview = try #require(await rig.engine.snapshot.preview)
        #expect(preview.photos.map(\.name) == ["First1 Last1"] && preview.counts.photo == 1 && !preview.isEmpty)
        #expect(await rig.photos.googlePhoto(1) == nil, "a preview writes nothing")

        #expect(await rig.engine.engine.approveFirstSync() == .started)
        #expect(await rig.photos.googlePhoto(1) != nil)
        await rig.engine.engine.stop()
    }

    @Test("A removal is asked about only when it is still there on a later run, five minutes on")
    func removalNeedsTwoRuns() async throws {
        let rig = try await setup(count: 2)
        defer { rig.photos.cleanUp() }
        try await rig.photos.setICloudPhoto("I1", one)
        _ = await rig.engine.startAndRun()
        try await rig.photos.setICloudPhoto("I1", nil)

        await rig.engine.engine.syncNow()
        #expect(try rig.photos.base.reviews.load().isEmpty && rig.photos.photoBaseline("I1")?.pendingRemoval != nil)
        rig.engine.clock.advance(by: 360)
        await rig.engine.engine.syncNow()
        let items = try rig.photos.base.reviews.load()
        #expect(items.map(\.photoReason) == [.removedInICloud])
        let onGoogle = await rig.photos.googlePhoto(1)
        let onICloud = try await rig.photos.icloudPhoto("I1")
        #expect(onGoogle != nil && onICloud == nil, "nothing is mirrored")
        await rig.engine.engine.stop()
    }

    @Test("With profile photos on, Google is listed in full when the last full listing is over a day old, and not before")
    func profileFullListing() async throws {
        let stale = try await setup(count: 2)
        defer { stale.photos.cleanUp() }
        try stale.photos.base.stateStore.update {
            $0.useGoogleProfilePhotos = true
            $0.lastPhotoFullListingAt = SyncFixtures.t0.addingTimeInterval(-25 * 3600)
        }
        _ = await stale.engine.startAndRun()
        #expect(try stale.engine.state.lastPhotoFullListingAt == SyncFixtures.t0)
        await stale.engine.engine.stop()

        let recent = try await setup(count: 2)
        defer { recent.photos.cleanUp() }
        let listed = SyncFixtures.t0.addingTimeInterval(-3600)
        try recent.photos.base.stateStore.update {
            $0.useGoogleProfilePhotos = true
            $0.lastPhotoFullListingAt = listed
        }
        _ = await recent.engine.startAndRun()
        #expect(try recent.engine.state.lastPhotoFullListingAt == listed)
        await recent.engine.engine.stop()
    }

    @Test("A profile photo reaches iCloud through a run, and the contact stays out of Google")
    func profilePhotoThroughEngine() async throws {
        let rig = try await setup(count: 2)
        defer { rig.photos.cleanUp() }
        try rig.photos.base.stateStore.update { $0.useGoogleProfilePhotos = true }
        try await rig.photos.setGoogleProfile(1, two)
        _ = await rig.engine.startAndRun()

        let copied = try await rig.photos.icloudPhoto("I1")
        let writes = await rig.photos.google.photoWrites
        #expect(copied != nil && writes.isEmpty)
        #expect(try rig.photos.photoBaseline("I1")?.icloudOrigin == .googleProfile)
        await rig.engine.engine.stop()
    }

    @Test("With photo sync off a run touches no photo and keeps what is stored")
    func switchedOff() async throws {
        let rig = try await setup(count: 2)
        defer { rig.photos.cleanUp() }
        try await rig.photos.setICloudPhoto("I1", one)
        try rig.photos.base.stateStore.update { $0.syncPhotos = false }
        let reads = rig.photos.store.photoReads
        _ = await rig.engine.startAndRun()

        #expect(rig.photos.store.photoReads.data == reads.data && rig.photos.store.photoReads.signatures == reads.signatures)
        let writes = await rig.photos.google.photoWrites
        let downloads = await rig.photos.fetcher.requested
        #expect(writes.isEmpty && downloads.isEmpty)
        await rig.engine.engine.stop()
    }
}
