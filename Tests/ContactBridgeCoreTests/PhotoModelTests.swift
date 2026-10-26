import Foundation
import Testing
@testable import ContactBridgeCore

/// The photo additions to the stored models: new fields round-trip, and files written before them still load.
struct PhotoModelTests {
    private let t0 = SyncFixtures.t0

    static func fingerprint(_ seed: UInt8) -> PhotoFingerprint {
        PhotoFingerprint(hash: UInt64(seed) << 40 | 0xABCD, colors: Data((0..<48).map { UInt8(truncatingIfNeeded: Int($0) * 3 + Int(seed)) }))
    }

    static func photoBaseline(_ seed: UInt8 = 1, at date: Date = SyncFixtures.t0) -> PhotoBaseline {
        PhotoBaseline(
            icloud: fingerprint(seed), google: fingerprint(seed &+ 1), googleProfile: fingerprint(seed &+ 2), icloudHint: "hint-\(seed)",
            googleURLKey: "https://lh3.googleusercontent.com/key-\(seed)", icloudOrigin: .googleProfile, syncedAt: date,
            pendingRemoval: PhotoBaseline.PendingRemoval(side: .icloud, firstSeenAt: date)
        )
    }

    private func baseline(photo: PhotoBaseline? = nil) -> SyncBaseline {
        let record = SyncFixtures.icloud("I1", "Ann", "Lee", phones: ["415-555-0100"])
        return SyncBaseline(
            icloud: record, google: record, googleEtag: "e1", icloudNoteHash: NoteHash.hash("n"), googleNoteHash: NoteHash.hash("n"),
            syncedAt: t0, photo: photo
        )
    }

    /// Dates as the sync files write them.
    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try decoder.decode(T.self, from: encoder.encode(value))
    }

    /// The JSON of `value` with `keys` removed at the top level: what an older version of the app would have written.
    private func legacyJSON(_ value: some Encodable, removing keys: [String]) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
        for key in keys { object[key] = nil }
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: baseline

    @Test("A photo baseline survives JSON with every field set, and with none")
    func photoBaselineRoundTrip() throws {
        let full = Self.photoBaseline()
        #expect(try roundTrip(full) == full)
        let empty = PhotoBaseline(syncedAt: t0)
        #expect(try roundTrip(empty) == empty)
        #expect(empty.icloud == nil && empty.google == nil && empty.icloudOrigin == .user && empty.pendingRemoval == nil)
    }

    @Test("A baseline carries its photo baseline through JSON")
    func baselineWithPhoto() throws {
        let original = baseline(photo: Self.photoBaseline())
        #expect(try roundTrip(original) == original)
        #expect(try roundTrip(original).photo?.pendingRemoval?.side == .icloud)
    }

    @Test("A baseline written before photo sync decodes with no photo baseline, and compares equal to a fresh one")
    func oldBaseline() throws {
        let legacy = try legacyJSON(baseline(photo: Self.photoBaseline()), removing: ["photo"])
        #expect(!String(decoding: legacy, as: UTF8.self).contains("photo"))
        let decoded = try decoder.decode(SyncBaseline.self, from: legacy)
        #expect(decoded.photo == nil)
        #expect(decoded == baseline())
    }

    // MARK: state

    @Test("Photo settings default to photo sync on, profile photos off, nobody opted out")
    func stateDefaults() {
        let state = SyncState()
        #expect(state.syncPhotos && !state.useGoogleProfilePhotos && state.profilePhotoOptOut.isEmpty && state.lastPhotoFullListingAt == nil)
    }

    @Test("Photo settings survive JSON")
    func stateRoundTrip() throws {
        let state = SyncState(
            baselines: ["I1": baseline(photo: Self.photoBaseline())], syncPhotos: false, useGoogleProfilePhotos: true,
            profilePhotoOptOut: ["I1", "I7"], lastPhotoFullListingAt: t0
        )
        let decoded = try roundTrip(state)
        #expect(decoded == state)
        #expect(!decoded.syncPhotos && decoded.useGoogleProfilePhotos && decoded.profilePhotoOptOut == ["I1", "I7"])
        #expect(decoded.lastPhotoFullListingAt == t0 && decoded.baselines["I1"]?.photo == Self.photoBaseline())
    }

    @Test("A state file written before photo sync loads with photo sync on, as it is for existing installs")
    func oldState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync-state.json")
        try Data(#"{"version":1,"baselines":{},"ignoredGoogle":["people/c1"],"firstSyncApproved":true,"keepSeparate":["a|b"]}"#.utf8).write(to: url)
        let state = try SyncStateStore(url: url).load()
        #expect(state.syncPhotos && !state.useGoogleProfilePhotos && state.profilePhotoOptOut.isEmpty && state.lastPhotoFullListingAt == nil)
        #expect(state.firstSyncApproved && state.ignoredGoogle == ["people/c1"] && state.keepSeparate == ["a|b"])

        // Saving writes the new fields, and they come back.
        try SyncStateStore(url: url).update { $0.useGoogleProfilePhotos = true }
        #expect(try SyncStateStore(url: url).load().useGoogleProfilePhotos)
    }

    @Test("A full state minus its photo keys is the old format, and decodes to the defaults")
    func strippedState() throws {
        let state = SyncState(
            baselines: ["I1": baseline(photo: Self.photoBaseline())], firstSyncApproved: true, syncPhotos: false, useGoogleProfilePhotos: true,
            profilePhotoOptOut: ["I1"], lastPhotoFullListingAt: t0
        )
        let legacy = try legacyJSON(state, removing: ["syncPhotos", "useGoogleProfilePhotos", "profilePhotoOptOut", "lastPhotoFullListingAt"])
        let decoded = try decoder.decode(SyncState.self, from: legacy)
        #expect(decoded.syncPhotos && !decoded.useGoogleProfilePhotos && decoded.profilePhotoOptOut.isEmpty && decoded.lastPhotoFullListingAt == nil)
        #expect(decoded.baselines == state.baselines)
    }

    @Test("store(_:for:) rewrites a baseline but keeps the photo half of the one it replaces")
    func storeKeepsPhoto() {
        var state = SyncState(baselines: ["I1": baseline(photo: Self.photoBaseline(1))])
        var rewrite = baseline(photo: Self.photoBaseline(9))
        rewrite.googleEtag = "e2"
        state.store(rewrite, for: "I1")
        #expect(state.baselines["I1"]?.googleEtag == "e2" && state.baselines["I1"]?.photo == Self.photoBaseline(1))

        state.store(baseline(photo: nil), for: "I1")
        #expect(state.baselines["I1"]?.photo == Self.photoBaseline(1), "a rewrite with no photo does not erase it")

        state.store(baseline(photo: Self.photoBaseline(5)), for: "I2")
        #expect(state.baselines["I2"]?.photo == Self.photoBaseline(5), "a baseline with no predecessor is stored as given")
    }

    // MARK: review

    @Test("Review items and candidates carry a photo stamp and reason through JSON")
    func reviewRoundTrip() throws {
        let candidate = ReviewCandidate(
            kind: .photoConflict, icloudID: "I1", resourceName: "people/c1", googleEtag: "e1", photoStamp: "hint|key", photoReason: .removedInICloud
        )
        #expect(candidate.id == "photoConflict|I1|people/c1" && candidate.fields.isEmpty)
        let item = ReviewItem(candidate: candidate, at: t0)
        #expect(item.photoStamp == "hint|key" && item.photoReason == .removedInICloud)
        #expect(try roundTrip(item) == item)
        #expect(try roundTrip(ReviewList(items: [item])).items == [item])
        #expect(ReviewKind.allCases.contains(.photoConflict) && PhotoConflictReason.allCases.count == 6)
        #expect(try roundTrip(ReviewKind.photoConflict) == .photoConflict)
    }

    @Test("A review file written before photo sync loads, with no stamp or reason")
    func oldReviewFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("review.json")
        let item = ReviewItem(candidate: ReviewCandidate(kind: .googleEdited, icloudID: "I1", resourceName: "people/c1", googleEtag: "e1", fields: [.nickname]), at: t0)
        let legacyItem = try legacyJSON(item, removing: ["photoStamp", "photoReason"])
        let file = try JSONSerialization.data(withJSONObject: [
            "version": 1, "items": [try JSONSerialization.jsonObject(with: legacyItem)],
        ] as [String: Any])
        try file.write(to: url)

        let loaded = try ReviewStore(url: url).load()
        #expect(loaded == [item] && loaded.first?.photoStamp == nil && loaded.first?.photoReason == nil)
    }

    @Test("A moved photo stamp or reason refreshes the item in place; the same ones change nothing")
    func stampRefreshes() throws {
        let store = InMemoryReviewStore()
        let first = ReviewCandidate(
            kind: .photoConflict, icloudID: "I1", resourceName: "people/c1", googleEtag: "e1", photoStamp: "a|b", photoReason: .bothChanged
        )
        func plan(_ candidate: ReviewCandidate) -> SyncPlan {
            var plan = SyncPlan(isPreview: false)
            plan.review = [candidate]
            return plan
        }
        #expect(try store.reconcile(with: plan(first), at: t0).added == [first.id])
        #expect(try store.reconcile(with: plan(first), at: t0.addingTimeInterval(60)).isEmpty)

        var restamped = first
        restamped.photoStamp = "a|c"
        let result = try store.reconcile(with: plan(restamped), at: t0.addingTimeInterval(120))
        #expect(result.refreshed == [first.id] && result.added.isEmpty && result.removed.isEmpty)
        let item = try #require(try store.load().first)
        #expect(item.photoStamp == "a|c" && item.createdAt == t0 && item.updatedAt == t0.addingTimeInterval(120))

        var reasoned = restamped
        reasoned.photoReason = .removedInGoogle
        #expect(try store.reconcile(with: plan(reasoned), at: t0.addingTimeInterval(180)).refreshed == [first.id])
        #expect(try store.load().first?.photoReason == .removedInGoogle)
    }

    @Test("The same pair can have a field conflict and a photo conflict open at once")
    func separateIDs() {
        let field = ReviewCandidate(kind: .bothEdited, icloudID: "I1", resourceName: "people/c1", fields: [.phones])
        let photo = ReviewCandidate(kind: .photoConflict, icloudID: "I1", resourceName: "people/c1", photoStamp: "x")
        #expect(field.id != photo.id)
    }

    // MARK: plan

    @Test("Photo ops make a plan non-empty, but are not field mutations")
    func planOps() {
        var plan = SyncPlan(isPreview: false)
        #expect(plan.isEmpty && plan.photoOps.isEmpty)
        plan.photoOps = [PlannedPhotoOp(icloudID: "I1", resourceName: "people/c1", kind: .copyToICloud(source: .googleProfile), baseline: Self.photoBaseline())]
        #expect(!plan.isEmpty && plan.mutationCount == 0)
        #expect(Set([PhotoSource.googleContact, .googleProfile]).count == 2)
    }
}
