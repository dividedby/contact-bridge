import Foundation

public struct DuplicateScan: Sendable {
    /// Every iCloud record that was analyzed.
    public var records: [ContactRecord]
    /// Not dismissed, in the matcher's order.
    public var clusters: [DuplicateCluster]
    public var hiddenCount: Int
    public var diagnostics: MatchDiagnostics
}

public struct ImportRun: Sendable {
    public var result: ImportResult
    public var receipt: BackupReceipt
}

/// What a merge did about the Google links of the contacts it deleted. The merge itself stands whatever happened here.
public struct MergeLinkOutcome: Sendable, Equatable {
    /// 1 when a deleted contact's Google link was given to the survivor (it then keeps syncing as the same Google contact).
    public var linksMoved = 0
    /// Other Google copies of the person that the merge leaves alone: their links are gone and nothing will delete them.
    public var googleCopiesLeft = 0
    /// Other Google copies whose link was kept because sync is on: the next sync deletes them (guarded, like Clean up).
    public var googleRemovalsPending = 0
    /// What tidying up the links did not manage. The merge is done regardless.
    public var followUpWarnings: [String] = []

    public init(linksMoved: Int = 0, googleCopiesLeft: Int = 0, googleRemovalsPending: Int = 0, followUpWarnings: [String] = []) {
        self.linksMoved = linksMoved
        self.googleCopiesLeft = googleCopiesLeft
        self.googleRemovalsPending = googleRemovalsPending
        self.followUpWarnings = followUpWarnings
    }
}

public struct MergeRun: Sendable {
    public var receipt: BackupReceipt
    public var outcome: MergeExecutor.Outcome
    /// The merged record as written.
    public var survivor: ContactRecord
    /// The contacts that were deleted.
    public var deleted: [ContactRecord]
    public var links = MergeLinkOutcome()

    public var linksMoved: Int { links.linksMoved }
    public var googleCopiesLeft: Int { links.googleCopiesLeft }
    public var googleRemovalsPending: Int { links.googleRemovalsPending }
    public var followUpWarnings: [String] { links.followUpWarnings }
}

/// What to do with the Google links of a merge's deleted contacts (`ContactWorkflows.linkCarryOver`).
public struct LinkCarryPlan: Sendable, Equatable {
    /// A deleted contact's link that the survivor takes over.
    public struct Moved: Sendable, Equatable {
        public var from: String
        public var googleResourceName: String
        public var origin: LinkOrigin?
    }

    public var moved: Moved?
    /// The survivor's baseline, from the contact whose link moved: its iCloud half is that contact's, with the survivor's
    /// ids, so the next sync sees the merged data as an ordinary iCloud edit and pushes it. Nil when sync is off or the
    /// moved link had no baseline yet (a later sync takes one from both sides).
    public var survivorBaseline: SyncBaseline?
    /// Deleted contacts whose link and baseline go: the moved one's (cleared with the baseline moved) and links with no
    /// Google copy the sync could safely delete.
    public var linksToRemove: [String] = []
    /// Deleted contacts whose link and baseline stay, because sync is on: the next sync deletes their Google copy.
    public var keptForSync: [String] = []
    /// Links removed without their Google copy being deleted.
    public var googleCopiesLeft: Int { linksToRemove.count - (moved == nil ? 0 : 1) }
}

/// What a bulk delete is doing, for progress display.
public enum CleanupPhase: Sendable, Equatable {
    case backingUp
    case deleting
}

public struct CleanupRun: Sendable {
    /// The brand-new backup (with notes) taken just before the delete.
    public var receipt: BackupReceipt
    public var deletedIDs: [String]
    /// Import links dropped because their contact is gone.
    public var linksRemoved: Int
    /// Linked contacts whose link was kept because sync is on: the next sync deletes their Google copy and then drops the
    /// link. Show "Also removed from Google on the next sync" when this is not zero.
    public var googleRemovalsPending: Int
    /// Dismissed "not duplicates" groups that mentioned a deleted contact and were trimmed or dropped.
    public var dismissalsPruned: Int
    /// The contacts are deleted regardless; these say what tidying afterwards did not work.
    public var followUpWarnings: [String]

    public var deletedCount: Int { deletedIDs.count }
}

public enum WorkflowError: Error, Sendable, Equatable {
    case nothingToMerge
    case nothingToDelete
    /// Merging and deleting remove contacts, and their notes would be lost without being read first.
    case notesUnavailable
    /// Bulk merge only takes groups that need no decisions; these (by cluster id) have conflicts to look at.
    case needsReview(groupIDs: [String])
    /// A group's contacts changed since it was found, so it was left alone.
    case membersGone(names: [String])
}

extension WorkflowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nothingToMerge: "A merge needs at least two contacts. Use Not duplicates instead."
        case .nothingToDelete: "Tick at least one contact to delete."
        case .notesUnavailable:
            "Merging and deleting need notes access, so notes on the contacts that get deleted are kept. Grant notes access in Setup, then try again."
        case .needsReview(let ids):
            "\(ids.count == 1 ? "1 group needs" : "\(ids.count) groups need") a closer look before merging. Open them one at a time instead."
        case .membersGone(let names):
            "\(names.joined(separator: ", ")) \(names.count == 1 ? "is" : "are") no longer in your address book, so this group was left as it is. Reload and look again."
        }
    }
}

/// The Phase 1 operations the screens run, each doing its work off the caller's actor. Every mutation first gets a
/// fresh backup from the `BackupCoordinator` (taking one if the last is older than an hour).
public struct ContactWorkflows: Sendable {
    private let store: any ContactStoring
    private let google: (any GoogleContactsClient)?
    private let notes: (any NotesStoring)?
    private let backups: BackupCoordinator
    private let links: any LinkStoring
    private let syncState: (any SyncStateStoring)?
    private let gate: WriteGate?
    private let dismissals: any DismissalStoring
    private let matcher: DuplicateMatcher
    private let containerID: String?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - google: nil when signed out.
    ///   - notes: nil means notes cannot be read: previews show none and `runMerge` refuses.
    ///   - syncState: nil means sync was never set up. Once it holds an approved first sync, Clean up keeps the links of
    ///     the contacts it deletes so the sync can remove their Google copies.
    ///   - gate: the write gate shared with the sync engine. Import, Merge (single and bulk) and Clean up run inside it, so
    ///     they never interleave with a sync run. Nil means no sync engine to wait for.
    ///   - containerID: the container `store` writes to; backups must cover exactly this one.
    public init(
        store: any ContactStoring, google: (any GoogleContactsClient)?, notes: (any NotesStoring)?, backups: BackupCoordinator,
        links: any LinkStoring, syncState: (any SyncStateStoring)? = nil, gate: WriteGate? = nil, dismissals: any DismissalStoring,
        matcher: DuplicateMatcher = DuplicateMatcher(), containerID: String? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.containerID = containerID
        self.store = store
        self.google = google
        self.notes = notes
        self.backups = backups
        self.links = links
        self.syncState = syncState
        self.gate = gate
        self.dismissals = dismissals
        self.matcher = matcher
        self.now = now
    }

    // MARK: import

    @concurrent
    public func loadImportPlan() async throws -> ImportPlan {
        guard let google else { throw GoogleAuthError.notSignedIn }
        let records = try await store.fetchAll()
        let connections = try await google.allConnections()
        let others = try await google.allOtherContacts()
        let known = Dictionary(try links.load().links.map { ($0.value.googleResourceName, $0.key) }, uniquingKeysWith: min)
        return ImportPlanner(matcher: matcher).plan(
            icloud: records, googleConnections: connections, googleOtherContacts: others, knownLinks: known
        )
    }

    /// Creates the selected candidates after making sure a fresh backup exists.
    @concurrent
    public func runImport(_ candidates: [ImportCandidate]) async throws -> ImportRun {
        try await exclusively {
            let receipt = try await backups.freshReceipt(requiring: BackupRequirement(containerID: containerID, needsGoogle: google != nil))
            let result = try await ImportExecutor(store: store, receipt: receipt, links: links).execute(candidates, now: now())
            return ImportRun(result: result, receipt: receipt)
        }
    }

    // MARK: dedupe

    @concurrent
    public func loadDuplicates() async throws -> DuplicateScan {
        let records = try await store.fetchAll()
        let analysis = matcher.analyze(records)
        let visible = try dismissals.load().visible(from: analysis.clusters)
        return DuplicateScan(
            records: records, clusters: visible, hiddenCount: analysis.clusters.count - visible.count, diagnostics: analysis.diagnostics
        )
    }

    /// Notes of the given contacts that have one, in one read. Empty without a notes store.
    @concurrent
    public func loadNotes(ids: [String]) async throws -> [String: String] {
        guard let notes else { return [:] }
        return try await notes.fetchNotes(ids: ids).filter { !$0.value.isEmpty }
    }

    /// Never offer this group again (until `restoreDismissed`): the members still in the draft, not ones the user left out.
    public func dismiss(_ draft: MergeDraft) throws {
        try dismissals.dismiss(memberIDs: draft.members.map(\.id), at: now())
    }

    public func restoreDismissed() throws {
        try dismissals.clear()
    }

    /// Several groups in one atomic write: the members still in each draft, as `dismiss(_:)` does for one.
    public func dismiss(_ drafts: [MergeDraft]) throws {
        try dismissals.dismiss(groups: drafts.map { $0.members.map(\.id) }, at: now())
    }

    /// Merges the draft's survivor with the others after a fresh backup that includes notes. Throws before doing anything
    /// if there is no notes store; if notes cannot be read, nothing is merged.
    @concurrent
    public func runMerge(_ draft: MergeDraft) async throws -> MergeRun {
        guard draft.canMerge else { throw WorkflowError.nothingToMerge }
        guard notes != nil else { throw WorkflowError.notesUnavailable }
        return try await exclusively {
            let receipt = try await backups.freshReceipt(requiring: BackupRequirement(containerID: containerID, needsNotes: true))
            return try await merge(draft, receipt: receipt)
        }
    }

    private func merge(_ draft: MergeDraft, receipt: BackupReceipt) async throws -> MergeRun {
        let plan = draft.plan
        let deleted = draft.others
        let survivorID = plan.merged.sourceIdentifier
        let loserIDs = draft.deleteSourceIdentifiers
        // Read before anything changes, as Clean up does: if either file is unreadable, nothing is merged.
        let table = try links.load()
        let state = try syncState?.load()
        let carry = Self.linkCarryOver(survivorID: survivorID, loserIDs: loserIDs, table: table, state: state)

        let outcome = try await MergeExecutor(store: store, notes: notes)
            .execute(survivor: plan.merged, absorbing: loserIDs, backup: receipt, now: now())
        var run = MergeRun(receipt: receipt, outcome: outcome, survivor: plan.merged, deleted: deleted)
        run.links = applyLinkCarry(carry, survivor: plan.merged)
        return run
    }

    /// The merge is done; the links follow it. A failure here is reported, never thrown.
    private func applyLinkCarry(_ carry: LinkCarryPlan, survivor: ContactRecord) -> MergeLinkOutcome {
        var result = MergeLinkOutcome(googleCopiesLeft: carry.googleCopiesLeft, googleRemovalsPending: carry.keptForSync.count)
        guard carry.moved != nil || !carry.linksToRemove.isEmpty else { return result }
        do {
            if let moved = carry.moved {
                // `add` takes the Google contact away from its old owner, so there is never a moment with two.
                try links.add([ImportedLink(
                    icloudID: survivor.sourceIdentifier, googleResourceName: moved.googleResourceName, origin: moved.origin ?? .imported,
                    displayName: survivor.displayName
                )], at: now())
                result.linksMoved = 1
            }
            try links.remove(icloudIDs: carry.linksToRemove)
            if let moved = carry.moved, let baseline = carry.survivorBaseline, let syncState {
                // One write, so the baseline is never both gone and not yet on the survivor.
                try syncState.update { state in
                    state.baselines[moved.from] = nil
                    state.baselines[survivor.sourceIdentifier] = baseline
                    // The opt-out is about the person, not the contact: it follows the baseline to the survivor.
                    if state.profilePhotoOptOut.remove(moved.from) != nil { state.profilePhotoOptOut.insert(survivor.sourceIdentifier) }
                }
            }
        } catch {
            result.followUpWarnings.append("The contacts are merged, but their Google links could not be updated: \(error.localizedDescription)")
        }
        return result
    }

    /// Decides what happens to the Google links of the contacts a merge deletes. Pure.
    ///
    /// - The survivor has no link and a deleted contact has: the survivor takes over one deleted contact's link (the one with
    ///   a baseline, then the oldest, then the lowest id), keeping its origin, so the same Google contact keeps syncing. With
    ///   sync on, that contact's baseline moves to the survivor.
    /// - Any other linked deleted contact (or all of them, if the survivor was linked already) points at another Google copy of
    ///   the same person; the survivor's link wins. With sync on, a copy the sync can safely delete (one with a baseline) keeps
    ///   its link and baseline so the next sync deletes it, as it does after Clean up. Otherwise the link goes and Google is left
    ///   alone (`googleCopiesLeft`).
    public static func linkCarryOver(survivorID: String, loserIDs: [String], table: LinkTable, state: SyncState?) -> LinkCarryPlan {
        var plan = LinkCarryPlan()
        let syncOn = state?.firstSyncApproved == true
        let linked = Set(loserIDs).subtracting([survivorID]).filter { table.links[$0] != nil }.sorted()
        guard !linked.isEmpty else { return plan }

        var others = linked
        if table.links[survivorID] == nil, let mover = linked.min(by: { lhs, rhs in
            let l = (state?.baselines[lhs] == nil ? 1 : 0, table.links[lhs]?.linkedAt ?? .distantFuture, lhs)
            let r = (state?.baselines[rhs] == nil ? 1 : 0, table.links[rhs]?.linkedAt ?? .distantFuture, rhs)
            return l < r
        }), let entry = table.links[mover] {
            plan.moved = LinkCarryPlan.Moved(from: mover, googleResourceName: entry.googleResourceName, origin: entry.origin)
            plan.linksToRemove.append(mover)
            if syncOn, var baseline = state?.baselines[mover] {
                baseline.icloud.id = survivorID
                baseline.icloud.sourceIdentifier = survivorID
                plan.survivorBaseline = baseline
            }
            others.removeAll { $0 == mover }
        }
        for id in others {
            if syncOn, state?.baselines[id] != nil { plan.keptForSync.append(id) } else { plan.linksToRemove.append(id) }
        }
        return plan
    }

    /// Merges the groups one after another, each with the suggested survivor and values, behind one brand-new backup that
    /// includes notes (taken even if a recent one exists). Throws before doing anything for a group that `needsReview`, one
    /// that cannot merge, or when there is no notes store; everything after that is in the report, never thrown.
    ///
    /// Stops at the first problem: a group whose members are no longer all there, a failed merge, or a merge whose combined
    /// note could not be saved. Groups after it are `notRun`. `isCancelled` is asked before each group, so a stop takes
    /// effect after the current one. A run that outlives the backup's freshness takes another backup between groups.
    @concurrent
    public func runBulkMerge(
        _ drafts: [MergeDraft], progress: @escaping @Sendable (BulkProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> BulkMergeReport {
        try await exclusively { try await bulkMerge(drafts, progress: progress, isCancelled: isCancelled) }
    }

    private func bulkMerge(
        _ drafts: [MergeDraft], progress: @escaping @Sendable (BulkProgress) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> BulkMergeReport {
        guard !drafts.isEmpty, drafts.allSatisfy(\.canMerge) else { throw WorkflowError.nothingToMerge }
        guard notes != nil else { throw WorkflowError.notesUnavailable }
        let review = drafts.filter { $0.bulkEligibility == .needsReview }
        guard review.isEmpty else { throw WorkflowError.needsReview(groupIDs: review.map(\.cluster.id)) }

        let total = drafts.count
        var entries = drafts.map { BulkMergeReport.Entry(draft: $0, outcome: .notRun) }
        let requirement = BackupRequirement(containerID: containerID, needsNotes: true)

        progress(BulkProgress(phase: .backingUp, completed: 0, total: total))
        var receipts: [BackupReceipt]
        do {
            receipts = [try await backups.newBackup(requiring: requirement)]
        } catch {
            return BulkMergeReport(entries: entries, stop: .backupFailed(reason: error.localizedDescription), receipts: [])
        }

        var stop = BulkMergeReport.Stop.completed
        for index in drafts.indices {
            if isCancelled() || Task.isCancelled {
                stop = .stoppedByUser
                break
            }
            progress(BulkProgress(phase: .merging, completed: index, total: total))
            let draft = drafts[index]
            do {
                try await requireMembersExist(draft)
                // The cached receipt is the one just taken; this only differs once it has aged out.
                let receipt = try await backups.freshReceipt(requiring: requirement)
                if receipt != receipts.last { receipts.append(receipt) }
                let run = try await merge(draft, receipt: receipt)
                entries[index].outcome = .merged(survivor: run.survivor, deleted: run.deleted, notes: run.outcome.notes, links: run.links)
                if case .writeFailed = run.outcome.notes {
                    stop = .stoppedOnProblem
                    break
                }
                if !run.links.followUpWarnings.isEmpty {
                    stop = .stoppedOnProblem
                    break
                }
            } catch {
                entries[index].outcome = .failed(reason: error.localizedDescription)
                stop = .stoppedOnProblem
                break
            }
        }
        progress(BulkProgress(phase: .merging, completed: entries.count { $0.outcome != .notRun }, total: total))
        return BulkMergeReport(entries: entries, stop: stop, receipts: receipts)
    }

    // MARK: clean up

    /// Every contact as a Clean up row, sorted by name.
    @concurrent
    public func loadCleanupRows() async throws -> [CleanupRow] {
        let records = try await store.fetchAll()
        let imported = Set(try links.load().links.filter { $0.value.effectiveOrigin == .imported }.keys)
        return records.map { CleanupRow(record: $0, isImported: imported.contains($0.sourceIdentifier)) }
            .sorted {
                let order = $0.displayName.localizedStandardCompare($1.displayName)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    /// Deletes the contacts (by store identifier) in one all-or-nothing call, after a brand-new backup that includes notes
    /// (taken even if a recent one exists). Throws before deleting anything if there is no notes store, a contact is no
    /// longer there, or the backup fails.
    ///
    /// Afterwards the deleted ids leave the import links and the dismissed groups. If that tidying fails the deletion still
    /// stands: the run reports it in `followUpWarnings` instead of throwing.
    ///
    /// Once sync is approved (`SyncState.firstSyncApproved`) the links stay: the sync deletes the Google copy of a linked
    /// contact that is gone from iCloud and only then drops the link and baseline (`googleRemovalsPending` counts them).
    /// Contacts that never synced, and every contact before sync was approved, lose their link as before.
    @concurrent
    public func deleteContacts(ids: [String], progress: @escaping @Sendable (CleanupPhase) -> Void = { _ in }) async throws -> CleanupRun {
        try await exclusively { try await deleteNow(ids: ids, progress: progress) }
    }

    private func deleteNow(ids: [String], progress: @escaping @Sendable (CleanupPhase) -> Void) async throws -> CleanupRun {
        var seen = Set<String>()
        let ids = ids.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { throw WorkflowError.nothingToDelete }
        guard notes != nil else { throw WorkflowError.notesUnavailable }
        let present = Set(try await store.fetchAll().map(\.sourceIdentifier))
        let missing = ids.filter { !present.contains($0) }
        guard missing.isEmpty else { throw ContactStoreError.notFound(missing) }
        // Decided before anything is deleted: if the state cannot be read, nothing changes.
        let state = try syncState?.load()
        let syncOn = state?.firstSyncApproved == true

        progress(.backingUp)
        let receipt = try await backups.newBackup(requiring: BackupRequirement(containerID: containerID, needsNotes: true))
        progress(.deleting)
        try await store.delete(ids: ids, backup: receipt)

        var run = CleanupRun(receipt: receipt, deletedIDs: ids, linksRemoved: 0, googleRemovalsPending: 0, dismissalsPruned: 0, followUpWarnings: [])
        do {
            let table = try links.load()
            let linked = Set(table.links.keys).intersection(ids)
            let kept = syncOn ? Self.googleCopiesToRemove(among: linked, state: state) : []
            run.googleRemovalsPending = kept.count
            let removable = ids.filter { linked.contains($0) && !kept.contains($0) }
            if !removable.isEmpty {
                try links.remove(icloudIDs: removable)
                run.linksRemoved = removable.count
            }
        } catch {
            run.followUpWarnings.append("The contacts are deleted, but their import links could not be removed: \(error.localizedDescription)")
        }
        do {
            run.dismissalsPruned = try dismissals.forget(ids: ids)
        } catch {
            run.followUpWarnings.append("The contacts are deleted, but the groups you marked as not duplicates could not be updated: \(error.localizedDescription)")
        }
        return run
    }

    /// How many of these contacts would also be removed from Google by the next sync if deleted now: linked contacts with
    /// a baseline, once sync is approved. Zero before that. The Clean up screen shows "Also removed from Google on the next
    /// sync" when this is not zero.
    public func googleRemovalsPending(ifDeleting ids: [String]) throws -> Int {
        guard let state = try syncState?.load(), state.firstSyncApproved else { return 0 }
        return Self.googleCopiesToRemove(among: Set(try links.load().links.keys).intersection(ids), state: state).count
    }

    /// A link without a baseline has no Google copy the sync could delete safely; it goes with the contact.
    private static func googleCopiesToRemove(among linked: Set<String>, state: SyncState?) -> Set<String> {
        linked.filter { state?.baselines[$0] != nil }
    }

    /// Runs `body` inside the write gate, if there is one.
    private func exclusively<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        guard let gate else { return try await body() }
        return try await gate.withLock(body)
    }

    private func requireMembersExist(_ draft: MergeDraft) async throws {
        let present = Set(try await store.fetchAll().map(\.sourceIdentifier))
        let missing = draft.members.filter { !present.contains($0.sourceIdentifier) }
        guard missing.isEmpty else { throw WorkflowError.membersGone(names: missing.map(\.displayName)) }
    }
}
