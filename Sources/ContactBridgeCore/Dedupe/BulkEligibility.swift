import Foundation

/// Whether a group may be merged in bulk without a person looking at it first.
public enum BulkEligibility: Sendable, Hashable {
    /// High confidence, no flags, no disagreeing fields: "Select all safe groups" ticks these.
    case safe
    /// Can be ticked by hand (medium confidence, or only informational flags), never by "Select all safe groups".
    case eligible
    /// A conflict flag or fields that disagree: the user has to open the group. Bulk merge refuses it.
    case needsReview
}

extension MergeDraft {
    /// Judged on the draft as it stands, so a member left out of the group counts.
    public var bulkEligibility: BulkEligibility {
        if flags.contains(where: \.isConflict) || !conflicts.isEmpty { return .needsReview }
        if level == .high && flags.isEmpty { return .safe }
        return .eligible
    }
}

extension DuplicateCluster {
    /// The classification of the untouched suggestion for this cluster (`MergeDraft(cluster:)`).
    public var bulkEligibility: BulkEligibility { MergeDraft(cluster: self).bulkEligibility }
}

/// Where a bulk merge is. `completed` groups are done; while merging, group `completed + 1` of `total` is the current one.
public struct BulkProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case backingUp
        case merging
    }

    public var phase: Phase
    public var completed: Int
    public var total: Int
}

public struct BulkMergeReport: Sendable {
    public enum GroupOutcome: Sendable, Equatable {
        /// `notes` can be `.writeFailed`: the merge happened, only the combined note was not saved. That stops the run.
        case merged(survivor: ContactRecord, deleted: [ContactRecord], notes: MergeExecutor.NotesOutcome)
        /// Nothing in this group was changed.
        case failed(reason: String)
        /// The run stopped before reaching it.
        case notRun
    }

    public struct Entry: Sendable {
        public var draft: MergeDraft
        public var outcome: GroupOutcome
    }

    public enum Stop: Sendable, Equatable {
        case completed
        /// The user pressed Stop; it took effect after the current group.
        case stoppedByUser
        /// The new backup failed, so nothing was merged.
        case backupFailed(reason: String)
        /// A group failed, or merged without saving its note; later groups were not run.
        case stoppedOnProblem
    }

    /// One per draft, in the order given.
    public var entries: [Entry]
    public var stop: Stop
    /// The backups taken, newest last. The first is the up-front one; more only if the run outlived a backup's freshness.
    public var receipts: [BackupReceipt]

    public var receipt: BackupReceipt? { receipts.first }

    public var mergedCount: Int {
        entries.count { if case .merged = $0.outcome { true } else { false } }
    }

    public var deletedCount: Int {
        entries.reduce(0) { total, entry in
            if case .merged(_, let deleted, _) = entry.outcome { total + deleted.count } else { total }
        }
    }

    public var notRunCount: Int { entries.count { $0.outcome == .notRun } }

    public var isComplete: Bool { stop == .completed }
}
