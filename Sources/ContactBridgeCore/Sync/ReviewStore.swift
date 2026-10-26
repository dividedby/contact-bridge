import Foundation
import Synchronization

/// One open question for the user, kept between runs. Built from a `ReviewCandidate`; the planner derives the candidates
/// again every run and `ReviewStore.reconcile` keeps the stored items in step with them.
public struct ReviewItem: Sendable, Hashable, Codable, Identifiable {
    /// `"<kind>|<iCloud id>|<resource name>"`, same as `ReviewCandidate.id`.
    public var id: String
    public var kind: ReviewKind
    public var icloudID: String?
    public var resourceName: String?
    /// The Google etag the decision is about. Applying a decision first checks it, and refreshes the item if it moved.
    public var googleEtag: String?
    /// `ContactFingerprint` of the iCloud contact the decision is about; same use as `googleEtag`.
    public var icloudFingerprint: String?
    public var fields: [SyncField]
    /// For `photoConflict`: see `ReviewCandidate.photoStamp`. Missing in files written before photo sync.
    public var photoStamp: String?
    /// For `photoConflict`: see `ReviewCandidate.photoReason`.
    public var photoReason: PhotoConflictReason?
    /// Set for a conflict between two contacts that were only just linked. Their baselines were taken from both sides as
    /// they are, so no later plan derives the conflict again and its absence says nothing: only the user resolving it
    /// (`ReviewStoring.remove`), the contact vanishing from either side, or the plan finding the two sides agree
    /// (`SyncPlan.settledReviews`; both in `reconcile`), removes the item.
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(candidate: ReviewCandidate, pinned: Bool = false, at now: Date) {
        id = candidate.id
        kind = candidate.kind
        icloudID = candidate.icloudID
        resourceName = candidate.resourceName
        googleEtag = candidate.googleEtag
        icloudFingerprint = candidate.icloudFingerprint
        fields = candidate.fields
        photoStamp = candidate.photoStamp
        photoReason = candidate.photoReason
        self.pinned = pinned
        createdAt = now
        updatedAt = now
    }

    /// Whether the item is about this contact on either side.
    func concerns(icloudID: String?, resourceName: String?) -> Bool {
        (icloudID != nil && self.icloudID == icloudID) || (resourceName != nil && self.resourceName == resourceName)
    }
}

/// What a store update did, by item id.
public struct ReviewReconciliation: Sendable, Hashable {
    public var added: [String] = []
    /// Kept, but its etag, fingerprint, fields or photo stamp moved.
    public var refreshed: [String] = []
    public var removed: [String] = []

    public var isEmpty: Bool { added.isEmpty && refreshed.isEmpty && removed.isEmpty }
}

/// The contents of `review.json`.
public struct ReviewList: Sendable, Hashable, Codable, VersionedFileContents {
    public static let currentVersion = 1

    public var version: Int
    public var items: [ReviewItem]

    public init(version: Int = ReviewList.currentVersion, items: [ReviewItem] = []) {
        self.version = version
        self.items = items
    }

    /// Adds new candidates and refreshes known ones in place (same id, new etag, fingerprint, fields or photo stamp; `createdAt` stays).
    mutating func upsert(_ candidates: [ReviewCandidate], pinned: Set<String> = [], at now: Date, into result: inout ReviewReconciliation) {
        for candidate in candidates {
            let isPinned = candidate.kind == .bothEdited && candidate.icloudID.map(pinned.contains) == true
            guard let index = items.firstIndex(where: { $0.id == candidate.id }) else {
                items.append(ReviewItem(candidate: candidate, pinned: isPinned, at: now))
                result.added.append(candidate.id)
                continue
            }
            let item = items[index]
            if isPinned { items[index].pinned = true }
            guard item.googleEtag != candidate.googleEtag || item.icloudFingerprint != candidate.icloudFingerprint
                || item.fields != candidate.fields || item.photoStamp != candidate.photoStamp || item.photoReason != candidate.photoReason
            else { continue }
            items[index].googleEtag = candidate.googleEtag
            items[index].icloudFingerprint = candidate.icloudFingerprint
            items[index].fields = candidate.fields
            items[index].photoStamp = candidate.photoStamp
            items[index].photoReason = candidate.photoReason
            items[index].updatedAt = now
            result.refreshed.append(candidate.id)
        }
        items.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    mutating func remove(where shouldRemove: (ReviewItem) -> Bool, into result: inout ReviewReconciliation) {
        result.removed += items.filter(shouldRemove).map(\.id)
        items.removeAll(where: shouldRemove)
    }

    mutating func reconcile(with plan: SyncPlan, ignoredGoogle: Set<String>, at now: Date) -> ReviewReconciliation {
        var result = ReviewReconciliation()
        // An ignored Google contact stays ignored, whatever else the plan says.
        remove(where: { $0.kind == .newInGoogle && $0.resourceName.map(ignoredGoogle.contains) == true }, into: &result)
        let candidates = plan.review.filter { !($0.kind == .newInGoogle && $0.resourceName.map(ignoredGoogle.contains) == true) }
        upsert(candidates, pinned: Set(plan.links.map(\.icloudID)), at: now, into: &result)
        // A conflict about a contact that is gone from either side is moot, and a pinned one would never be derived away.
        let gone = Set(plan.droppedLinks).union(plan.deletes.map(\.icloudID)).union(
            plan.review.filter { $0.kind == .deletedInGoogle || $0.kind == .deletedInICloudEditedInGoogle }.compactMap(\.icloudID)
        )
        remove(
            where: { ($0.kind == .googleEdited || $0.kind == .bothEdited) && $0.icloudID.map(gone.contains) == true }, into: &result
        )
        // A first-link conflict whose two sides were found to agree: what Save would record, without anything to choose.
        let settled = Set(plan.settledReviews)
        remove(where: { $0.pinned && settled.contains($0.id) }, into: &result)
        // A conflict missing from a plan that did not look at everything is unseen, not resolved.
        if plan.reviewIsComplete {
            let current = Set(plan.review.map(\.id))
            remove(where: { !current.contains($0.id) && !$0.pinned }, into: &result)
        }
        return result
    }
}

public protocol ReviewStoring: Sendable {
    func load() throws -> [ReviewItem]
    /// Brings the stored items in line with the plan's candidates: new ones are added, ones with the same id and a moved
    /// etag or fingerprint are refreshed, and stored items the plan no longer reports are removed, but only when
    /// `plan.reviewIsComplete` (otherwise an absent item was not looked at, not resolved). Stored `newInGoogle` items
    /// for contacts in `ignoredGoogle` are removed regardless, and so are pinned conflicts in `plan.settledReviews`.
    @discardableResult
    func reconcile(with plan: SyncPlan, ignoredGoogle: Set<String>, at now: Date) throws -> ReviewReconciliation
    /// Adds or refreshes candidates the executor found while writing (a delete turned into a review).
    @discardableResult
    func add(_ candidates: [ReviewCandidate], at now: Date) throws -> ReviewReconciliation
    /// Drops items the user resolved.
    func remove(ids: [String]) throws
}

extension ReviewStoring {
    @discardableResult
    public func reconcile(with plan: SyncPlan, at now: Date) throws -> ReviewReconciliation {
        try reconcile(with: plan, ignoredGoogle: [], at: now)
    }

    /// The open items that concern this contact, by iCloud id or Google resource name.
    public func items(concerning icloudID: String?, resourceName: String?) throws -> [ReviewItem] {
        try load().filter { $0.concerns(icloudID: icloudID, resourceName: resourceName) }
    }
}

/// `review.json` next to `links.json`, rewritten atomically on every change.
public final class ReviewStore: ReviewStoring, Sendable {
    public static var defaultURL: URL { VersionedJSONFile<ReviewList>.inSupportFolder("review.json") }

    private let file: VersionedJSONFile<ReviewList>
    /// Serializes read-modify-write within this process.
    private let lock = Mutex(())

    public init(url: URL = ReviewStore.defaultURL) {
        file = VersionedJSONFile(url: url)
    }

    public func load() throws -> [ReviewItem] { try lock.withLock { _ in try file.read()?.items ?? [] } }

    public func reconcile(with plan: SyncPlan, ignoredGoogle: Set<String>, at now: Date) throws -> ReviewReconciliation {
        try change { $0.reconcile(with: plan, ignoredGoogle: ignoredGoogle, at: now) }
    }

    public func add(_ candidates: [ReviewCandidate], at now: Date) throws -> ReviewReconciliation {
        try change { list in
            var result = ReviewReconciliation()
            list.upsert(candidates, at: now, into: &result)
            return result
        }
    }

    public func remove(ids: [String]) throws {
        let doomed = Set(ids)
        _ = try change { list in
            var result = ReviewReconciliation()
            list.remove(where: { doomed.contains($0.id) }, into: &result)
            return result
        }
    }

    private func change(_ body: (inout ReviewList) -> ReviewReconciliation) throws -> ReviewReconciliation {
        try lock.withLock { _ in
            var list = try file.read() ?? ReviewList()
            let before = list
            let result = body(&list)
            if list != before { try file.write(list) }
            return result
        }
    }
}

/// For previews, the demo mode and tests: same semantics, nothing on disk.
public final class InMemoryReviewStore: ReviewStoring, Sendable {
    private let list: Mutex<ReviewList>

    public init(_ items: [ReviewItem] = []) {
        list = Mutex(ReviewList(items: items))
    }

    public func load() throws -> [ReviewItem] { list.withLock { $0.items } }

    public func reconcile(with plan: SyncPlan, ignoredGoogle: Set<String>, at now: Date) throws -> ReviewReconciliation {
        list.withLock { $0.reconcile(with: plan, ignoredGoogle: ignoredGoogle, at: now) }
    }

    public func add(_ candidates: [ReviewCandidate], at now: Date) throws -> ReviewReconciliation {
        list.withLock { list in
            var result = ReviewReconciliation()
            list.upsert(candidates, at: now, into: &result)
            return result
        }
    }

    public func remove(ids: [String]) throws {
        let doomed = Set(ids)
        list.withLock { list in
            var result = ReviewReconciliation()
            list.remove(where: { doomed.contains($0.id) }, into: &result)
        }
    }
}
