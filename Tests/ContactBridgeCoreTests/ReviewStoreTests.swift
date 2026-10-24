import Foundation
import Testing
@testable import ContactBridgeCore

struct ReviewStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_800_003_600)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("review-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func plan(_ candidates: [ReviewCandidate], complete: Bool) -> SyncPlan {
        var plan = SyncPlan(isPreview: false)
        plan.review = candidates
        plan.reviewIsComplete = complete
        return plan
    }

    private let edited = ReviewCandidate(kind: .googleEdited, icloudID: "I1", resourceName: "people/c1", googleEtag: "e1", icloudFingerprint: "f1", fields: [.nickname])
    private let both = ReviewCandidate(kind: .bothEdited, icloudID: "I2", resourceName: "people/c2", googleEtag: "e2", icloudFingerprint: "f2", fields: [.phones])
    private let fresh = ReviewCandidate(kind: .newInGoogle, resourceName: "people/c9", googleEtag: "e9")

    @Test("New candidates are added with their ids, timestamps and details")
    func adds() throws {
        let store = InMemoryReviewStore()
        let result = try store.reconcile(with: plan([edited, fresh], complete: true), at: t0)
        #expect(Set(result.added) == ["googleEdited|I1|people/c1", "newInGoogle||people/c9"] && result.refreshed.isEmpty && result.removed.isEmpty)
        let item = try #require(try store.load().first { $0.id == "googleEdited|I1|people/c1" })
        #expect(item.kind == .googleEdited && item.icloudID == "I1" && item.resourceName == "people/c1")
        #expect(item.googleEtag == "e1" && item.icloudFingerprint == "f1" && item.fields == [.nickname])
        #expect(item.createdAt == t0 && item.updatedAt == t0)
    }

    @Test("The same conflict again changes nothing; a new etag or fingerprint refreshes the item in place")
    func refreshes() throws {
        let store = InMemoryReviewStore()
        try store.reconcile(with: plan([edited], complete: true), at: t0)
        #expect(try store.reconcile(with: plan([edited], complete: true), at: t1).isEmpty)
        #expect(try store.load().first?.updatedAt == t0)

        var moved = edited
        moved.googleEtag = "e2"
        moved.icloudFingerprint = "f2"
        moved.fields = [.nickname, .emails]
        let result = try store.reconcile(with: plan([moved], complete: true), at: t1)
        #expect(result.refreshed == [edited.id] && result.added.isEmpty && result.removed.isEmpty)
        let item = try #require(try store.load().first)
        #expect(item.googleEtag == "e2" && item.icloudFingerprint == "f2" && item.fields == [.nickname, .emails])
        #expect(item.createdAt == t0 && item.updatedAt == t1, "same item, so it keeps its age")
    }

    @Test("A conflict missing from a complete plan is resolved and removed")
    func completePlanRemoves() throws {
        let store = InMemoryReviewStore()
        try store.reconcile(with: plan([edited, both], complete: true), at: t0)
        let result = try store.reconcile(with: plan([both], complete: true), at: t1)
        #expect(result.removed == [edited.id])
        #expect(try store.load().map(\.id) == [both.id])
    }

    @Test("A conflict missing from an incomplete plan was not looked at: it stays, while present ones still refresh")
    func incompletePlanKeeps() throws {
        let store = InMemoryReviewStore()
        try store.reconcile(with: plan([edited, both], complete: true), at: t0)
        var moved = both
        moved.googleEtag = "e3"
        let result = try store.reconcile(with: plan([moved], complete: false), at: t1)
        #expect(result.removed.isEmpty && result.refreshed == [both.id])
        #expect(Set(try store.load().map(\.id)) == [edited.id, both.id])

        var paused = plan([], complete: false)
        paused.pause = .user
        try store.reconcile(with: paused, at: t1)
        #expect(try store.load().count == 2, "an empty paused plan resolves nothing")
    }

    @Test("A conflict found when two contacts were linked cannot be derived again, so only the user removes it")
    func pinnedFirstLinkConflicts() throws {
        let store = InMemoryReviewStore()
        let record = ContactRecord(id: "I1", source: .icloud, sourceIdentifier: "I1", givenName: "Ann")
        var linking = plan([ReviewCandidate(kind: .bothEdited, icloudID: "I1", resourceName: "people/c1", googleEtag: "e1", fields: [.nickname]), both], complete: true)
        linking.links = [PlannedLink(
            icloudID: "I1", resourceName: "people/c1", origin: .matched, isNewLink: true,
            baseline: SyncBaseline(icloud: record, google: record, googleEtag: "e1", syncedAt: t0), reasons: []
        )]
        try store.reconcile(with: linking, at: t0)
        #expect(try store.load().map(\.pinned).sorted { !$0 && $1 } == [false, true])

        let result = try store.reconcile(with: plan([], complete: true), at: t1)
        #expect(result.removed == [both.id], "an ordinary conflict that is gone is dropped; the first-link one stays")
        #expect(try store.load().map(\.id) == ["bothEdited|I1|people/c1"])
        try store.remove(ids: ["bothEdited|I1|people/c1"])
        #expect(try store.load().isEmpty)
    }

    @Test("Ignored Google contacts are never offered again, even by a plan that still lists them")
    func ignoredStayIgnored() throws {
        let store = InMemoryReviewStore()
        try store.reconcile(with: plan([fresh, edited], complete: true), at: t0)
        let result = try store.reconcile(with: plan([fresh, edited], complete: false), ignoredGoogle: ["people/c9"], at: t1)
        #expect(result.removed == [fresh.id] && result.added.isEmpty)
        #expect(try store.load().map(\.id) == [edited.id])
    }

    @Test("Executor-added items and manual removal")
    func addAndRemove() throws {
        let store = InMemoryReviewStore()
        let late = ReviewCandidate(kind: .deletedInICloudEditedInGoogle, icloudID: "I3", resourceName: "people/c3", googleEtag: "e3")
        #expect(try store.add([late], at: t0).added == [late.id])
        #expect(try store.items(concerning: "I3", resourceName: nil).count == 1)
        #expect(try store.items(concerning: nil, resourceName: "people/c3").count == 1)
        #expect(try store.items(concerning: "I4", resourceName: "people/c4").isEmpty)
        try store.remove(ids: [late.id, "nonexistent"])
        #expect(try store.load().isEmpty)
    }

    @Test("review.json is versioned, survives a reload, and a file of another version is left alone")
    func fileStore() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("review.json")
        let store = ReviewStore(url: url)
        #expect(try store.load().isEmpty && !FileManager.default.fileExists(atPath: url.path))
        try store.reconcile(with: plan([edited, both], complete: true), at: t0)

        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["version"] as? Int == 1 && (object["items"] as? [[String: Any]])?.count == 2)
        let reloaded = try ReviewStore(url: url).load()
        #expect(Set(reloaded.map(\.id)) == [edited.id, both.id] && reloaded.allSatisfy { $0.createdAt == t0 })
        try ReviewStore(url: url).remove(ids: [edited.id])
        #expect(try store.load().map(\.id) == [both.id])

        let future = Data(#"{"version": 99, "items": []}"#.utf8)
        try future.write(to: url)
        #expect(throws: SyncFileError.unsupportedVersion(file: "review.json", version: 99)) { try store.load() }
        #expect(throws: SyncFileError.unsupportedVersion(file: "review.json", version: 99)) { try store.add([edited], at: t0) }
        #expect(try Data(contentsOf: url) == future, "left as it was")

        try Data("not json".utf8).write(to: url)
        #expect(throws: SyncFileError.self) { try store.load() }
        #expect(try Data(contentsOf: url) == Data("not json".utf8))
    }
}
