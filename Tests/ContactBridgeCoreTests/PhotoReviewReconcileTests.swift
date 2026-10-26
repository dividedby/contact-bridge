import Foundation
import Testing
@testable import ContactBridgeCore

/// How the review list keeps photo questions in step with a plan.
struct PhotoReviewReconcileTests {
    private let t0 = SyncFixtures.t0

    private func photoItem(_ id: String = "I1", _ name: String = "people/c1") -> ReviewItem {
        ReviewItem(
            candidate: ReviewCandidate(kind: .photoConflict, icloudID: id, resourceName: name, photoStamp: "h|k", photoReason: .bothChanged),
            pinned: false, at: t0
        )
    }

    private func fieldItem(_ id: String = "I1") -> ReviewItem {
        ReviewItem(candidate: ReviewCandidate(kind: .googleEdited, icloudID: id, resourceName: "people/c1", fields: [.nickname]), pinned: false, at: t0)
    }

    private func plan(reviewComplete: Bool = false, photoComplete: Bool = false) -> SyncPlan {
        var plan = SyncPlan(isPreview: false)
        plan.reviewIsComplete = reviewComplete
        plan.photoReviewIsComplete = photoComplete
        return plan
    }

    @Test("A photo question about a contact that is gone is removed, even when the plan did not look at every photo")
    func goneContact() {
        var list = ReviewList(items: [photoItem("I1"), photoItem("I2", "people/c2")])
        var gone = plan()
        gone.droppedLinks = ["I1"]
        let result = list.reconcile(with: gone, ignoredGoogle: [], at: t0)
        #expect(result.removed == ["photoConflict|I1|people/c1"] && list.items.map(\.icloudID) == ["I2"])

        var deleted = plan()
        deleted.review = [ReviewCandidate(kind: .deletedInGoogle, icloudID: "I2", resourceName: "people/c2")]
        _ = list.reconcile(with: deleted, ignoredGoogle: [], at: t0)
        #expect(list.items.filter { $0.kind == .photoConflict }.isEmpty)
    }

    @Test("An absent photo question is removed only when the plan looked at every photo")
    func absentPhotoQuestion() {
        var list = ReviewList(items: [photoItem()])
        _ = list.reconcile(with: plan(reviewComplete: true, photoComplete: false), ignoredGoogle: [], at: t0)
        #expect(list.items.count == 1, "the field review being complete says nothing about photos")
        _ = list.reconcile(with: plan(reviewComplete: false, photoComplete: true), ignoredGoogle: [], at: t0)
        #expect(list.items.isEmpty)
    }

    @Test("A field question is not removed by photo completeness, and a photo question that is still derived stays")
    func kindsAreIndependent() {
        var list = ReviewList(items: [fieldItem(), photoItem()])
        var derived = plan(reviewComplete: false, photoComplete: true)
        derived.review = [ReviewCandidate(kind: .photoConflict, icloudID: "I1", resourceName: "people/c1", photoStamp: "h|k2", photoReason: .bothChanged)]
        let result = list.reconcile(with: derived, ignoredGoogle: [], at: t0)
        #expect(list.items.count == 2 && result.refreshed == ["photoConflict|I1|people/c1"])
        #expect(list.items.first { $0.kind == .photoConflict }?.photoStamp == "h|k2")
    }

    @Test("With photo sync off the plan looks at no photo, so stored photo questions are kept")
    func switchedOff() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try rig.base.stateStore.update { $0.syncPhotos = false }
        let plan = try await rig.look(.syncNow, fullListing: true).plan
        #expect(plan.reviewIsComplete && !plan.photoReviewIsComplete)

        var list = ReviewList(items: [photoItem()])
        _ = list.reconcile(with: plan, ignoredGoogle: [], at: t0)
        #expect(list.items.count == 1)
    }
}
