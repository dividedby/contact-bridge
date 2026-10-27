import Foundation
import Testing
@testable import ContactBridgeCore

/// What the photo phase does with failures: a halt stops the run like any other, permanent failures are remembered on the
/// pair and left alone until a photo changes, and transient ones are tried again without piling up history.
struct PhotoFailureTests {
    private let one = PhotoPictures.picture(1)
    private let two = PhotoPictures.picture(2)
    private let garbage = Data("not a picture".utf8)

    private func ops(_ rig: PhotoRig) async throws -> [PlannedPhotoOp] {
        let plan = try await rig.look(.syncNow, fullListing: true).plan
        try #require(plan.pause == nil)
        return plan.photoOps
    }

    private func engine(count: Int = 2) async throws -> (photos: PhotoRig, engine: EngineRig) {
        let photos = try await PhotoRig.linked(count: count)
        let support = SyncPhotoSupport(fetcher: photos.fetcher, history: photos.photoHistory, sleep: { _ in })
        return (photos, EngineRig(photos.base, photos: support))
    }

    // MARK: a halt in the photo phase

    @Test("A rate limit or sign-in problem in the photo phase stops the run: summary, back-off, and no follow-up run", arguments: [
        GoogleAPIError.rateLimited(retryAfter: nil), .unauthorized, .other(status: 403, message: "forbidden"),
    ])
    func photoHaltStopsTheRun(error: GoogleAPIError) async throws {
        let rig = try await engine()
        defer { rig.photos.cleanUp() }
        let carol = try await rig.photos.base.addICloudContact("Carol", "Newman", phone: "415-555-0100", note: "n")
        try await rig.photos.setICloudPhoto(carol.sourceIdentifier, one)  // a new pair: a follow-up would be wanted
        try await rig.photos.setICloudPhoto("I1", two)
        await rig.photos.google.inject(.error(error), on: .updateContactPhoto)
        _ = await rig.engine.startAndRun()

        let snapshot = await rig.engine.snapshot
        #expect(snapshot.lastRun?.created == 1 && snapshot.lastRun?.halted != nil, "the summary says the run stopped")
        #expect(snapshot.nextAttemptAt != nil, "a back-off was registered")
        let quiet = await rig.engine.clock.waitForSleepers(1, timeout: 5)
        #expect(quiet, "only the timer is asleep: no follow-up was asked for")
        await rig.engine.advance(10)
        let runs = await rig.engine.engine.completedRuns
        #expect(runs == 1, "no follow-up straight after the stop")
        await rig.engine.engine.stop()
    }

    @Test("A failure that is tried again says which step failed")
    func transientFailureNamesTheStep() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", one)
        await rig.google.inject(.error(.other(status: 503, message: "busy")), on: .updateContactPhoto)

        let report = try await rig.executor().execute(try await ops(rig))
        let reason = try #require(report.skipped.first { $0.icloudID == "I1" }?.reason)
        let message = try #require(reason.message)
        #expect(message.hasPrefix("Google did not take the photo ("), "\(message)")
        #expect(report.putOffReasons.first?.contains("Google did not take the photo") == true)
    }

    // MARK: permanent failures on a write

    @Test("A photo Google refuses is recorded on the pair, warned about once, and not tried again until a photo changes")
    func permanentUploadFailure() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", one)
        await rig.google.inject(.error(.other(status: 400, message: "bad image")), on: .updateContactPhoto)
        let planned = try await ops(rig)

        let report = try await rig.executor().execute(planned)
        guard case .permanent? = report.skipped.first?.reason else {
            Issue.record("expected a permanent failure")
            return
        }
        #expect(report.isComplete && report.givenUp.count == 1 && report.leftForNextRun == 0 && report.googleWrites == 0)
        let failure = try #require(try rig.photoBaseline("I1")?.failure)
        #expect(failure.stamp == planned.first { $0.icloudID == "I1" }?.failureStamp)

        let again = try await rig.look(.syncNow, fullListing: true).plan
        #expect(!again.photoOps.contains { $0.icloudID == "I1" && $0.kind == .copyToGoogle }, "left alone")
        #expect(again.checkpoint != nil)

        try await rig.setICloudPhoto("I1", two)
        let changed = try await rig.look(.syncNow, fullListing: true).plan
        let retry = try #require(changed.photoOps.first { $0.icloudID == "I1" })
        #expect(retry.kind == .copyToGoogle && retry.baseline.failure == nil)
        let done = try await rig.executor().execute(changed.photoOps)
        let writes = await rig.google.photoWrites.count
        #expect(done.copiedToGoogle == 1 && writes == 1)
        #expect(try rig.photoBaseline("I1")?.failure == nil)
    }

    @Test("A picture this Mac cannot encode for Google is a permanent failure too")
    func undecodableUpload() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", garbage)
        let op = PlannedPhotoOp(
            icloudID: "I1", resourceName: "people/c1", kind: .copyToGoogle, baseline: PhotoBaseline(syncedAt: SyncFixtures.t0),
            expectedICloudHint: PhotoHash.sha256Hex(garbage), failureStamp: "stamp"
        )
        let report = try await rig.executor().execute([op])
        #expect(report.skipped.map(\.reason).count == 1 && report.isComplete)
        #expect(try rig.photoBaseline("I1")?.failure?.stamp == "stamp")
    }

    @Test("An old photo that cannot be fetched for good is not overwritten, and is not tried again")
    func permanentOldPhotoFailure() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", one)
        try await rig.sync()
        try await rig.setICloudPhoto("I1", two)
        let planned = try await ops(rig).filter { $0.icloudID == "I1" }
        try #require(planned.first?.kind == .copyToGoogle)
        await rig.fetcher.failNext(with: .http(404))

        let report = try await rig.executor().execute(planned)
        guard case .permanent? = report.skipped.first?.reason else {
            Issue.record("expected a permanent failure")
            return
        }
        let writes = await rig.google.photoWrites.count
        #expect(report.isComplete && writes == 1, "only the first sync's upload")
        #expect(try rig.photoBaseline("I1")?.failure != nil)
    }

    @Test("A write that keeps failing for a moment saves the old photo to the history once, not once per attempt")
    func historyOncePerOldPhoto() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", one)
        try await rig.sync()
        try await rig.setICloudPhoto("I1", two)
        let planned = try await ops(rig)
        await rig.google.inject(.error(.other(status: 500, message: "try later")), on: .updateContactPhoto, times: 2)

        for _ in 0..<2 {
            let report = try await rig.executor().execute(planned)
            #expect(!report.isComplete && report.copiedToGoogle == 0)
        }
        #expect(try rig.photoHistory.entries().count == 1)
        let report = try await rig.executor().execute(planned)
        #expect(report.copiedToGoogle == 1)
        #expect(try rig.photoHistory.entries().count == 1)
        #expect(try rig.photoBaseline("I1")?.failure == nil)
    }

    @Test("A 409 from Google (a concurrent write) is retried, not remembered as a failure")
    func conflictIsRetried() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", one)
        await rig.google.inject(.error(.other(status: 409, message: "aborted")), on: .updateContactPhoto)
        let planned = try await ops(rig)

        let report = try await rig.executor().execute(planned)
        #expect(!report.isComplete && report.warnings.isEmpty && report.copiedToGoogle == 0)
        #expect(try rig.photoBaseline("I1")?.failure == nil)
        let again = try await rig.executor().execute(planned)
        #expect(again.copiedToGoogle == 1)
    }

    @Test("Classification: refused addresses, bad pictures and 4xx answers are permanent; timeouts, 5xx and rate limits are not")
    func classification() {
        #expect(PhotoErrors.isPermanent(PhotoEncodingError.tooLarge) && PhotoErrors.isPermanent(PhotoEncodingError.undecodable))
        #expect(PhotoErrors.isPermanent(GooglePhotoError.notAllowed("host")) && PhotoErrors.isPermanent(GooglePhotoError.notAnImage))
        #expect(PhotoErrors.isPermanent(GooglePhotoError.tooLarge) && PhotoErrors.isPermanent(GooglePhotoError.http(404)))
        #expect(!PhotoErrors.isPermanent(GooglePhotoError.http(503)) && !PhotoErrors.isPermanent(GooglePhotoError.http(429)))
        #expect(PhotoErrors.isPermanent(GoogleAPIError.other(status: 400, message: "")))
        #expect(!PhotoErrors.isPermanent(GoogleAPIError.other(status: 409, message: "aborted")), "Google's ABORTED is a retry, not a refusal")
        #expect(!PhotoErrors.isPermanent(GoogleAPIError.other(status: 500, message: "")) && !PhotoErrors.isPermanent(URLError(.timedOut)))
        #expect(PhotoErrors.isPermanent(ContactStoreError.photoNotSaved), "a contact whose picture file macOS lost fails every time")
    }

    @Test("Through the engine a permanent failure does not hold the tokens back, so nothing is re-read or retried every run")
    func permanentFailureThroughEngine() async throws {
        let rig = try await engine()
        defer { rig.photos.cleanUp() }
        let before = try rig.engine.state
        try await rig.photos.setICloudPhoto("I1", one)
        await rig.photos.google.inject(.error(.other(status: 400, message: "bad image")), on: .updateContactPhoto)
        _ = await rig.engine.startAndRun()

        let first = await rig.engine.snapshot
        #expect(first.lastRun?.warnings.count == 1 && first.lastRun?.halted == nil)
        let held = try rig.engine.state
        #expect(held.icloudChangeToken != before.icloudChangeToken, "the checkpoint stands")

        await rig.engine.engine.syncNow()
        let second = await rig.engine.snapshot
        let writes = await rig.photos.google.photoWrites
        #expect(second.lastRun?.warnings == first.lastRun?.warnings, "only the listing of the photo left alone")
        #expect(second.lastRun?.leftForNextRun == 0 && writes.isEmpty)
        await rig.engine.engine.stop()
    }

    // MARK: permanent failures on a read

    @Test("A Google photo that is not a picture is recorded, counts as evaluated, and is not downloaded again")
    func unreadableGooglePhoto() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setGooglePhoto(1, garbage)
        let first = try await rig.look(.syncNow)
        #expect(first.observed.unevaluated.isEmpty && first.observed.failures.keys.sorted() == ["I1"])
        #expect(first.plan.photosUnevaluated == 0 && first.plan.checkpoint != nil)
        let marker = try #require(first.plan.photoOps.first { $0.icloudID == "I1" })
        #expect(marker.kind == .recordBaseline && marker.baseline.failure?.stamp.hasPrefix("google:") == true)
        _ = try await rig.executor().execute(first.plan.photoOps)

        let requested = await rig.fetcher.requested.count
        let second = try await rig.look(.syncNow, fullListing: true)
        #expect(second.observed.failures.isEmpty && second.observed.unevaluated.isEmpty && second.observed.pairs["I1"] == nil)
        let after = await rig.fetcher.requested.count
        #expect(after == requested, "not downloaded again")
        #expect(second.plan.checkpoint != nil && second.plan.photoReviewIsComplete)

        // A new photo is read afresh.
        try await rig.setGooglePhoto(1, two)
        let third = try await rig.look(.syncNow, fullListing: true)
        #expect(third.observed.pairs["I1"]?.seen.google != nil && third.observed.failures.isEmpty)
    }

    @Test("A Google photo that is gone (404) is permanent; one that fails with a 503 is only deferred")
    func downloadStatuses() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setGooglePhoto(1, one)
        try await rig.setGooglePhoto(2, one)
        await rig.fetcher.failNext(with: .http(404))
        await rig.fetcher.failNext(with: .http(503))

        let look = try await rig.look(.syncNow)
        #expect(look.observed.failures.count == 1 && look.observed.unevaluated.count == 1)
        #expect(look.plan.checkpoint == nil, "the transient one still holds the checkpoint")
    }

    @Test("An iCloud photo that cannot be decoded is recorded the same way, and not read again")
    func unreadableICloudPhoto() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", garbage)
        let first = try await rig.look(.syncNow)
        #expect(first.observed.failures["I1"]?.stamp == "icloud:" + PhotoHash.sha256Hex(garbage) && first.plan.photosUnevaluated == 0)
        _ = try await rig.executor().execute(first.plan.photoOps)

        let reads = rig.store.photoReads.data
        let second = try await rig.look(.syncNow)
        #expect(second.observed.failures.isEmpty && rig.store.photoReads.data == reads)
    }

    // MARK: stored questions and unreadable photos

    private func question(_ id: String, _ name: String) -> ReviewItem {
        ReviewItem(
            candidate: ReviewCandidate(kind: .photoConflict, icloudID: id, resourceName: name, photoStamp: "h|k", photoReason: .bothChanged),
            pinned: false, at: SyncFixtures.t0
        )
    }

    @Test("A stored photo question survives a run that skipped or could not read its pair; one whose pair was judged is dropped")
    func questionsOfUnjudgedPairsStay() async throws {
        let rig = try await PhotoRig.linked(count: 3)
        defer { rig.cleanUp() }
        try await rig.setGooglePhoto(1, garbage)
        try await rig.setICloudPhoto("I2", garbage)
        let items = [question("I1", "people/c1"), question("I2", "people/c2"), question("I3", "people/c3")]

        // This run cannot read two photos for the first time.
        let first = try await rig.look(.syncNow, fullListing: true)
        try #require(first.plan.photoReviewIsComplete && first.observed.failures.count == 2)
        var list = ReviewList(items: items)
        _ = list.reconcile(with: first.plan, ignoredGoogle: [], at: SyncFixtures.t0)
        #expect(list.items.compactMap(\.icloudID).sorted() == ["I1", "I2"], "I3 was judged, has no question to ask, and goes")

        // The next one skips them, for they failed the same way before.
        _ = try await rig.executor().execute(first.plan.photoOps)
        let second = try await rig.look(.syncNow, fullListing: true)
        try #require(second.plan.photoReviewIsComplete && second.observed.failures.isEmpty && second.observed.pairs.keys.sorted() == ["I3"])
        list = ReviewList(items: items)
        _ = list.reconcile(with: second.plan, ignoredGoogle: [], at: SyncFixtures.t0)
        #expect(list.items.compactMap(\.icloudID).sorted() == ["I1", "I2"])

        // Only the contact being gone takes a question away.
        var gone = second.plan
        gone.droppedLinks = ["I1"]
        _ = list.reconcile(with: gone, ignoredGoogle: [], at: SyncFixtures.t0)
        #expect(list.items.compactMap(\.icloudID) == ["I2"])
    }

    @Test("An unreadable profile photo drops only the profile: Google's own photo still replaces the profile copy in iCloud")
    func unreadableProfilePhoto() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        let fingerprint = try #require(ImageIOPhotoFingerprinter().fingerprint(of: one))
        try rig.base.stateStore.update {
            $0.useGoogleProfilePhotos = true
            $0.baselines["I1"]?.photo = PhotoBaseline(
                icloud: fingerprint, googleProfile: fingerprint, icloudHint: PhotoHash.sha256Hex(one), googleProfileKey: "old-profile-key",
                icloudOrigin: .googleProfile, syncedAt: SyncFixtures.t0
            )
        }
        try await rig.setICloudPhoto("I1", one)
        try await rig.setGoogleProfile(1, garbage)
        try await rig.setGooglePhoto(1, two)

        let look = try await rig.look(.syncNow, fullListing: true)
        #expect(look.observed.pairs["I1"]?.seen.google != nil, "the pair is still judged")
        let failure = try #require(look.observed.failures["I1"])
        #expect(failure.stamp.hasPrefix("profile:"))
        #expect(look.plan.photosUnevaluated == 0)
        let copy = try #require(look.plan.photoOps.first { $0.icloudID == "I1" })
        #expect(copy.kind == .copyToICloud(source: .googleContact) && copy.baseline.icloudOrigin == .user)
        #expect(copy.baseline.failure?.stamp == failure.stamp, "the unreadable profile photo is remembered on the same baseline")
        #expect(look.plan.photoOps.filter { $0.icloudID == "I1" }.count == 1)

        _ = try await rig.executor().execute(look.plan.photoOps)
        let requested = await rig.fetcher.requested.count
        let again = try await rig.look(.syncNow, fullListing: true)
        let after = await rig.fetcher.requested.count
        #expect(again.observed.failures.isEmpty && after == requested, "the profile photo is not downloaded again")
    }

    @Test("Photos given up on are one line per reason naming the contacts, with the rest counted past ten")
    func givenUpLines() {
        let lost = "macOS Contacts could not save this contact's photo"
        let many = (1...12).map { (name: "Person \($0)", message: lost) }
        let lines = PhotoNotice.lines(many + [(name: "Ada", message: "bad image")], couldNotBe: "synced")
        #expect(lines == [
            "A contact photo could not be synced and is left alone until it changes (Ada): bad image",
            "12 contact photos could not be synced and are left alone until a photo changes (Person 1, Person 2, Person 3, Person 4, "
                + "Person 5, Person 6, Person 7, Person 8, Person 9, Person 10 and 2 more): \(lost)",
        ])
        #expect(PhotoNotice.lines([], couldNotBe: "read").isEmpty)
    }

    @Test("A photo given up on is named in every run summary until it changes, and not counted as tried again next run")
    func givenUpInRunSummary() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        let support = SyncPhotoSupport(fetcher: rig.fetcher, history: rig.photoHistory, sleep: { _ in })
        let engine = EngineRig(rig.base, photos: support)
        try await rig.setICloudPhoto("I1", one)
        await rig.google.inject(.error(.other(status: 400, message: "bad image")), on: .updateContactPhoto)
        _ = await engine.startAndRun()

        let run = try #require(await engine.snapshot.lastRun)
        let name = try #require(try rig.state.baselines["I1"]?.icloud.displayName)
        let lines = run.warnings.filter { $0.contains("could not be synced") }
        #expect(lines.count == 1 && lines.first?.contains("(\(name))") == true && lines.first?.contains("bad image") == true)
        #expect(run.leftForNextRun == 0, "a photo given up on is not tried again next run")

        // The next run does not try it again, but still lists it, until a photo changes.
        await engine.engine.syncNow()
        let next = try #require(await engine.snapshot.lastRun)
        #expect(next.warnings.filter { $0.contains("could not be synced") } == lines)
        try await rig.setICloudPhoto("I1", two)
        await engine.engine.syncNow()
        #expect(await engine.snapshot.lastRun?.warnings.contains { $0.contains("could not be synced") } == false)
        await engine.engine.stop()
    }
}
