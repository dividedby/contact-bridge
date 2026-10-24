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
    ///   - now: stamped on the baselines.
    public func plan(
        icloud: ICloudScan, google feed: GoogleFeed, state: SyncState, links: LinkTable, keepSeparate: Set<String> = [],
        allowMassGoogleDeletions: Bool = false, now: Date
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
        applyCap(to: &plan)
        applyGuards(to: &plan, linkedCount: max(links.links.count, state.baselines.count))

        plan.review.sort { $0.id < $1.id }
        plan.links.sort { ($0.icloudID, $0.resourceName) < ($1.icloudID, $1.resourceName) }
        plan.droppedLinks.sort()

        // Anything left waiting must be seen again next run, so the iCloud token must not move past it.
        if plan.deferred.isEmpty, plan.unlinkedWaitingForFullListing == 0, plan.waitingForNotes == 0 {
            plan.checkpoint = SyncCheckpoint(
                icloudChangeToken: icloud.changeToken, icloudContainerID: icloud.containerID, lastNotesReadAt: icloud.notesReadAt,
                googleSyncToken: feed.nextSyncToken, fieldsVersion: feed.fieldsVersion, googleAccount: feed.account,
                replacesGoogleToken: feed.isFullListing || feed.nextSyncToken != nil
            )
        }
        return plan
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
    }

    /// Judged on the full plan, before the cap.
    private func applyGuards(to plan: inout SyncPlan, linkedCount: Int) {
        let deletes = plan.deletes.count + plan.deferred.deletes
        let updates = plan.updates.count + plan.deferred.updates
        let deleteLimit = max(Double(limits.minDeletes), limits.deleteFraction * Double(linkedCount))
        let updateLimit = max(Double(limits.minUpdates), limits.updateFraction * Double(linkedCount))
        var reasons: [String] = []
        if Double(plan.droppedLinks.count) > deleteLimit {
            reasons.append("forget \(plan.droppedLinks.count) of \(linkedCount) links to contacts that are gone from both sides (more than \(Int(deleteLimit)) at once)")
        }
        if Double(deletes) > deleteLimit {
            reasons.append("delete \(deletes) of \(linkedCount) linked contacts in Google (more than \(Int(deleteLimit)) at once)")
        }
        if Double(updates) > updateLimit {
            reasons.append("update \(updates) of \(linkedCount) linked contacts in Google (more than \(Int(updateLimit)) at once)")
        }
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
                    planUnbaselined(id: id, name: name, iCloudGone: iCloudGone, googleGone: googleGone, person: person, into: &plan)
                    continue
                }
                if iCloudGone && googleGone {
                    plan.droppedLinks.append(id)
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
            id: String, name: String, iCloudGone: Bool, googleGone: Bool, person: GooglePerson?, into plan: inout SyncPlan
        ) {
            guard scanned else { return }
            guard let record = icloudByID[id] else {
                if iCloudGone { plan.droppedLinks.append(id) }
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

        private func differs(_ new: SyncBaseline, from old: SyncBaseline) -> Bool {
            var new = new
            new.syncedAt = old.syncedAt
            return new != old
        }

        private func googleChanged(_ person: GooglePerson, since baseline: SyncBaseline) -> Bool {
            ThreeWayDiff.googleChanged(person, since: baseline, at: now)
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
            // not "both edited to the same thing" is a genuine difference.
            let empty = NoteHash.hash("")
            let probe = SyncBaseline(
                icloud: ContactRecord(id: id, source: .icloud, sourceIdentifier: id),
                google: ContactRecord(id: name, source: .google, sourceIdentifier: name), googleEtag: "",
                icloudNoteHash: empty, googleNoteHash: empty, syncedAt: now
            )
            let diff = ThreeWayDiff.diff(icloud: record, google: google, base: probe, icloudNoteHash: iHash, googleNoteHash: gHash, at: now)
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
            let linkedNames = Set(links.links.values.map(\.googleResourceName))
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
