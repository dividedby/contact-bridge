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

public enum WorkflowError: Error, Sendable, Equatable {
    case nothingToMerge
    /// Merging deletes contacts, and their notes would be lost without being read first.
    case notesUnavailable
}

extension WorkflowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nothingToMerge: "A merge needs at least two contacts. Use Not duplicates instead."
        case .notesUnavailable:
            "Merging needs notes access, so notes on the contacts that get deleted are kept. Grant notes access in Setup, then try again."
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
    private let dismissals: any DismissalStoring
    private let matcher: DuplicateMatcher
    private let containerID: String?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - google: nil when signed out.
    ///   - notes: nil means notes cannot be read: previews show none and `runMerge` refuses.
    ///   - containerID: the container `store` writes to; backups must cover exactly this one.
    public init(
        store: any ContactStoring, google: (any GoogleContactsClient)?, notes: (any NotesStoring)?, backups: BackupCoordinator,
        links: any LinkStoring, dismissals: any DismissalStoring, matcher: DuplicateMatcher = DuplicateMatcher(),
        containerID: String? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.containerID = containerID
        self.store = store
        self.google = google
        self.notes = notes
        self.backups = backups
        self.links = links
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
        return ImportPlanner(matcher: matcher).plan(icloud: records, googleConnections: connections, googleOtherContacts: others)
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

    /// Merges the draft's survivor with the others after a fresh backup that includes notes. Throws before doing anything
    /// if there is no notes store; if notes cannot be read, nothing is merged.
    @concurrent
    public func runMerge(_ draft: MergeDraft) async throws -> MergeRun {
        guard draft.canMerge else { throw WorkflowError.nothingToMerge }
        guard notes != nil else { throw WorkflowError.notesUnavailable }
        let receipt = try await backups.freshReceipt(requiring: BackupRequirement(containerID: containerID, needsNotes: true))
        let plan = draft.plan
        let deleted = draft.others
        let outcome = try await MergeExecutor(store: store, notes: notes)
            .execute(survivor: plan.merged, absorbing: draft.deleteSourceIdentifiers, backup: receipt, now: now())
        return MergeRun(receipt: receipt, outcome: outcome, survivor: plan.merged, deleted: deleted)
    }
}
