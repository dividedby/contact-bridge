import Foundation

public enum SyncExecutorError: Error, Sendable, Equatable {
    /// Sync has not been approved, so the plan is only a preview.
    case previewPlan
    /// The plan carries a pause (the scan or feed paused, or a guard wants the user's confirmation).
    case paused(PauseReason)
    /// A creates-bearing plan was not checked against a full Google listing.
    case createsNotVerified
    /// A crashed or unresolved run left journal entries; settle them with `recoverInterruptedRun()`, then plan again.
    case interruptedRunPending(entries: Int)
}

extension SyncExecutorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .previewPlan: "Syncing has not been started yet, so nothing was changed."
        case .paused: "Syncing is paused, so nothing was changed."
        case .createsNotVerified: "New contacts were not checked against all of your Google contacts, so nothing was changed."
        case .interruptedRunPending(let count):
            "An earlier sync stopped part-way (\(count) change\(count == 1 ? "" : "s") unconfirmed). It has to be checked before syncing again."
        }
    }
}

/// What one executed plan did.
public struct SyncRunReport: Sendable {
    /// Work that was not done; the next run plans it again.
    public struct Skipped: Sendable, Hashable {
        public enum Reason: Sendable, Hashable {
            /// Google rejected it.
            case failed(String)
            /// Never sent: an earlier call hit an error that stopped the run.
            case notAttempted(String)
            /// Google changed the contact after the plan was made, and again after a second look.
            case etagChanged
            /// The change cannot be expressed as an update (nothing the mask can carry).
            case nothingToSend
            /// The Google contact is gone; the next run reports it as deleted in Google.
            case vanishedInGoogle
            /// No link and baseline say this Google contact belongs to the iCloud one, so it is never touched.
            case notLinked
            /// The iCloud contact is already linked to a Google contact (the plan is out of date).
            case alreadyLinked
            /// Could not tell whether Google applied the change; recovery will look again.
            case unconfirmed
            /// Google's answer was unclear and a look at the contact showed the change did not happen (or no longer
            /// matches what was sent). The next plan sees it again.
            case notApplied
        }

        public var icloudID: String
        public var resourceName: String?
        public var reason: Reason
    }

    /// Pairs linked and baselined (including links from an earlier import that only needed a baseline).
    public var linksAdded = 0
    public var linksDropped = 0
    public var baselinesRefreshed = 0
    public var updated = 0
    public var created = 0
    public var deleted = 0
    /// Deletes where Google no longer had the contact; the link and baseline are dropped.
    public var alreadyGone = 0
    /// Plan updates that had to be re-diffed against a newer Google version before sending.
    public var rediffed = 0
    /// Deletes turned into `deletedInICloudEditedInGoogle` review items because Google had changed the contact.
    public var reviewsAdded: [String] = []
    /// iCloud ids whose delete was held back because the review list already has an open item for them.
    public var blockedByReview: [String] = []
    public var leftForNextRun: [Skipped] = []
    /// The settled outcome of batch results that were `ambiguous`.
    public var recovery = SyncRecoveryReport()
    /// The backup the Google writes ran under; nil when nothing was written to Google.
    public var backup: BackupReceipt?
    /// Why the run stopped early (rate limit, sign-in or permission problem), if it did.
    public var halted: String?
    /// Whether `plan.checkpoint` was stored. False when work was left behind or the plan had no checkpoint.
    public var checkpointCommitted = false
    /// The checkpoint was stored without moving the iCloud change token, because a conflict is open (see `execute`).
    public var icloudTokenHeld = false
    /// Review items (ids) for conflicts found while writing: Google changed a contact after the plan was made.
    public var conflictsFound: [String] = []
    /// Housekeeping that failed without affecting the run (history, pruning).
    public var warnings: [String] = []

    public var googleWrites: Int { updated + created + deleted }
    /// Everything the plan asked for was done or deliberately held for review.
    public var isComplete: Bool { leftForNextRun.isEmpty && halted == nil }
}

/// Applies a `SyncPlan` to Google and records the results. Order: Google backup, links and baselines that need no write,
/// then updates, creates and deletes in batches of 200 sent one after the other, each written to the journal first.
///
/// - Baselines advance only after Google confirms, and take the Google half from the person Google returned (so our
///   own writes echo back as unchanged). Results that are `ambiguous` are settled by `SyncJournalRecovery`.
/// - An update whose Google contact moved on since the plan is re-diffed once against the fresh version; if it moved again
///   it is left for the next run.
/// - Before every delete the contact is fetched. If Google changed it since the baseline, or the review list has an open
///   item for it, nothing is deleted and (for the former) a `deletedInICloudEditedInGoogle` item is added instead. Only
///   Google contacts that `links.json` and a baseline tie to the deleted iCloud contact are ever deleted.
/// - The plan's checkpoint (tokens) is stored only when everything was done.
public struct SyncExecutor: Sendable {
    /// Google writes need a Google backup no older than this.
    public static let maxBackupAge: TimeInterval = 24 * 60 * 60

    /// Review kinds whose baseline keeps the pre-conflict iCloud values.
    private static let iCloudSideKinds: Set<ReviewKind> = [.googleEdited, .bothEdited]

    private let google: any GoogleContactsClient
    private let links: any LinkStoring
    private let state: any SyncStateStoring
    private let reviews: any ReviewStoring
    private let journal: any SyncJournalStoring
    private let history: any SyncHistoryStoring
    private let backups: BackupCoordinator
    private let containerID: String?
    private let now: @Sendable () -> Date
    private let recovery: SyncJournalRecovery

    public init(
        google: any GoogleContactsClient, links: any LinkStoring, state: any SyncStateStoring, reviews: any ReviewStoring,
        journal: any SyncJournalStoring, history: any SyncHistoryStoring, backups: BackupCoordinator, containerID: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.google = google
        self.links = links
        self.state = state
        self.reviews = reviews
        self.journal = journal
        self.history = history
        self.backups = backups
        self.containerID = containerID
        self.now = now
        recovery = SyncJournalRecovery(google: google, links: links, state: state, journal: journal, history: history, now: now)
    }

    /// Settles journal entries left by a crash or an unconfirmed batch. Run it at launch and before planning; a plan made
    /// before recovery may be out of date. Only reads from Google.
    public func recoverInterruptedRun() async throws -> SyncRecoveryReport {
        try await recovery.recover()
    }

    // MARK: execute

    /// - Parameter approvedDeletes: iCloud id to the Google etag the user saw and decided to delete (`deletedInICloudEditedInGoogle`).
    ///   Those deletes skip the "open review item" check and the "Google changed" check, but only for that version: if
    ///   Google's etag has moved since, nothing is deleted and the review item is refreshed instead.
    public func execute(plan: SyncPlan, approvedDeletes: [String: String] = [:]) async throws -> SyncRunReport {
        guard !plan.isPreview, try state.load().firstSyncApproved else { throw SyncExecutorError.previewPlan }
        if let pause = plan.pause { throw SyncExecutorError.paused(pause) }
        guard plan.creates.isEmpty || plan.createsVerifiedAgainstFullListing else { throw SyncExecutorError.createsNotVerified }
        // Only creates that recovery has already looked for and is holding back may stay in the journal; everything else
        // needs `recoverInterruptedRun()` first.
        let pending = try journal.load().entries
        let blocking = pending.filter { $0.kind != .create || $0.recheckedAt == nil }
        guard blocking.isEmpty else { throw SyncExecutorError.interruptedRunPending(entries: blocking.count) }
        let heldCreates = Set(pending.map(\.icloudID))

        var report = SyncRunReport()
        if plan.mutationCount > 0 {
            report.backup = try await backups.freshReceipt(
                requiring: BackupRequirement(containerID: containerID, needsGoogle: true), maxAge: Self.maxBackupAge
            )
        }
        try applyLocalChanges(of: plan, to: &report)

        try await runUpdates(plan.updates, retrying: false, reviewed: plan.review, report: &report)
        if report.halted == nil { try await runCreates(plan.creates, held: heldCreates, report: &report) }
        if report.halted == nil { try await runDeletes(plan.deletes, approved: approvedDeletes, report: &report) }

        // The iCloud change token stays as the scan read it: this executor makes no iCloud writes, and re-reading the
        // token here would swallow edits made since the scan.
        if report.isComplete, let checkpoint = plan.checkpoint {
            // A contact with a conflict held for review keeps its old iCloud values in its baseline. A later "unchanged"
            // scan would compare Google against those and report a different conflict, so while one is open every run
            // scans iCloud in full.
            let stored = try reviews.load()
            let holdsConflicts = !report.conflictsFound.isEmpty || plan.review.contains { Self.iCloudSideKinds.contains($0.kind) }
                || stored.contains { Self.iCloudSideKinds.contains($0.kind) }
            try state.update { state in
                let token = state.icloudChangeToken
                state = checkpoint.applied(to: state)
                if holdsConflicts { state.icloudChangeToken = token }
            }
            report.icloudTokenHeld = holdsConflicts
            report.checkpointCommitted = true
        }
        do { try history.prune(now: now()) } catch { report.warnings.append("Old sync history could not be cleaned up: \(error.localizedDescription)") }
        return report
    }

    // MARK: links and baselines (no Google write)

    private func applyLocalChanges(of plan: SyncPlan, to report: inout SyncRunReport) throws {
        let at = now()
        let newLinks = plan.links.filter(\.isNewLink)
        // New links go in before dropped ones come out: `LinkTable.add` takes a Google contact from its old owner, so a contact
        // that is re-pointed from a vanished iCloud id to a surviving one never has two owners or none.
        try links.add(newLinks.map {
            ImportedLink(icloudID: $0.icloudID, googleResourceName: $0.resourceName, origin: $0.origin, displayName: $0.baseline.icloud.displayName)
        }, at: at)
        try links.remove(icloudIDs: plan.droppedLinks)
        guard !plan.links.isEmpty || !plan.baselineRefreshes.isEmpty || !plan.droppedLinks.isEmpty else { return }
        try state.update { state in
            for link in plan.links { state.baselines[link.icloudID] = link.baseline }
            for (id, baseline) in plan.baselineRefreshes { state.baselines[id] = baseline }
            for id in plan.droppedLinks { state.baselines[id] = nil }
        }
        report.linksAdded = plan.links.count
        report.linksDropped = plan.droppedLinks.count
        report.baselinesRefreshed = plan.baselineRefreshes.count
    }

    // MARK: updates

    private struct PreparedUpdate {
        var update: PlannedUpdate
        var existing: GooglePerson
        var payload: GoogleUpdatePayload
        var entry: SyncJournalEntry
    }

    private func runUpdates(
        _ updates: [PlannedUpdate], retrying: Bool, reviewed: [ReviewCandidate], report: inout SyncRunReport
    ) async throws {
        for chunk in updates.chunked(into: GoogleBatchLimits.maxItemsPerCall) {
            guard report.halted == nil else {
                for update in chunk { skip(update.icloudID, update.resourceName, .notAttempted(report.halted ?? ""), &report) }
                continue
            }
            try Task.checkCancellation()

            var prepared: [PreparedUpdate] = []
            for update in chunk {
                if let item = try await prepare(update, retrying: retrying, reviewed: reviewed, report: &report) { prepared.append(item) }
            }
            guard !prepared.isEmpty else { continue }

            let at = now()
            try history.append(prepared.map {
                SyncHistoryEntry(
                    at: at, operation: .update, icloudID: $0.update.icloudID, resourceName: $0.update.resourceName,
                    before: $0.existing, after: nil, confirmed: false
                )
            })
            try journal.append(prepared.map(\.entry))
            let results = try await send(prepared.map(\.entry)) {
                try await google.batchUpdate(prepared.map {
                    GoogleContactUpdate(
                        resourceName: $0.update.resourceName, etag: $0.existing.etag ?? $0.update.etag, person: $0.payload.person,
                        updatePersonFields: $0.payload.updatePersonFields
                    )
                })
            }

            var confirmed: [(item: PreparedUpdate, person: GooglePerson)] = []
            var settled: [String] = []
            var retry: [PlannedUpdate] = []
            var unknown: [PreparedUpdate] = []
            for (index, item) in prepared.enumerated() {
                let outcome = results?[index].outcome ?? .ambiguous(reason: "Google's answer did not match the request")
                switch outcome {
                case .applied:
                    if let person = results?[index].person { confirmed.append((item, person)) } else { unknown.append(item) }
                case .failed(let error):
                    settled.append(item.entry.opID)
                    if error == .etagMismatch, !retrying {
                        retry.append(item.update)
                    } else if error == .etagMismatch {
                        skip(item.update.icloudID, item.update.resourceName, .etagChanged, &report)
                    } else if error == .notFound {
                        skip(item.update.icloudID, item.update.resourceName, .vanishedInGoogle, &report)
                    } else {
                        skip(item.update.icloudID, item.update.resourceName, .failed(error.localizedDescription), &report)
                        report.halted = report.halted ?? Self.haltReason(for: error)
                    }
                case .notAttempted(let reason):
                    settled.append(item.entry.opID)
                    skip(item.update.icloudID, item.update.resourceName, .notAttempted(reason), &report)
                    report.halted = report.halted ?? reason
                case .ambiguous:
                    unknown.append(item)
                }
            }

            if !confirmed.isEmpty {
                let confirmedAt = now()
                try state.update { state in
                    for (item, person) in confirmed {
                        state.baselines[item.update.icloudID] = item.update.baseline.afterUpdate(
                            fields: item.update.fields, returned: person, at: confirmedAt
                        )
                    }
                }
                recordConfirmations(confirmed.map {
                    SyncHistoryEntry(
                        at: confirmedAt, operation: .update, icloudID: $0.item.update.icloudID, resourceName: $0.item.update.resourceName,
                        before: $0.item.existing, after: $0.person, confirmed: true
                    )
                }, &report)
                report.updated += confirmed.count
            }
            try journal.remove(opIDs: settled + confirmed.map(\.item.entry.opID))

            if !unknown.isEmpty {
                let settledByRecovery = try await recovery.resolve(unknown.map(\.entry))
                merge(settledByRecovery, into: &report)
                report.updated += settledByRecovery.applied
                for item in unknown where settledByRecovery.outcomes[item.entry.opID] != .applied {
                    let reason: SyncRunReport.Skipped.Reason = settledByRecovery.outcomes[item.entry.opID] == .unresolved ? .unconfirmed : .notApplied
                    skip(item.update.icloudID, item.update.resourceName, reason, &report)
                }
            }

            if !retry.isEmpty {
                report.rediffed += retry.count
                try await runUpdates(retry, retrying: true, reviewed: reviewed, report: &report)
            }
        }
    }

    /// Fetches the Google contact if the plan did not list it, re-diffs when its etag moved, and builds the payload and
    /// journal entry. Nil when the update is skipped (and recorded as such).
    private func prepare(
        _ update: PlannedUpdate, retrying: Bool, reviewed: [ReviewCandidate], report: inout SyncRunReport
    ) async throws -> PreparedUpdate? {
        let existing: GooglePerson
        if !retrying, let listed = update.existing {
            existing = listed
        } else {
            do {
                existing = try await google.getPerson(resourceName: update.resourceName)
            } catch GoogleAPIError.notFound {
                skip(update.icloudID, update.resourceName, .vanishedInGoogle, &report)
                return nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skip(update.icloudID, update.resourceName, .failed(error.localizedDescription), &report)
                if let api = error as? GoogleAPIError { report.halted = report.halted ?? Self.haltReason(for: api) }
                return nil
            }
        }

        var effective = update
        if existing.etag != update.etag {
            report.rediffed += retrying ? 0 : 1
            let (redone, conflicts) = try rediff(update, against: existing, reviewed: reviewed)
            try recordConflicts(conflicts, &report)
            guard let redone else {
                skip(update.icloudID, update.resourceName, .etagChanged, &report)
                return nil
            }
            effective = redone
        }

        let payload = GooglePersonMapper.updatePayload(
            for: effective.desired, existing: existing, ownershipSourceID: effective.icloudID, restrictedTo: effective.fields, note: effective.note
        )
        guard !payload.updatePersonFields.isEmpty else {
            skip(update.icloudID, update.resourceName, .nothingToSend, &report)
            return nil
        }
        let entry = SyncJournalEntry(
            opID: UUID().uuidString, kind: .update, icloudID: effective.icloudID, resourceName: effective.resourceName,
            tag: effective.icloudID, baseEtag: existing.etag,
            payloadHash: SyncJournalEntry.projectionHash(
                of: effective.desired, fields: effective.fields, noteHash: NoteHash.hash(effective.note ?? "")
            ),
            fields: SyncField.allCases.filter(effective.fields.contains), baseline: effective.baseline
        )
        return PreparedUpdate(update: effective, existing: existing, payload: payload, entry: entry)
    }

    /// The plan's update against a newer Google version. The iCloud side is what the plan saw (its baseline carries the
    /// current values of every group that was not held for review); held groups are not pushed either way.
    ///
    /// Also returns the conflicts the newer version brings that the plan did not already report. Their iCloud fingerprint
    /// is unknown here (the plan's baseline is not the live contact), so it is left nil and the next full scan fills it in.
    private func rediff(
        _ update: PlannedUpdate, against existing: GooglePerson, reviewed: [ReviewCandidate]
    ) throws -> (update: PlannedUpdate?, conflicts: [ReviewCandidate]) {
        guard let base = try state.load().baselines[update.icloudID],
              let record = GooglePersonMapper.record(from: existing, source: .google)
        else { return (nil, []) }
        let diff = ThreeWayDiff.diff(
            icloud: update.baseline.icloud, google: record, base: base, icloudNoteHash: update.baseline.icloudNoteHash,
            googleNoteHash: GooglePersonMapper.noteHash(of: existing), googleEtag: existing.etag, at: now()
        )

        let known = Set(reviewed.filter { $0.icloudID == update.icloudID && Self.iCloudSideKinds.contains($0.kind) }.flatMap(\.fields))
        var conflicts: [ReviewCandidate] = []
        for (kind, change) in [(ReviewKind.googleEdited, FieldChange.googleEdited), (.bothEdited, .bothEditedDifferent)] {
            let fields = diff.reviewFields.filter { !known.contains($0) && diff.changes[$0] == change }
            guard !fields.isEmpty else { continue }
            conflicts.append(ReviewCandidate(
                kind: kind, icloudID: update.icloudID, resourceName: update.resourceName, googleEtag: existing.etag, fields: fields
            ))
        }

        guard diff.needsPush, !diff.pushFields.contains(.note) || update.note != nil else { return (nil, conflicts) }
        var redone = update
        redone.etag = existing.etag ?? update.etag
        redone.existing = existing
        redone.fields = diff.pushFields
        redone.desired = diff.desiredGoogle
        redone.note = diff.pushFields.contains(.note) ? update.note : nil
        redone.baseline = diff.updatedBaseline
        return (redone, conflicts)
    }

    /// Conflicts found while writing become review items (unless the list already has them) and keep the iCloud token
    /// from moving.
    private func recordConflicts(_ conflicts: [ReviewCandidate], _ report: inout SyncRunReport) throws {
        let stored = Set(try reviews.load().map(\.id))
        let fresh = conflicts.filter { !stored.contains($0.id) }
        if !fresh.isEmpty { try reviews.add(fresh, at: now()) }
        for conflict in conflicts where !report.conflictsFound.contains(conflict.id) { report.conflictsFound.append(conflict.id) }
    }

    // MARK: creates

    private struct PreparedCreate {
        var create: PlannedCreate
        var person: GooglePerson
        var entry: SyncJournalEntry
    }

    private func runCreates(_ creates: [PlannedCreate], held: Set<String>, report: inout SyncRunReport) async throws {
        let linked = try links.load().links
        for chunk in creates.chunked(into: GoogleBatchLimits.maxItemsPerCall) {
            guard report.halted == nil else {
                for create in chunk { skip(create.icloudID, nil, .notAttempted(report.halted ?? ""), &report) }
                continue
            }
            try Task.checkCancellation()

            let at = now()
            var prepared: [PreparedCreate] = []
            for create in chunk {
                // An earlier attempt may have been applied and not listed yet: creating again could duplicate it.
                guard !held.contains(create.icloudID) else {
                    skip(create.icloudID, nil, .unconfirmed, &report)
                    continue
                }
                guard linked[create.icloudID] == nil else {
                    skip(create.icloudID, nil, .alreadyLinked, &report)
                    continue
                }
                var person = GooglePersonMapper.createPayload(for: create.record, ownershipSourceID: create.icloudID)
                if let note = create.note { GooglePersonMapper.setNote(note, on: &person) }
                let baseline = SyncBaseline(
                    icloud: create.record, google: ContactRecord(id: "", source: .google, sourceIdentifier: ""), googleEtag: "",
                    icloudNoteHash: create.icloudNoteHash, googleNoteHash: create.icloudNoteHash, syncedAt: at
                )
                let entry = SyncJournalEntry(
                    opID: UUID().uuidString, kind: .create, icloudID: create.icloudID, resourceName: nil, tag: create.icloudID,
                    baseEtag: nil, payloadHash: ContactFingerprint.of(create.record), fields: [], baseline: baseline, attemptedAt: at
                )
                prepared.append(PreparedCreate(create: create, person: person, entry: entry))
            }
            guard !prepared.isEmpty else { continue }

            try journal.append(prepared.map(\.entry))
            let results = try await send(prepared.map(\.entry)) { try await google.batchCreate(prepared.map(\.person)) }

            var confirmed: [(item: PreparedCreate, person: GooglePerson, name: String)] = []
            var settled: [String] = []
            var unknown: [PreparedCreate] = []
            for (index, item) in prepared.enumerated() {
                let outcome = results?[index].outcome ?? .ambiguous(reason: "Google's answer did not match the request")
                switch outcome {
                case .applied:
                    if let person = results?[index].person, let name = person.resourceName {
                        confirmed.append((item, person, name))
                    } else {
                        unknown.append(item)
                    }
                case .failed(let error):
                    settled.append(item.entry.opID)
                    skip(item.create.icloudID, nil, .failed(error.localizedDescription), &report)
                    report.halted = report.halted ?? Self.haltReason(for: error)
                case .notAttempted(let reason):
                    settled.append(item.entry.opID)
                    skip(item.create.icloudID, nil, .notAttempted(reason), &report)
                    report.halted = report.halted ?? reason
                case .ambiguous:
                    unknown.append(item)
                }
            }

            if !confirmed.isEmpty {
                let confirmedAt = now()
                // The link first: a crash between the two leaves a link without a baseline, which the next plan adopts.
                try links.add(confirmed.map {
                    ImportedLink(
                        icloudID: $0.item.create.icloudID, googleResourceName: $0.name, origin: .createdInGoogle,
                        displayName: $0.item.create.record.displayName
                    )
                }, at: confirmedAt)
                try state.update { state in
                    for (item, person, _) in confirmed {
                        state.baselines[item.create.icloudID] = (item.entry.baseline ?? SyncBaseline(
                            icloud: item.create.record, google: ContactRecord(id: "", source: .google, sourceIdentifier: ""),
                            googleEtag: "", icloudNoteHash: item.create.icloudNoteHash, syncedAt: confirmedAt
                        )).afterCreate(returned: person, at: confirmedAt)
                    }
                }
                report.created += confirmed.count
            }
            try journal.remove(opIDs: settled + confirmed.map(\.item.entry.opID))

            if !unknown.isEmpty {
                let settledByRecovery = try await recovery.resolve(unknown.map(\.entry))
                merge(settledByRecovery, into: &report)
                report.created += settledByRecovery.applied
                for item in unknown where settledByRecovery.outcomes[item.entry.opID] != .applied {
                    let reason: SyncRunReport.Skipped.Reason = settledByRecovery.outcomes[item.entry.opID] == .unresolved ? .unconfirmed : .notApplied
                    skip(item.create.icloudID, nil, reason, &report)
                }
            }
        }
    }

    // MARK: deletes

    private func runDeletes(_ deletes: [PlannedDelete], approved: [String: String], report: inout SyncRunReport) async throws {
        for chunk in deletes.chunked(into: GoogleBatchLimits.maxItemsPerCall) {
            guard report.halted == nil else {
                for delete in chunk { skip(delete.icloudID, delete.resourceName, .notAttempted(report.halted ?? ""), &report) }
                continue
            }
            try Task.checkCancellation()

            let linked = try links.load().links
            let baselines = try state.load().baselines
            let open = try reviews.load()
            var candidates: [ReviewCandidate] = []
            var gone: [String] = []
            var doomed: [(delete: PlannedDelete, person: GooglePerson, baseline: SyncBaseline)] = []

            for delete in chunk {
                guard linked[delete.icloudID]?.googleResourceName == delete.resourceName, let baseline = baselines[delete.icloudID] else {
                    skip(delete.icloudID, delete.resourceName, .notLinked, &report)
                    continue
                }
                if approved[delete.icloudID] == nil,
                   open.contains(where: { $0.concerns(icloudID: delete.icloudID, resourceName: delete.resourceName) }) {
                    report.blockedByReview.append(delete.icloudID)
                    continue
                }
                let person: GooglePerson
                do {
                    person = try await google.getPerson(resourceName: delete.resourceName)
                } catch GoogleAPIError.notFound {
                    gone.append(delete.icloudID)
                    continue
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    skip(delete.icloudID, delete.resourceName, .failed(error.localizedDescription), &report)
                    if let api = error as? GoogleAPIError { report.halted = report.halted ?? Self.haltReason(for: api) }
                    continue
                }
                let changed: Bool
                if let approvedEtag = approved[delete.icloudID] {
                    changed = person.etag != approvedEtag
                } else {
                    changed = ThreeWayDiff.googleChanged(person, since: baseline, at: now())
                }
                if changed {
                    candidates.append(ReviewCandidate(
                        kind: .deletedInICloudEditedInGoogle, icloudID: delete.icloudID, resourceName: delete.resourceName, googleEtag: person.etag
                    ))
                } else {
                    doomed.append((delete, person, baseline))
                }
            }

            if !candidates.isEmpty {
                try reviews.add(candidates, at: now())
                report.reviewsAdded += candidates.map(\.id)
            }
            if !gone.isEmpty {
                try dropLinks(gone)
                report.alreadyGone += gone.count
            }
            guard !doomed.isEmpty else { continue }

            let at = now()
            let entries = doomed.map {
                SyncJournalEntry(
                    opID: UUID().uuidString, kind: .delete, icloudID: $0.delete.icloudID, resourceName: $0.delete.resourceName,
                    tag: $0.delete.icloudID, baseEtag: $0.person.etag, payloadHash: nil, fields: [], baseline: $0.baseline
                )
            }
            try history.append(doomed.map {
                SyncHistoryEntry(
                    at: at, operation: .delete, icloudID: $0.delete.icloudID, resourceName: $0.delete.resourceName,
                    before: $0.person, after: nil, confirmed: false
                )
            })
            try journal.append(entries)
            let results = try await send(entries) { try await google.batchDelete(doomed.map(\.delete.resourceName)) }

            var removed: [String] = []
            var settled: [String] = []
            var unknown: [SyncJournalEntry] = []
            for (index, item) in doomed.enumerated() {
                let entry = entries[index]
                let outcome = results?[index].outcome ?? .ambiguous(reason: "Google's answer did not match the request")
                switch outcome {
                case .applied:
                    removed.append(item.delete.icloudID)
                    settled.append(entry.opID)
                    report.deleted += 1
                case .failed(.notFound):
                    removed.append(item.delete.icloudID)
                    settled.append(entry.opID)
                    report.alreadyGone += 1
                case .failed(let error):
                    settled.append(entry.opID)
                    skip(item.delete.icloudID, item.delete.resourceName, .failed(error.localizedDescription), &report)
                    report.halted = report.halted ?? Self.haltReason(for: error)
                case .notAttempted(let reason):
                    settled.append(entry.opID)
                    skip(item.delete.icloudID, item.delete.resourceName, .notAttempted(reason), &report)
                    report.halted = report.halted ?? reason
                case .ambiguous:
                    unknown.append(entry)
                }
            }
            if !removed.isEmpty {
                try dropLinks(removed)
                recordConfirmations(doomed.filter { removed.contains($0.delete.icloudID) }.map {
                    SyncHistoryEntry(
                        at: now(), operation: .delete, icloudID: $0.delete.icloudID, resourceName: $0.delete.resourceName,
                        before: $0.person, after: nil, confirmed: true
                    )
                }, &report)
            }
            try journal.remove(opIDs: settled)

            if !unknown.isEmpty {
                let settledByRecovery = try await recovery.resolve(unknown)
                merge(settledByRecovery, into: &report)
                report.deleted += settledByRecovery.applied
                for entry in unknown where settledByRecovery.outcomes[entry.opID] != .applied {
                    let reason: SyncRunReport.Skipped.Reason = settledByRecovery.outcomes[entry.opID] == .unresolved ? .unconfirmed : .notApplied
                    skip(entry.icloudID, entry.resourceName, reason, &report)
                }
            }
        }
    }

    /// A contact that is gone from both sides: its link and baseline go.
    private func dropLinks(_ icloudIDs: [String]) throws {
        try links.remove(icloudIDs: icloudIDs)
        try state.update { state in
            for id in icloudIDs { state.baselines[id] = nil }
        }
    }

    // MARK: shared

    /// Sends one batch. `GoogleBatchError` means the request was refused before anything was sent, so its entries come
    /// back out of the journal; any other thrown error (cancellation, say) may have happened mid-flight, so they stay for
    /// recovery. Nil when Google's answer has the wrong number of results, which callers treat as unconfirmed.
    private func send(_ entries: [SyncJournalEntry], _ call: () async throws -> [GoogleBatchResult]) async throws -> [GoogleBatchResult]? {
        do {
            let results = try await call()
            return results.count == entries.count ? results : nil
        } catch let error as GoogleBatchError {
            try? journal.remove(opIDs: entries.map(\.opID))
            throw error
        }
    }

    private func skip(_ icloudID: String, _ resourceName: String?, _ reason: SyncRunReport.Skipped.Reason, _ report: inout SyncRunReport) {
        report.leftForNextRun.append(SyncRunReport.Skipped(icloudID: icloudID, resourceName: resourceName, reason: reason))
    }

    /// The confirmation lines are a convenience: the attempt line already holds the "before", so a failure here only warns.
    private func recordConfirmations(_ entries: [SyncHistoryEntry], _ report: inout SyncRunReport) {
        do { try history.append(entries) } catch { report.warnings.append("The sync history could not be updated: \(error.localizedDescription)") }
    }

    private func merge(_ settled: SyncRecoveryReport, into report: inout SyncRunReport) {
        report.recovery.applied += settled.applied
        report.recovery.notApplied += settled.notApplied
        report.recovery.unresolved += settled.unresolved
        report.recovery.outcomes.merge(settled.outcomes) { first, _ in first }
    }

    /// Errors after which every later call would fail the same way.
    private static func haltReason(for error: GoogleAPIError) -> String? {
        switch error {
        case .rateLimited, .unauthorized: error.localizedDescription
        case .other(403, _): error.localizedDescription
        default: nil
        }
    }
}
