import Foundation
import Testing
@testable import ContactBridgeCore

/// `SyncPlanner.plan(..., photos:)`: the ops, review candidates, completeness and guards that come out of the observations.
struct PhotoPlannerTests {
    private let picture = PhotoPictures.picture(1)

    /// `count` linked contacts, the first `withPhoto` of which have the same iCloud photo.
    private func rig(count: Int, icloudPhotos: Int = 0, googlePhotos: Int = 0) async throws -> PhotoRig {
        let rig = try await PhotoRig.linked(count: count)
        for index in 0..<icloudPhotos { try await rig.setICloudPhoto("I\(index + 1)", picture) }
        for index in 0..<googlePhotos { try await rig.setGooglePhoto(index + 1, picture) }
        return rig
    }

    private func op(_ plan: SyncPlan, _ id: String) -> PlannedPhotoOp? { plan.photoOps.first { $0.icloudID == id } }

    @Test("First sight plans a copy each way, records agreeing photos and asks about different ones, with stamps and reasons")
    func firstSightPlan() async throws {
        let rig = try await PhotoRig.linked(count: 4)
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", PhotoPictures.picture(1))
        try await rig.setGooglePhoto(2, PhotoPictures.picture(2))
        try await rig.setICloudPhoto("I3", PhotoPictures.picture(3))
        try await rig.setGooglePhoto(3, PhotoPictures.lookAlike(3))
        try await rig.setICloudPhoto("I4", PhotoPictures.picture(4))
        try await rig.setGooglePhoto(4, PhotoPictures.picture(5))

        let plan = try await rig.look(.syncNow, fullListing: true).plan
        #expect(plan.pause == nil && plan.photoReviewIsComplete && plan.photosUnevaluated == 0)

        let toGoogle = try #require(op(plan, "I1"))
        #expect(toGoogle.kind == .copyToGoogle && toGoogle.resourceName == "people/c1")
        #expect(toGoogle.expectedICloudHint == PhotoHash.sha256Hex(PhotoPictures.picture(1)) && toGoogle.expectedGoogleURLKey == nil)
        #expect(toGoogle.baseline.icloud == toGoogle.baseline.google && toGoogle.baseline.icloud != nil)

        let toICloud = try #require(op(plan, "I2"))
        let googleKey = try #require(GooglePersonMapper.photos(of: try await rig.base.googlePerson("people/c2")).contact?.key)
        #expect(toICloud.kind == .copyToICloud(source: .googleContact) && toICloud.expectedGoogleURLKey == googleKey)
        #expect(toICloud.expectedICloudHint == nil)

        #expect(op(plan, "I3")?.kind == .recordBaseline)
        #expect(op(plan, "I4") == nil)
        let conflict = try #require(plan.review.first { $0.kind == .photoConflict })
        let stamp = PhotoHash.sha256Hex(PhotoPictures.picture(4)) + "|" + (try #require(GooglePersonMapper.photos(of: try await rig.base.googlePerson("people/c4")).contact?.key))
        #expect(conflict.id == "photoConflict|I4|people/c4" && conflict.photoReason == .firstSightDiffers && conflict.photoStamp == stamp)
        #expect(conflict.googleEtag == nil && conflict.icloudFingerprint == nil)

        #expect(plan.mutationCount == 1 && plan.googlePhotoWrites == 1 && !plan.isEmpty)
    }

    @Test("The photo review is only complete after a full Google listing and a changed iCloud scan")
    func completeness() async throws {
        let rig = try await rig(count: 2, icloudPhotos: 1)
        defer { rig.cleanUp() }
        let incremental = try await rig.look(.syncNow).plan
        #expect(!incremental.photoReviewIsComplete)
        let token = try await rig.store.changeToken()
        try rig.base.stateStore.update { $0.icloudChangeToken = token }
        let unchanged = try await rig.look(.scheduled, fullListing: true)
        #expect(unchanged.scan.status == .unchanged && !unchanged.plan.photoReviewIsComplete)
        let full = try await rig.look(.syncNow, fullListing: true).plan
        #expect(full.photoReviewIsComplete)
    }

    @Test("A plan with only a recorded baseline is not empty and writes nothing")
    func recordedBaselineOnly() async throws {
        let rig = try await rig(count: 2)
        defer { rig.cleanUp() }
        let plan = try await rig.look().plan
        #expect(plan.photoOps.count == 2 && plan.photoOps.allSatisfy { $0.kind == .recordBaseline })
        #expect(plan.mutationCount == 0 && plan.googlePhotoWrites == 0 && !plan.isEmpty && plan.checkpoint != nil)
    }

    @Test("With photo sync off in the state, observations are ignored: no op, no candidate")
    func planOffWhenSwitchedOff() async throws {
        let rig = try await rig(count: 2, icloudPhotos: 1)
        defer { rig.cleanUp() }
        let look = try await rig.look(.syncNow, fullListing: true)
        var state = try rig.state
        state.syncPhotos = false
        let plan = SyncPlanner().plan(
            icloud: look.scan, google: look.feed, state: state, links: try rig.base.linkStore.load(), photos: look.observed, now: SyncFixtures.t0
        )
        #expect(plan.photoOps.isEmpty && !plan.photoReviewIsComplete)
    }

    // MARK: guards and the per-run limit

    @Test("More than max(20, 25%) Google photo writes pause the plan for confirmation; exactly that many go through")
    func googleWriteGuard() async throws {
        let rig = try await rig(count: 30, icloudPhotos: 21)
        defer { rig.cleanUp() }
        let paused = try await rig.look(.syncNow).plan
        guard case .needsConfirmation(let summary)? = paused.pause else {
            Issue.record("expected a confirmation pause")
            return
        }
        #expect(summary == "This sync would write 21 of 30 contact photos to Google (more than 20 at once)")
        #expect(paused.googlePhotoWrites == 21, "the plan still lists what it would do")

        try await rig.setICloudPhoto("I21", nil)
        #expect(try await rig.look(.syncNow).plan.pause == nil)
    }

    @Test("More than max(20, 25%) photo writes to iCloud pause the plan for confirmation too")
    func icloudWriteGuard() async throws {
        let rig = try await rig(count: 30, googlePhotos: 21)
        defer { rig.cleanUp() }
        let plan = try await rig.look(.syncNow).plan
        guard case .needsConfirmation(let summary)? = plan.pause else {
            Issue.record("expected a confirmation pause")
            return
        }
        #expect(summary == "This sync would change 21 of 30 contact photos in iCloud (more than 20 at once)")
    }

    @Test("The limits scale with the number of linked contacts, and Google photo deletes have their own, lower one")
    func guardArithmetic() {
        func ops(_ kind: PlannedPhotoOp.Kind, _ count: Int) -> [PlannedPhotoOp] {
            (0..<count).map { PlannedPhotoOp(icloudID: "I\($0)", resourceName: "people/c\($0)", kind: kind, baseline: PhotoBaseline(syncedAt: SyncFixtures.t0)) }
        }
        let limits = SyncPlanner.Limits()
        func reasons(_ ops: [PlannedPhotoOp], linked: Int, deferred: Int = 0) -> [String] {
            SyncPlanner.photoGuardReasons(ops: ops, deferredWrites: deferred, linkedCount: linked, limits: limits)
        }
        #expect(reasons(ops(.copyToGoogle, 25), linked: 100).isEmpty && reasons(ops(.copyToGoogle, 26), linked: 100).count == 1)
        #expect(reasons(ops(.copyToGoogle, 20), linked: 10, deferred: 1).count == 1, "writes held back by the per-run limit count")
        #expect(reasons(ops(.deleteOnGoogle, 5), linked: 100).isEmpty)
        #expect(reasons(ops(.deleteOnGoogle, 6), linked: 100) == ["remove 6 of 100 contact photos from Google (more than 5 at once)"])
        #expect(reasons(ops(.deleteOnGoogle, 8), linked: 400).isEmpty && reasons(ops(.deleteOnGoogle, 9), linked: 400).count == 1)
        #expect(reasons(ops(.copyToICloud(source: .googleContact), 21), linked: 100).isEmpty)
        #expect(reasons(ops(.deleteOnICloud, 26), linked: 100).count == 1)
        #expect(reasons(ops(.recordBaseline, 500), linked: 10).isEmpty, "recording a baseline writes nothing")
    }

    @Test("At most 60 Google photo writes go in one run; the rest are held back, and the tokens wait for them")
    func perRunCap() async throws {
        let rig = try await rig(count: 70, icloudPhotos: 70)
        defer { rig.cleanUp() }
        var planner = SyncPlanner()
        planner.limits.minPhotoWrites = 1000
        let plan = try await rig.look(.syncNow, planner: planner).plan

        #expect(plan.pause == nil && plan.googlePhotoWrites == 60 && plan.deferred.photoWrites == 10 && plan.mutationCount == 60)
        #expect(!plan.deferred.isEmpty && plan.checkpoint == nil)
        let kept = plan.photoOps.map(\.icloudID).sorted()
        #expect(kept == (1...70).map { "I\($0)" }.sorted().prefix(60).map { $0 }, "the first 60 by iCloud id")

        // The guard judges the whole plan, held-back writes included.
        let guarded = try await rig.look(.syncNow).plan
        #expect(guarded.needsConfirmation)
    }
}
