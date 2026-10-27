import Foundation
import Testing
@testable import ContactBridgeCore

struct PhotoExecutorTests {
    private let one = PhotoPictures.picture(1)
    private let two = PhotoPictures.picture(2)

    private func ops(_ rig: PhotoRig, _ trigger: SyncTrigger = .syncNow, planner: SyncPlanner? = nil) async throws -> [PlannedPhotoOp] {
        let plan = try await rig.look(trigger, fullListing: true, planner: planner).plan
        try #require(plan.pause == nil)
        return plan.photoOps
    }

    private func googleKey(_ rig: PhotoRig, _ index: Int) async throws -> String? {
        GooglePersonMapper.photos(of: try await rig.base.googlePerson("people/c\(index)")).contact?.key
    }

    /// I1 and c1 hold the same picture and have been looked at: the pair's baseline is settled.
    private func settledRig(count: Int = 3) async throws -> PhotoRig {
        let rig = try await PhotoRig.linked(count: count)
        try await rig.setICloudPhoto("I1", one)
        try await rig.sync()
        try #require(try rig.photoBaseline("I1")?.google != nil)
        return rig
    }

    // MARK: to Google

    @Test("An iCloud photo is uploaded to Google as a JPEG of at most 1024 px, and the baseline records Google's new URL key")
    func copyToGoogle() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        let big = PhotoTestImages.jpeg(PhotoTestImages.scene(seed: 4, width: 1600, height: 1200))
        try await rig.setICloudPhoto("I1", big)
        let etagBefore = try rig.state.baselines["I1"]?.googleEtag

        let report = try await rig.executor().execute(try await ops(rig))
        #expect(report.copiedToGoogle == 1 && report.recorded == 1 && report.isComplete && report.googleWrites == 1)
        let uploaded = try #require(await rig.googlePhoto(1))
        let size = PhotoTestImages.pixelSize(of: uploaded)
        #expect(max(size.width, size.height) <= 1024 && uploaded != big)
        #expect(await rig.google.photoWrites == [FakeGoogleClient.PhotoWrite(resourceName: "people/c1", bytes: uploaded)])

        let baseline = try #require(try rig.photoBaseline("I1"))
        let key = try await googleKey(rig, 1)
        #expect(baseline.googleURLKey == key && baseline.icloudHint == PhotoHash.sha256Hex(big))
        #expect(try rig.state.baselines["I1"]?.googleEtag == etagBefore, "the field baseline is not touched; the next plan refreshes its etag")
        #expect(try rig.photoHistory.entries().isEmpty, "nothing was replaced")
    }

    @Test("Replacing a Google photo saves the old one to the history first")
    func replaceSavesOldPhoto() async throws {
        let rig = try await settledRig()
        defer { rig.cleanUp() }
        let old = try #require(await rig.googlePhoto(1))
        let oldKey = try await googleKey(rig, 1)
        try await rig.setICloudPhoto("I1", two)

        let report = try await rig.executor().execute(try await ops(rig))
        #expect(report.copiedToGoogle == 1)
        let entry = try #require(try rig.photoHistory.entries().first)
        #expect(entry.operation == .replace && entry.icloudID == "I1" && entry.resourceName == "people/c1" && entry.photo == old && entry.urlKey == oldKey)
        #expect(await rig.googlePhoto(1) != old)
    }

    @Test("If the old photo cannot be saved, it is not replaced")
    func oldPhotoUnsavable() async throws {
        let rig = try await settledRig()
        defer { rig.cleanUp() }
        let old = try #require(await rig.googlePhoto(1))
        try await rig.setICloudPhoto("I1", two)
        let planned = try await ops(rig)
        await rig.fetcher.failNext(with: .http(500))

        let report = try await rig.executor().execute(planned)
        #expect(report.copiedToGoogle == 0 && report.skipped.count == 1 && !report.isComplete)
        guard case .couldNotSaveOld? = report.skipped.first?.reason else {
            Issue.record("expected couldNotSaveOld")
            return
        }
        let after = await rig.googlePhoto(1)
        let history = try rig.photoHistory.entries()
        #expect(after == old && history.isEmpty)
    }

    @Test("A Google photo that changed after the plan was made is left alone")
    func googlePhotoMovedSincePlan() async throws {
        let rig = try await settledRig()
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", two)
        let planned = try await ops(rig)
        try await rig.setGooglePhoto(1, PhotoPictures.picture(9))
        let theirs = try #require(await rig.googlePhoto(1))
        let baseline = try rig.photoBaseline("I1")

        let report = try await rig.executor().execute(planned)
        #expect(report.skipped.map(\.reason) == [.googleChanged] && report.copiedToGoogle == 0 && report.isComplete)
        let kept = await rig.googlePhoto(1)
        let baselineAfter = try rig.photoBaseline("I1")
        #expect(kept == theirs && baselineAfter == baseline)
    }

    @Test("An iCloud photo that changed after the plan was made is not uploaded")
    func icloudPhotoMovedSincePlan() async throws {
        let rig = try await settledRig()
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", two)
        let planned = try await ops(rig)
        try await rig.setICloudPhoto("I1", PhotoPictures.picture(9))

        let report = try await rig.executor().execute(planned)
        let writes = await rig.google.photoWrites.count
        #expect(report.skipped.map(\.reason) == [.icloudChanged] && writes == 1, "only the first sync's upload")
    }

    @Test("A photo delete on Google saves the old photo, removes it and clears the key in the baseline")
    func deleteOnGoogle() async throws {
        let rig = try await settledRig()
        defer { rig.cleanUp() }
        let old = try #require(await rig.googlePhoto(1))
        var baseline = try #require(try rig.photoBaseline("I1"))
        let key = try await googleKey(rig, 1)
        baseline.icloud = nil
        baseline.icloudHint = nil
        let op = PlannedPhotoOp(icloudID: "I1", resourceName: "people/c1", kind: .deleteOnGoogle, baseline: baseline, expectedGoogleURLKey: key)

        let report = try await rig.executor().execute([op])
        #expect(report.removedFromGoogle == 1 && report.googleWrites == 1)
        #expect(await rig.googlePhoto(1) == nil)
        let entry = try #require(try rig.photoHistory.entries().first)
        #expect(entry.operation == .delete && entry.photo == old)
        #expect(try rig.photoBaseline("I1")?.googleURLKey == nil && rig.photoBaseline("I1")?.icloud == nil)
    }

    // MARK: to iCloud

    @Test("A Google photo goes into iCloud as the bytes Google served at 1024 px, behind a fresh backup, and the iCloud token follows")
    func copyToICloud() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setGooglePhoto(2, two)
        let planned = try await ops(rig)

        let report = try await rig.executor().execute(planned)
        #expect(report.copiedToICloud == 1 && report.isComplete && report.googleWrites == 0)
        let icloudBytes = try await rig.icloudPhoto("I2")
        let googleBytes = await rig.googlePhoto(2)
        #expect(icloudBytes != nil && icloudBytes == googleBytes)
        let requested = try #require(await rig.fetcher.requested.last)
        #expect(requested.absoluteString.hasSuffix("=s1024"))
        #expect(rig.base.backupFolders() == 1 && rig.store.mutationLog.last?.kind == .photo)
        #expect(await rig.google.photoWrites.isEmpty)

        let baseline = try #require(try rig.photoBaseline("I2"))
        let served = try #require(await rig.googlePhoto(2))
        #expect(baseline.icloudHint == PhotoHash.sha256Hex(served))
        let token = try await rig.store.changeToken()
        #expect(try rig.state.icloudChangeToken == token, "the app's own write is not read as an edit next time")
        #expect(try await rig.look().scan.status == .unchanged)
    }

    @Test("The iCloud token is left alone when a field conflict is open, as after any other iCloud write of the app")
    func tokenHeldWhileConflictOpen() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setGooglePhoto(2, two)
        let planned = try await ops(rig)
        let before = try rig.state.icloudChangeToken
        try rig.base.reviews.add([ReviewCandidate(kind: .bothEdited, icloudID: "I1", resourceName: "people/c1", fields: [.nickname])], at: SyncFixtures.t0)

        _ = try await rig.executor().execute(planned)
        #expect(try rig.state.icloudChangeToken == before)
    }

    @Test("An iCloud photo that changed after the plan was made is not replaced")
    func icloudMovedBeforeCopyToICloud() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setGooglePhoto(2, two)
        let planned = try await ops(rig)
        try await rig.setICloudPhoto("I2", PhotoPictures.picture(9))
        let theirs = try await rig.icloudPhoto("I2")

        let report = try await rig.executor().execute(planned)
        let kept = try await rig.icloudPhoto("I2")
        #expect(report.skipped.map(\.reason) == [.icloudChanged] && kept == theirs)
    }

    @Test("A profile photo is copied to iCloud with origin googleProfile, and nothing is written to Google")
    func profileCopy() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try rig.base.stateStore.update { $0.useGoogleProfilePhotos = true }
        try await rig.setGoogleProfile(1, two)
        let planned = try await ops(rig)

        let report = try await rig.executor().execute(planned)
        let copied = try await rig.icloudPhoto("I1")
        let writes = await rig.google.photoWrites
        let onGoogle = await rig.googlePhoto(1)
        #expect(report.copiedToICloud == 1 && report.googleWrites == 0 && copied != nil)
        #expect(writes.isEmpty && onGoogle == nil)

        let baseline = try #require(try rig.photoBaseline("I1"))
        #expect(baseline.icloudOrigin == .googleProfile && baseline.google == nil && baseline.googleProfileKey != nil)
    }

    @Test("A photo delete in iCloud removes it and clears the hint")
    func deleteOnICloud() async throws {
        let rig = try await settledRig()
        defer { rig.cleanUp() }
        var baseline = try #require(try rig.photoBaseline("I1"))
        let hint = baseline.icloudHint
        baseline.google = nil
        baseline.googleURLKey = nil
        let op = PlannedPhotoOp(icloudID: "I1", resourceName: "people/c1", kind: .deleteOnICloud, baseline: baseline, expectedICloudHint: hint)

        let report = try await rig.executor().execute([op])
        let removed = try await rig.icloudPhoto("I1")
        let hintAfter = try rig.photoBaseline("I1")?.icloudHint
        #expect(report.removedFromICloud == 1 && removed == nil && hintAfter == nil)
    }

    // MARK: pacing, limits, failures

    @Test("Google writes are at least a second apart")
    func pacing() async throws {
        let rig = try await PhotoRig.linked(count: 4)
        defer { rig.cleanUp() }
        for id in ["I1", "I2", "I3"] { try await rig.setICloudPhoto(id, one) }
        let report = try await rig.executor().execute(try await ops(rig))
        #expect(report.copiedToGoogle == 3 && rig.sleeps == [1, 1], "the clock stood still, so each later write waited a full second")
    }

    @Test("At most 60 Google photo writes happen in a run; the rest are carried and the run is not complete")
    func perRunLimit() async throws {
        let rig = try await PhotoRig.linked(count: 62)
        defer { rig.cleanUp() }
        for index in 1...62 { try await rig.setICloudPhoto("I\(index)", one) }
        var planner = SyncPlanner()
        planner.limits.minPhotoWrites = 1000
        planner.limits.maxGooglePhotoWrites = 1000
        let planned = try await ops(rig, planner: planner)
        #expect(planned.count == 62)

        let report = try await rig.executor().execute(planned)
        #expect(report.copiedToGoogle == 60 && report.carried == 2 && !report.isComplete && report.skipped.isEmpty)
        #expect(rig.sleeps.count == 59)
        #expect(PhotoExecutor.maxGoogleWrites == 60)
    }

    @Test("A rate limit stops the run: the failed op is noted and the rest are not attempted")
    func rateLimited() async throws {
        let rig = try await PhotoRig.linked(count: 3)
        defer { rig.cleanUp() }
        for id in ["I1", "I2", "I3"] { try await rig.setICloudPhoto(id, one) }
        await rig.google.inject(.rateLimited(), on: .updateContactPhoto)

        let report = try await rig.executor().execute(try await ops(rig))
        #expect(report.halted != nil && report.googleWrites == 0 && !report.isComplete)
        #expect(report.skipped.count == 3)
        guard case .failed? = report.skipped.first?.reason, case .notAttempted? = report.skipped.last?.reason else {
            Issue.record("expected the first op to fail and the others not to be attempted")
            return
        }
        #expect(try rig.photoBaseline("I1") == nil)
    }

    @Test("An op for a pair that is no longer linked is skipped; a recorded baseline leaves the rest of the baseline alone")
    func notLinkedAndRecorded() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        let before = try #require(try rig.state.baselines["I1"])
        let marker = PhotoBaseline(icloudHint: "x", syncedAt: SyncFixtures.t0)
        let stray = PlannedPhotoOp(icloudID: "I9", resourceName: "people/c9", kind: .recordBaseline, baseline: marker)
        let record = PlannedPhotoOp(icloudID: "I1", resourceName: "people/c1", kind: .recordBaseline, baseline: marker)

        let report = try await rig.executor().execute([stray, record])
        #expect(report.recorded == 1 && report.skipped.map(\.reason) == [.notLinked] && report.isComplete)
        var after = try #require(try rig.state.baselines["I1"])
        #expect(after.photo == marker)
        after.photo = nil
        #expect(after == before)
    }

    @Test("A first look at many pairs records every baseline in one save, and a write saves the records pending with it")
    func recordsSavedTogether() async throws {
        let rig = try await PhotoRig.linked(count: 12)
        defer { rig.cleanUp() }
        let planned = try await ops(rig)
        try #require(planned.count == 12 && planned.allSatisfy { $0.kind == .recordBaseline })
        let counting = FlakyStateStore(rig.base.stateStore)

        let report = try await rig.executor(state: counting).execute(planned)
        #expect(report.recorded == 12 && report.isComplete && counting.writeCount == 1)
        #expect(try (1...12).allSatisfy { try rig.photoBaseline("I\($0)") != nil })

        try await rig.setICloudPhoto("I1", one)
        let edited = try await ops(rig)
        let uploads = FlakyStateStore(rig.base.stateStore)
        let again = try await rig.executor(state: uploads).execute(edited)
        #expect(again.copiedToGoogle == 1 && uploads.writeCount == 1)
        #expect(try rig.photoBaseline("I1")?.google != nil)
    }

    // MARK: crashes

    @Test("A crash between the Google write and the baseline update: the next run records the baseline, writes nothing twice, asks nothing")
    func crashAfterGoogleWrite() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", one)
        let planned = try await ops(rig)
        let flaky = FlakyStateStore(rig.base.stateStore)
        flaky.failWrites(true)

        await #expect(throws: FlakyStateStore.WriteFailure.self) { try await rig.executor(state: flaky).execute(planned) }
        let writes = await rig.google.photoWrites.count
        let baselineAfter = try rig.photoBaseline("I1")
        #expect(writes == 1 && baselineAfter == nil)
        flaky.failWrites(false)

        let again = try await rig.look(.syncNow, fullListing: true).plan
        #expect(again.review.filter { $0.kind == .photoConflict }.isEmpty)
        #expect(again.photoOps.map(\.kind) == [.recordBaseline, .recordBaseline])
        let report = try await rig.executor().execute(again.photoOps)
        let writesAfter = await rig.google.photoWrites.count
        #expect(report.recorded == 2 && report.googleWrites == 0 && writesAfter == 1)
        #expect(try rig.photoBaseline("I1")?.google != nil)
    }

    @Test("The same after an edit: iCloud changed, Google was written, the baseline was not")
    func crashAfterGoogleWriteWithBaseline() async throws {
        let rig = try await settledRig()
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", two)
        let planned = try await ops(rig)
        let flaky = FlakyStateStore(rig.base.stateStore)
        flaky.failWrites(true)
        await #expect(throws: FlakyStateStore.WriteFailure.self) { try await rig.executor(state: flaky).execute(planned) }
        flaky.failWrites(false)
        let writes = await rig.google.photoWrites.count

        let again = try await rig.look(.syncNow, fullListing: true).plan
        #expect(again.review.filter { $0.kind == .photoConflict }.isEmpty)
        #expect(!again.photoOps.contains { $0.icloudID == "I1" && $0.kind != .recordBaseline })
        _ = try await rig.executor().execute(again.photoOps)
        #expect(await rig.google.photoWrites.count == writes)
    }

    @Test("A crash between the iCloud write and the baseline update converges the same way")
    func crashAfterICloudWrite() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setGooglePhoto(2, two)
        let planned = try await ops(rig).filter { $0.icloudID == "I2" }
        let flaky = FlakyStateStore(rig.base.stateStore)
        flaky.failWrites(true)

        await #expect(throws: FlakyStateStore.WriteFailure.self) { try await rig.executor(state: flaky).execute(planned) }
        let written = try await rig.icloudPhoto("I2")
        let baselineAfter = try rig.photoBaseline("I2")
        #expect(written != nil && baselineAfter == nil)
        flaky.failWrites(false)
        let writes = rig.store.mutationLog.count

        let again = try await rig.look(.syncNow, fullListing: true).plan
        #expect(again.review.filter { $0.kind == .photoConflict }.isEmpty && again.photoOps.allSatisfy { $0.kind == .recordBaseline })
        _ = try await rig.executor().execute(again.photoOps)
        let recorded = try rig.photoBaseline("I2")?.icloud
        #expect(rig.store.mutationLog.count == writes && recorded != nil)
    }
}
