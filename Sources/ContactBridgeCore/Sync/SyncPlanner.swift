import Foundation

/// Turns what the scanner and the feed found into the plan for one sync run. Pure and deterministic: the same inputs in
/// any order give the same plan.
///
/// Linked contacts go through `ThreeWayDiff`. Unlinked iCloud contacts go through the matching pass: a confident match
/// is linked, a name-only or possible match becomes a `possibleLink` review, no match is created in Google (unless the
/// ownership-tag index shows it already was). Unlinked Google contacts that nobody claimed are offered as `newInGoogle`,
/// except those the user ignored. Nothing is ever deleted from a side that merely looks empty: the scanner and the feed
/// pause first.
public struct SyncPlanner: Sendable {
    public struct Limits: Sendable, Hashable {
        /// More deletes than `max(minDeletes, deleteFraction * linked)` need the user's confirmation.
        public var minDeletes = 5
        public var deleteFraction = 0.02
        /// Same for updates of linked contacts.
        public var minUpdates = 50
        public var updateFraction = 0.25
        /// Google writes per run; the rest wait for the next one.
        public var maxMutations = 1000
        /// Photo writes to Google (or to iCloud) beyond `max(minPhotoWrites, photoWriteFraction * linked)` need confirmation.
        public var minPhotoWrites = 20
        public var photoWriteFraction = 0.25
        /// Photo deletes in Google beyond `max(minPhotoDeletes, photoDeleteFraction * linked)` need confirmation.
        public var minPhotoDeletes = 5
        public var photoDeleteFraction = 0.02
        /// Google photo writes per run (they are slow, one a second); the rest wait for the next one.
        public var maxGooglePhotoWrites = 60

        public init() {}
    }

    /// Starts the summary of the pause for a full listing that lacks many linked contacts. The engine lets the user
    /// confirm only that pause by allowing mass deletions, so it recognises it by this text.
    public static let googleMissingSummaryPrefix = "Google no longer lists "

    public var matcher: DuplicateMatcher
    public var limits: Limits

    public init(matcher: DuplicateMatcher = DuplicateMatcher(), limits: Limits = Limits()) {
        self.matcher = matcher
        self.limits = limits
    }

    /// Whether the Google feed must list every contact for `plan` to be right: there are iCloud contacts to match or
    /// create, or links whose baseline has to be taken from Google.
    public static func requiresFullGoogleListing(icloud: ICloudScan, links: LinkTable, state: SyncState) -> Bool {
        guard icloud.status == .changed else { return false }
        if links.links.keys.contains(where: { state.baselines[$0] == nil }) { return true }
        return icloud.records.contains { links.links[$0.sourceIdentifier] == nil && !$0.isEmpty }
    }

    /// - Parameters:
    ///   - links: `links.json`. A link without a baseline in `state` (a Phase 1 import) is adopted: its baseline is taken
    ///     from both sides as they are now.
    ///   - keepSeparate: `PossibleMatch.id`-style pairs (`"<iCloud id>|<resource name>"`) the user chose to keep apart.
    ///   - allowMassGoogleDeletions: the user confirmed that a full Google listing really is missing that many linked
    ///     contacts (see `PauseReason.needsConfirmation`); they then become `deletedInGoogle` reviews as usual. An empty
    ///     listing is never let through.
    ///   - openReviews: the stored review items. A pinned edit conflict (`canSettle`) is derived by no later plan, so the
    ///     planner reports it in `settledReviews` when the live contacts it is about already agree on every group it names.
    ///   - googleExtra: Google contacts the caller read by hand, for pinned conflicts the feed did not list.
    ///   - photos: what `PhotoReconciler` found; the default looked at nothing, so no photo is planned.
    ///   - now: stamped on the baselines.
    public func plan(
        icloud: ICloudScan, google feed: GoogleFeed, state: SyncState, links: LinkTable, keepSeparate: Set<String> = [],
        allowMassGoogleDeletions: Bool = false, openReviews: [ReviewItem] = [], googleExtra: [String: GooglePerson] = [:],
        photos: PhotoObservations = .none, now: Date
    ) -> SyncPlan {
        var plan = SyncPlan(isPreview: !state.firstSyncApproved)
        plan.notesReason = icloud.notesReason
        if let pause = icloud.pause ?? feed.pause {
            plan.pause = pause
            return plan
        }
        if icloud.status == .changed, icloud.records.isEmpty, !state.baselines.isEmpty || !links.links.isEmpty {
            plan.pause = .containerChanged
            return plan
        }
        if let pause = googleListingPause(feed, state: state, links: links, confirmed: allowMassGoogleDeletions) {
            plan.pause = pause
            return plan
        }
        if case .unavailable = icloud.notes { plan.notesUnavailable = true }
        plan.createsVerifiedAgainstFullListing = feed.isFullListing
        plan.reviewIsComplete = feed.isFullListing && icloud.status == .changed

        let run = Run(planner: self, icloud: icloud, feed: feed, state: state, links: links, keepSeparate: keepSeparate, now: now)
        run.planLinked(into: &plan)
        run.planUnlinked(into: &plan)
        run.planPhotos(photos, into: &plan)
        plan.settledReviews = run.settledReviews(of: openReviews, googleExtra: googleExtra, plan: plan)
        applyCap(to: &plan)
        applyGuards(to: &plan, linkedCount: max(links.links.count, state.baselines.count))

        plan.review.sort { $0.id < $1.id }
        plan.links.sort { ($0.icloudID, $0.resourceName) < ($1.icloudID, $1.resourceName) }
        plan.droppedLinks.sort()

        // Anything left waiting must be seen again next run, so the iCloud token must not move past it.
        if plan.deferred.isEmpty, plan.unlinkedWaitingForFullListing == 0, plan.waitingForNotes == 0, plan.photosUnevaluated == 0 {
            plan.checkpoint = SyncCheckpoint(
                icloudChangeToken: icloud.changeToken, icloudContainerID: icloud.containerID, lastNotesReadAt: icloud.notesReadAt,
                googleSyncToken: feed.nextSyncToken, fieldsVersion: feed.fieldsVersion, googleAccount: feed.account,
                replacesGoogleToken: feed.isFullListing || feed.nextSyncToken != nil
            )
        }
        return plan
    }

    /// What a photo review item is about: the iCloud thumbnail hash and the Google contact photo URL key, never the etag (which
    /// moves on every unrelated edit). A moved stamp means the item has to be refreshed before it is applied.
    public static func photoStamp(_ seen: PhotoSnapshot) -> String { "\(seen.icloud?.token ?? "")|\(seen.google?.token ?? "")" }

    /// A first-link conflict that is kept (pinned) until the user decides it, since the baseline already holds both sides.
    public static func canSettle(_ item: ReviewItem) -> Bool {
        item.pinned && (item.kind == .bothEdited || item.kind == .googleEdited) && item.icloudID != nil && item.resourceName != nil
    }

    // MARK: cap and guards

    /// A full listing that is empty while contacts are linked, or that lacks more linked contacts than the delete guard
    /// allows, is not read as deletions: no review items or writes come from it.
    private func googleListingPause(_ feed: GoogleFeed, state: SyncState, links: LinkTable, confirmed: Bool) -> PauseReason? {
        guard feed.isFullListing else { return nil }
        let linked = max(links.links.count, state.baselines.count)
        guard linked > 0 else { return nil }
        if feed.people.isEmpty { return .googleEmpty }
        let missing = links.links.values.filter { feed.people[$0.googleResourceName] == nil }.count
        let limit = max(Double(limits.minDeletes), limits.deleteFraction * Double(linked))
        guard !confirmed, Double(missing) > limit else { return nil }
        return .needsConfirmation(
            summary: "\(Self.googleMissingSummaryPrefix)\(missing) of \(linked) linked contacts (more than \(Int(limit)) at once). They may have been deleted in Google, or the listing may be incomplete."
        )
    }

    /// Keeps the first `maxMutations` Google writes (updates, then deletes, then creates, each by iCloud id).
    private func applyCap(to plan: inout SyncPlan) {
        plan.updates.sort { $0.icloudID < $1.icloudID }
        plan.deletes.sort { $0.icloudID < $1.icloudID }
        plan.creates.sort { $0.icloudID < $1.icloudID }
        var room = limits.maxMutations
        func take<T>(_ items: inout [T]) -> Int {
            let kept = min(room, items.count)
            let dropped = items.count - kept
            items.removeLast(dropped)
            room -= kept
            return dropped
        }
        plan.deferred.updates = take(&plan.updates)
        plan.deferred.deletes = take(&plan.deletes)
        plan.deferred.creates = take(&plan.creates)

        // Photos to Google are the slow ones; everything that writes no Google photo goes through.
        plan.photoOps.sort { ($0.icloudID, $0.resourceName) < ($1.icloudID, $1.resourceName) }
        var photoRoom = limits.maxGooglePhotoWrites
        plan.photoOps.removeAll { op in
            switch op.kind {
            case .copyToGoogle, .deleteOnGoogle:
                guard photoRoom > 0 else {
                    plan.deferred.photoWrites += 1
                    return true
                }
                photoRoom -= 1
                return false
            default: return false
            }
        }
    }

    /// The summary of the pause for photo changes that exceed the limits, nil when they are within them. Judged on every op
    /// the plan lists plus the Google writes the per-run cap held back. Also used by whoever writes photos in bulk.
    public static func photoGuardReasons(ops: [PlannedPhotoOp], deferredWrites: Int = 0, linkedCount: Int, limits: Limits) -> [String] {
        var googleWrites = deferredWrites
        var googleDeletes = 0
        var icloudWrites = 0
        for op in ops {
            switch op.kind {
            case .copyToGoogle: googleWrites += 1
            case .deleteOnGoogle: googleDeletes += 1
            case .copyToICloud, .deleteOnICloud: icloudWrites += 1
            case .recordBaseline: break
            }
        }
        let writeLimit = max(Double(limits.minPhotoWrites), limits.photoWriteFraction * Double(linkedCount))
        let deleteLimit = max(Double(limits.minPhotoDeletes), limits.photoDeleteFraction * Double(linkedCount))
        var reasons: [String] = []
        if Double(googleWrites) > writeLimit {
            reasons.append("write \(googleWrites) of \(linkedCount) contact photos to Google (more than \(Int(writeLimit)) at once)")
        }
        if Double(googleDeletes) > deleteLimit {
            reasons.append("remove \(googleDeletes) of \(linkedCount) contact photos from Google (more than \(Int(deleteLimit)) at once)")
        }
        if Double(icloudWrites) > writeLimit {
            reasons.append("change \(icloudWrites) of \(linkedCount) contact photos in iCloud (more than \(Int(writeLimit)) at once)")
        }
        return reasons
    }

    /// Judged on the full plan, before the cap.
    private func applyGuards(to plan: inout SyncPlan, linkedCount: Int) {
        let deletes = plan.deletes.count + plan.deferred.deletes
        let updates = plan.updates.count + plan.deferred.updates
        let deleteLimit = max(Double(limits.minDeletes), limits.deleteFraction * Double(linkedCount))
        let updateLimit = max(Double(limits.minUpdates), limits.updateFraction * Double(linkedCount))
        var reasons: [String] = []
        // A released link (its iCloud contact is gone, Google's still exists) is re-matched, not forgotten for good.
        let forgotten = plan.forgottenLinkInfo
        if Double(forgotten.count) > deleteLimit {
            let reasonsSeen = Set(forgotten.map(\.reason))
            let what = reasonsSeen == [.iCloudGone] ? "deleted in iCloud"
                : reasonsSeen == [.goneFromBothSides] ? "gone from both sides" : "deleted in iCloud or gone from both sides"
            plan.guardedForgottenLinks = forgotten
            reasons.append("forget \(forgotten.count) of \(linkedCount) links to contacts \(what) (more than \(Int(deleteLimit)) at once)")
        }
        if Double(deletes) > deleteLimit {
            reasons.append("delete \(deletes) of \(linkedCount) linked contacts in Google (more than \(Int(deleteLimit)) at once)")
        }
        if Double(updates) > updateLimit {
            reasons.append("update \(updates) of \(linkedCount) linked contacts in Google (more than \(Int(updateLimit)) at once)")
        }
        reasons += Self.photoGuardReasons(ops: plan.photoOps, deferredWrites: plan.deferred.photoWrites, linkedCount: linkedCount, limits: limits)
        if !reasons.isEmpty { plan.pause = .needsConfirmation(summary: "This sync would " + reasons.joined(separator: " and ")) }
    }
}

// MARK: one planning run

extension SyncPlanner {
    /// Working state of one `plan` call.
    fileprivate struct Run {
        let planner: SyncPlanner
        let icloud: ICloudScan
        let feed: GoogleFeed
        let state: SyncState
        let links: LinkTable
        let keepSeparate: Set<String>
        let now: Date
        let icloudByID: [String: ContactRecord]

        init(planner: SyncPlanner, icloud: ICloudScan, feed: GoogleFeed, state: SyncState, links: LinkTable, keepSeparate: Set<String>, now: Date) {
            self.planner = planner
            self.icloud = icloud
            self.feed = feed
            self.state = state
            self.links = links
            self.keepSeparate = keepSeparate
            self.now = now
            icloudByID = Dictionary(icloud.records.map { ($0.sourceIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        }

        private var scanned: Bool { icloud.status == .changed }

        // MARK: linked contacts

        func planLinked(into plan: inout SyncPlan) {
            for id in links.links.keys.sorted() {
                guard let entry = links.links[id] else { continue }
                let name = entry.googleResourceName
                let iCloudGone = scanned && icloudByID[id] == nil
                let googleGone = feed.deleted.contains(name) || (feed.isFullListing && feed.people[name] == nil)
                let person = feed.people[name]

                guard let baseline = state.baselines[id] else {
                    planUnbaselined(id: id, entry: entry, iCloudGone: iCloudGone, googleGone: googleGone, person: person, into: &plan)
                    continue
                }
                if iCloudGone && googleGone {
                    drop(id, entry, baseline: baseline, person: person, reason: .goneFromBothSides, released: false, into: &plan)
                } else if iCloudGone {
                    if let person, googleChanged(person, since: baseline) {
                        plan.review.append(ReviewCandidate(
                            kind: .deletedInICloudEditedInGoogle, icloudID: id, resourceName: name, googleEtag: person.etag
                        ))
                    } else {
                        plan.deletes.append(PlannedDelete(icloudID: id, resourceName: name, baseline: baseline))
                    }
                } else if googleGone {
                    let current = icloudByID[id] ?? baseline.icloud
                    plan.review.append(ReviewCandidate(
                        kind: .deletedInGoogle, icloudID: id, resourceName: name, icloudFingerprint: ContactFingerprint.of(current)
                    ))
                } else {
                    planPair(id: id, name: name, baseline: baseline, person: person, into: &plan)
                }
            }
        }

        /// A link from Phase 1 Import: no baseline yet. Take one from both sides as they are now.
        private func planUnbaselined(
            id: String, entry: LinkEntry, iCloudGone: Bool, googleGone: Bool, person: GooglePerson?, into plan: inout SyncPlan
        ) {
            let name = entry.googleResourceName
            guard scanned else { return }
            guard let record = icloudByID[id] else {
                // Typically a Dedupe merge or a delete removed the iCloud contact after Import linked it. If Google still has
                // the contact, release it: a surviving iCloud contact may be the same person, and must not get a second copy.
                if iCloudGone {
                    drop(
                        id, entry, baseline: nil, person: person, reason: googleGone ? .goneFromBothSides : .iCloudGone,
                        released: person != nil, into: &plan
                    )
                }
                return
            }
            if googleGone {
                plan.review.append(ReviewCandidate(
                    kind: .deletedInGoogle, icloudID: id, resourceName: name, icloudFingerprint: ContactFingerprint.of(record)
                ))
            } else if let person {
                link(record, person, origin: .imported, isNewLink: false, reasons: ["linked by an earlier import"], into: &plan)
            }
        }

        /// Both contacts exist: run the three-way diff against the baseline.
        private func planPair(id: String, name: String, baseline: SyncBaseline, person: GooglePerson?, into plan: inout SyncPlan) {
            let record = icloudByID[id] ?? baseline.icloud
            // Same etag as the baseline: Google did not change it, whatever the listing says.
            let fresh = person.flatMap { $0.etag != baseline.googleEtag ? $0 : nil }
            let google = fresh.flatMap { GooglePersonMapper.record(from: $0, source: .google) } ?? baseline.google
            let etag = fresh?.etag ?? baseline.googleEtag
            let diff = ThreeWayDiff.diff(
                icloud: record, google: google, base: baseline,
                icloudNoteHash: scanned ? icloud.noteHashes[id] : baseline.icloudNoteHash,
                googleNoteHash: fresh.map(GooglePersonMapper.noteHash(of:)) ?? baseline.googleNoteHash,
                googleEtag: etag, at: now
            )

            if diff.needsPush {
                plan.updates.append(PlannedUpdate(
                    icloudID: id, resourceName: name, etag: etag, existing: fresh, fields: diff.pushFields, desired: diff.desiredGoogle,
                    note: diff.pushFields.contains(.note) ? icloud.noteTexts[id] ?? "" : nil, baseline: diff.updatedBaseline
                ))
            } else if differs(diff.updatedBaseline, from: baseline) {
                plan.baselineRefreshes[id] = diff.updatedBaseline
            }

            for (kind, change) in [(ReviewKind.googleEdited, FieldChange.googleEdited), (.bothEdited, .bothEditedDifferent)] {
                let fields = diff.reviewFields.filter { diff.changes[$0] == change }
                guard !fields.isEmpty else { continue }
                plan.review.append(ReviewCandidate(
                    kind: kind, icloudID: id, resourceName: name, googleEtag: etag,
                    icloudFingerprint: ContactFingerprint.of(record), fields: fields
                ))
            }
        }

        private func drop(
            _ id: String, _ entry: LinkEntry, baseline: SyncBaseline?, person: GooglePerson?, reason: DroppedLinkInfo.Reason,
            released: Bool, into plan: inout SyncPlan
        ) {
            plan.droppedLinks.append(id)
            let named = [
                baseline?.icloud.displayName,
                person.flatMap { GooglePersonMapper.record(from: $0, source: .google) }?.displayName,
                entry.displayName,
            ].compactMap { $0 }.first { !$0.isBlank && $0 != "(No name)" }
            plan.droppedLinkInfo[id] = DroppedLinkInfo(
                icloudID: id, name: named ?? entry.googleResourceName, resourceName: entry.googleResourceName, reason: reason,
                isReleased: released
            )
        }

        private func differs(_ new: SyncBaseline, from old: SyncBaseline) -> Bool {
            var new = new
            new.syncedAt = old.syncedAt
            return new != old
        }

        private func googleChanged(_ person: GooglePerson, since baseline: SyncBaseline) -> Bool {
            ThreeWayDiff.googleChanged(person, since: baseline, at: now)
        }

        // MARK: photos

        /// Decides each observed pair's photos. A pair whose contact is going away (or is being asked about as gone) is
        /// left out, as are pairs the observation could not look at (`photosUnevaluated`).
        func planPhotos(_ photos: PhotoObservations, into plan: inout SyncPlan) {
            guard state.syncPhotos, photos.wasObserved else { return }
            let leaving = Set(plan.droppedLinks).union(plan.deletes.map(\.icloudID)).union(
                plan.review.filter { $0.kind == .deletedInGoogle || $0.kind == .deletedInICloudEditedInGoogle }.compactMap(\.icloudID)
            )
            for id in photos.pairs.keys.sorted() {
                guard let observation = photos.pairs[id], !leaving.contains(id), let baseline = state.baselines[id] else { continue }
                let seen = observation.seen
                let name = observation.resourceName
                // A new decision supersedes an old failure; the failure only stops the same copy being tried again.
                func op(_ kind: PlannedPhotoOp.Kind, _ result: PhotoBaseline, googleKey: String?) -> PlannedPhotoOp {
                    var result = result
                    result.failure = nil
                    return PlannedPhotoOp(
                        icloudID: id, resourceName: name, kind: kind, baseline: result, expectedGoogleURLKey: googleKey,
                        expectedICloudHint: seen.icloud?.token,
                        failureStamp: "\(seen.icloud?.token ?? "")|\(googleKey ?? "")"
                    )
                }
                func copy(_ planned: PlannedPhotoOp) {
                    if let failure = baseline.photo?.failure, failure.stamp == planned.failureStamp { return }
                    plan.photoOps.append(planned)
                }
                switch PhotoDecision.decide(baseline: baseline.photo, seen: seen, profileEnabled: observation.profileEnabled, now: now) {
                case .settled: break
                case .record(let result): plan.photoOps.append(op(.recordBaseline, result, googleKey: seen.google?.token))
                case .copyToGoogle(let result): copy(op(.copyToGoogle, result, googleKey: seen.google?.token))
                case .copyToICloud(let source, let result):
                    copy(op(.copyToICloud(source: source), result, googleKey: source == .googleProfile ? seen.profile?.token : seen.google?.token))
                case .review(let reason):
                    plan.review.append(ReviewCandidate(
                        kind: .photoConflict, icloudID: id, resourceName: name, photoStamp: SyncPlanner.photoStamp(seen), photoReason: reason
                    ))
                }
            }
            // A photo that cannot be read is recorded on the pair, so it is left alone until it changes. A pair that is judged
            // anyway (only its profile photo failed) carries the note on the baseline its op stores.
            for (id, failure) in photos.failures.sorted(by: { $0.key < $1.key }) where !leaving.contains(id) && state.baselines[id] != nil {
                let marker = PhotoBaseline.Failure(stamp: failure.stamp, message: failure.message, at: now)
                if let index = plan.photoOps.firstIndex(where: { $0.icloudID == id }) {
                    plan.photoOps[index].baseline.failure = marker
                } else {
                    var marked = state.baselines[id]?.photo ?? PhotoBaseline(syncedAt: now)
                    marked.failure = marker
                    plan.photoOps.append(PlannedPhotoOp(icloudID: id, resourceName: failure.resourceName, kind: .recordBaseline, baseline: marked))
                }
            }
            plan.photosUnjudged = Set(photos.skipped).union(photos.failures.keys)
            plan.photosUnevaluated = photos.unevaluated.count
            plan.photoReviewIsComplete = feed.isFullListing && scanned && photos.unevaluated.isEmpty
        }

        // MARK: settled conflicts

        /// The pinned conflicts among `items` that the review screen would show as "The two sides agree now", judged on the live
        /// contacts of this run (the same draft, baseline included). Anything not read this run is kept: iCloud not scanned,
        /// Google's contact neither listed nor in `googleExtra`, no baseline yet, or a note conflict whose iCloud note was not read.
        func settledReviews(of items: [ReviewItem], googleExtra: [String: GooglePerson], plan: SyncPlan) -> [String] {
            guard scanned else { return [] }
            let derived = Set(plan.review.map(\.id))
            return items.filter(SyncPlanner.canSettle).compactMap { item -> String? in
                guard !derived.contains(item.id), let id = item.icloudID, let name = item.resourceName, let record = icloudByID[id],
                      let baseline = state.baselines[id], !feed.deleted.contains(name), let person = feed.people[name] ?? googleExtra[name],
                      !person.isDeleted, let google = GooglePersonMapper.record(from: person, source: .google)
                else { return nil }
                let icloudNote = icloud.noteHashes[id] == nil ? nil : icloud.noteTexts[id] ?? ""
                let draft = SyncReviewDraft(
                    icloud: record, google: google, base: baseline, reviewFields: item.fields, icloudNote: icloudNote,
                    googleNote: GooglePersonMapper.note(of: person)
                )
                return !draft.noteUnreadable && draft.isSettled ? item.id : nil
            }
        }

        // MARK: linking

        /// Records a link with a baseline taken from both sides as they are now. Field groups that already differ become
        /// a `bothEdited` candidate (the baseline stays at the current values; the review item carries the conflict).
        private func link(
            _ record: ContactRecord, _ person: GooglePerson, origin: LinkOrigin, isNewLink: Bool, reasons: [String], into plan: inout SyncPlan
        ) {
            guard let name = person.resourceName, let google = GooglePersonMapper.record(from: person, source: .google) else { return }
            let id = record.sourceIdentifier
            let iHash = scanned ? icloud.noteHashes[id] : nil
            // The scan reads notes for contacts without a baseline; if that failed, wait rather than store a baseline
            // that can never compare the note.
            guard iHash != nil else {
                plan.waitingForNotes += 1
                return
            }
            let gHash = GooglePersonMapper.noteHash(of: person)
            let baseline = SyncBaseline(
                icloud: record, google: google, googleEtag: person.etag ?? "", icloudNoteHash: iHash, googleNoteHash: gHash, syncedAt: now
            )
            plan.links.append(PlannedLink(
                icloudID: id, resourceName: name, origin: origin, isNewLink: isNewLink, baseline: baseline, reasons: reasons
            ))

            // Against an empty baseline every group that has data on either side counts as edited, so a group that is
            // not "both edited to the same thing" is a genuine difference. Labels are not: each side keeps its own, and the
            // review screen shows entries with the same key as the same.
            let empty = NoteHash.hash("")
            let probe = SyncBaseline(
                icloud: ContactRecord(id: id, source: .icloud, sourceIdentifier: id),
                google: ContactRecord(id: name, source: .google, sourceIdentifier: name), googleEtag: "",
                icloudNoteHash: empty, googleNoteHash: empty, syncedAt: now
            )
            let diff = ThreeWayDiff.diff(
                icloud: record, google: google, base: probe, icloudNoteHash: iHash, googleNoteHash: gHash, labelsMatter: false, at: now
            )
            let differing = SyncField.allCases.filter {
                switch diff.changes[$0] {
                case .pushToGoogle?, .googleEdited?, .bothEditedDifferent?: true
                default: false
                }
            }
            if !differing.isEmpty {
                plan.review.append(ReviewCandidate(
                    kind: .bothEdited, icloudID: id, resourceName: name, googleEtag: person.etag,
                    icloudFingerprint: ContactFingerprint.of(record), fields: differing
                ))
            }
        }

        // MARK: unlinked contacts

        func planUnlinked(into plan: inout SyncPlan) {
            // A released link's Google contact competes in the matching pass like any unlinked one.
            let released = Set(plan.droppedLinkInfo.values.filter(\.isReleased).map(\.resourceName))
            let linkedNames = Set(links.links.values.map(\.googleResourceName)).subtracting(released)
            var claimedICloud = Set(plan.links.map(\.icloudID))
            var claimedGoogle = Set(plan.links.map(\.resourceName))

            var unlinkedICloud = scanned
                ? icloud.records.filter { links.links[$0.sourceIdentifier] == nil && !$0.isEmpty && !claimedICloud.contains($0.sourceIdentifier) }
                : []
            // Contacts the user ignored stay out of every pass.
            let googleOffered = feed.people.keys.sorted().compactMap { name -> (person: GooglePerson, record: ContactRecord)? in
                guard !linkedNames.contains(name), !state.ignoredGoogle.contains(name), !claimedGoogle.contains(name),
                      let person = feed.people[name], let record = GooglePersonMapper.record(from: person, source: .google), !record.isEmpty
                else { return nil }
                return (person, record)
            }

            // A Google contact already tagged with this iCloud id was created by an earlier run that never recorded the link.
            for record in unlinkedICloud {
                let id = record.sourceIdentifier
                guard let name = feed.ownershipIndex[id], !linkedNames.contains(name), !claimedGoogle.contains(name),
                      let person = feed.people[name]
                else { continue }
                link(record, person, origin: .createdInGoogle, isNewLink: true, reasons: ["created by an earlier sync"], into: &plan)
                claimedICloud.insert(id)
                claimedGoogle.insert(name)
            }
            unlinkedICloud.removeAll { claimedICloud.contains($0.sourceIdentifier) }

            var pairs: [(icloudID: String, name: String)] = []
            if feed.isFullListing {
                var candidates = googleOffered.filter { !claimedGoogle.contains($0.record.sourceIdentifier) }
                matchPass(&unlinkedICloud, &candidates, claimedGoogle: &claimedGoogle, pairs: &pairs, into: &plan)
                let pending = Set(pairs.map(\.icloudID))
                for record in unlinkedICloud where !pending.contains(record.sourceIdentifier) {
                    let id = record.sourceIdentifier
                    guard icloud.noteHashes[id] != nil else {
                        plan.waitingForNotes += 1
                        continue
                    }
                    plan.creates.append(PlannedCreate(
                        icloudID: id, record: record, note: icloud.noteTexts[id], icloudNoteHash: icloud.noteHashes[id]
                    ))
                }
            } else {
                plan.unlinkedWaitingForFullListing = unlinkedICloud.count
            }

            let paired = Set(pairs.map(\.name))
            let icloudRecords = icloudByID
            for (icloudID, name) in pairs {
                let person = feed.people[name]
                plan.review.append(ReviewCandidate(
                    kind: .possibleLink, icloudID: icloudID, resourceName: name, googleEtag: person?.etag,
                    icloudFingerprint: icloudRecords[icloudID].map(ContactFingerprint.of)
                ))
            }
            for offered in googleOffered where !claimedGoogle.contains(offered.record.sourceIdentifier) && !paired.contains(offered.record.sourceIdentifier) {
                plan.review.append(ReviewCandidate(kind: .newInGoogle, resourceName: offered.record.sourceIdentifier, googleEtag: offered.person.etag))
            }
        }

        /// Links confident matches; collects name-only and possible ones as pairs for the user.
        private func matchPass(
            _ unlinkedICloud: inout [ContactRecord], _ candidates: inout [(person: GooglePerson, record: ContactRecord)],
            claimedGoogle: inout Set<String>, pairs: inout [(icloudID: String, name: String)], into plan: inout SyncPlan
        ) {
            guard !unlinkedICloud.isEmpty, !candidates.isEmpty else { return }
            let result = ImportPlanner(matcher: planner.matcher).plan(
                icloud: unlinkedICloud, connections: candidates.map(\.record), otherContacts: []
            )
            let people = Dictionary(candidates.map { ($0.record.sourceIdentifier, $0.person) }, uniquingKeysWith: { first, _ in first })
            var claimedICloud = Set<String>()

            let ordered = result.links.sorted {
                $0.confidence != $1.confidence ? $0.confidence > $1.confidence : ($0.googleResourceName, $0.icloudID) < ($1.googleResourceName, $1.icloudID)
            }
            for match in ordered where !match.isNameOnly {
                guard !claimedICloud.contains(match.icloudID), let record = icloudByID[match.icloudID], let person = people[match.googleResourceName]
                else { continue }
                link(record, person, origin: .matched, isNewLink: true, reasons: match.reasons, into: &plan)
                claimedICloud.insert(match.icloudID)
                claimedGoogle.insert(match.googleResourceName)
            }

            var seen = Set<String>()
            func offer(_ icloudID: String, _ name: String) {
                let pair = icloudID + "|" + name
                guard !claimedICloud.contains(icloudID), !claimedGoogle.contains(name), !keepSeparate.contains(pair), seen.insert(pair).inserted
                else { return }
                pairs.append((icloudID, name))
            }
            for match in ordered where match.isNameOnly { offer(match.icloudID, match.googleResourceName) }
            for match in result.possibleMatches { offer(match.icloudID, match.googleID) }
            pairs.sort { ($0.icloudID, $0.name) < ($1.icloudID, $1.name) }

            unlinkedICloud.removeAll { claimedICloud.contains($0.sourceIdentifier) }
            candidates.removeAll { claimedGoogle.contains($0.record.sourceIdentifier) }
        }
    }
}
