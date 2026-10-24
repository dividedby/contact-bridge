import Foundation

/// One notification the app may show.
public struct SyncNotice: Sendable, Hashable {
    /// Each kind has one slot: a newer notice of the same kind replaces the older instead of stacking.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case reviews
        case pause
        case failing

        /// The system identifier of the notice slot, so a newer notice replaces the older.
        public var identifier: String { "dev.dividedby.contactbridge.notice.\(rawValue)" }
    }

    /// Where a click on the notification takes the user.
    public enum Destination: String, Sendable, Hashable {
        case reviewList
        case confirmation
        case status
    }

    public var kind: Kind
    public var title: String
    public var body: String
    public var destination: Destination

    public var identifier: String { kind.identifier }
}

/// What to do after one snapshot.
public struct SyncNoticeUpdate: Sendable, Hashable {
    public var post: [SyncNotice] = []
    /// Kinds whose condition has cleared, so a notice still on screen is stale.
    public var retract: [SyncNotice.Kind] = []

    public var isEmpty: Bool { post.isEmpty && retract.isEmpty }
}

/// Decides, from the stream of engine snapshots, when something is worth a notification. Pure state: no clock, no system.
///
/// - Reviews: when a review item appears that was not in the list before. Item ids, not the count, so one resolved and one
///   new item still counts. The list a launch starts from comes from the stored review list (`knownReviewIDs`), so what
///   was already waiting is not announced again.
/// - Pauses: once on entering a pause that is not the user's own (confirmation, wrong account, empty listing); again only
///   after syncing ran normally in between, or when a confirmation asks about something different.
/// - Failures: runs that fail or stop early are retried by the engine and are often just a network gap, so only the second
///   in a row is announced, once per streak.
public struct SyncNoticeTracker: Sendable {
    public static let failureStreakThreshold = 2

    private var knownReviewIDs: Set<String>
    private var reviewNoticeShown = false
    private var announcedPause: PauseReason?
    private var previousStatus: SyncStatus?
    private var lastRunSeen: Date?
    private var failureStreak = 0
    private var failureNoticeShown = false

    public init(knownReviewIDs: Set<String> = []) {
        self.knownReviewIDs = knownReviewIDs
    }

    public mutating func observe(_ snapshot: SyncSnapshot) -> SyncNoticeUpdate {
        var update = SyncNoticeUpdate()
        defer { previousStatus = snapshot.status }
        observeReviews(snapshot, into: &update)
        observePause(snapshot, into: &update)
        observeFailures(snapshot, into: &update)
        return update
    }

    private mutating func observeReviews(_ snapshot: SyncSnapshot, into update: inout SyncNoticeUpdate) {
        // The list is only filled by a finished run; before the first one it is empty without meaning "all settled".
        guard snapshot.lastRunAt != nil else { return }
        let ids = Set(snapshot.reviewItems.map(\.id))
        let appeared = !ids.subtracting(knownReviewIDs).isEmpty
        knownReviewIDs = ids
        if appeared {
            reviewNoticeShown = true
            let count = ids.count
            update.post.append(SyncNotice(
                kind: .reviews, title: "Contact Bridge",
                body: count == 1 ? "1 contact needs your review" : "\(count) contacts need your review", destination: .reviewList
            ))
        } else if ids.isEmpty, reviewNoticeShown {
            reviewNoticeShown = false
            update.retract.append(.reviews)
        }
    }

    private mutating func observePause(_ snapshot: SyncSnapshot, into update: inout SyncNoticeUpdate) {
        switch snapshot.status {
        case .paused(.user), .paused(.notesUnavailable), .idle:
            // `.notesUnavailable` skips one field and syncing goes on, so it is not a stop.
            if announcedPause != nil {
                announcedPause = nil
                update.retract.append(.pause)
            }
        case .paused(let reason):
            guard announcedPause != reason else { return }
            announcedPause = reason
            if case .needsConfirmation(let summary) = reason {
                update.post.append(SyncNotice(kind: .pause, title: "Syncing is waiting for your OK", body: summary, destination: .confirmation))
            } else {
                update.post.append(SyncNotice(kind: .pause, title: "Syncing is paused", body: reason.explanation, destination: .status))
            }
        default:
            break
        }
    }

    private mutating func observeFailures(_ snapshot: SyncSnapshot, into update: inout SyncNoticeUpdate) {
        switch snapshot.status {
        case .failed(let message):
            if case .failed? = previousStatus { return }
            failed(message, into: &update)
        case .idle:
            guard snapshot.lastRunAt != lastRunSeen else { return }
            lastRunSeen = snapshot.lastRunAt
            if let halted = snapshot.lastRun?.halted {
                failed(halted, into: &update)
            } else {
                failureStreak = 0
                if failureNoticeShown {
                    failureNoticeShown = false
                    update.retract.append(.failing)
                }
            }
        default:
            break
        }
    }

    private mutating func failed(_ message: String, into update: inout SyncNoticeUpdate) {
        failureStreak += 1
        guard failureStreak == Self.failureStreakThreshold else { return }
        failureNoticeShown = true
        update.post.append(SyncNotice(kind: .failing, title: "Syncing keeps failing", body: message, destination: .status))
    }
}
