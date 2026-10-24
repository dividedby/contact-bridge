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

public struct MergeRun: Sendable {
    public var receipt: BackupReceipt
    public var outcome: MergeExecutor.Outcome
    /// The merged record as written.
    public var survivor: ContactRecord
    /// The contacts that were deleted.
    public var deleted: [ContactRecord]
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
    private let dismissals: any DismissalStoring
    private let matcher: DuplicateMatcher
    private let containerID: String?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - google: nil when signed out.
    ///   - notes: nil means notes cannot be read: previews show none and `runMerge` refuses.
    ///   - syncState: nil means sync was never set up. Once it holds an approved first sync, Clean up keeps the links of
    ///     the contacts it deletes so the sync can remove their Google copies.
    ///   - containerID: the container `store` writes to; backups must cover exactly this one.
    public init(
        store: any ContactStoring, google: (any GoogleContactsClient)?, notes: (any NotesStoring)?, backups: BackupCoordinator,
        links: any LinkStoring, syncState: (any SyncStateStoring)? = nil, dismissals: any DismissalStoring,
        matcher: DuplicateMatcher = DuplicateMatcher(), containerID: String? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.containerID = containerID
        self.store = store
        self.google = google
        self.notes = notes
        self.backups = backups
        self.links = links
        self.syncState = syncState
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
        let receipt = try await backups.freshReceipt(requiring: BackupRequirement(containerID: containerID, needsGoogle: google != nil))
        let result = try await ImportExecutor(store: store, receipt: receipt, links: links).execute(candidates, now: now())
        return ImportRun(result: result, receipt: receipt)
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

    /// Notes of the given contacts, in one read. Empty without a notes store.
    @concurrent
    public func loadNotes(ids: [String]) async throws -> [String: String] {
        guard let notes else { return [:] }
        return try await notes.fetchNotes(ids: ids)
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
        let receipt = try await backups.freshReceipt(requiring: BackupRequirement(containerID: containerID, needsNotes: true))
        return try await merge(draft, receipt: receipt)
    }

    private func merge(_ draft: MergeDraft, receipt: BackupReceipt) async throws -> MergeRun {
        let plan = draft.plan
        let deleted = draft.others
        let outcome = try await MergeExecutor(store: store, notes: notes)
            .execute(survivor: plan.merged, absorbing: draft.deleteSourceIdentifiers, backup: receipt, now: now())
        return MergeRun(receipt: receipt, outcome: outcome, survivor: plan.merged, deleted: deleted)
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
                entries[index].outcome = .merged(survivor: run.survivor, deleted: run.deleted, notes: run.outcome.notes)
                if case .writeFailed = run.outcome.notes {
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

    private func requireMembersExist(_ draft: MergeDraft) async throws {
        let present = Set(try await store.fetchAll().map(\.sourceIdentifier))
        let missing = draft.members.filter { !present.contains($0.sourceIdentifier) }
        guard missing.isEmpty else { throw WorkflowError.membersGone(names: missing.map(\.displayName)) }
    }
}
