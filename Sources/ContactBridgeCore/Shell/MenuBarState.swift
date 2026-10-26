import Foundation

/// How the menu-bar icon looks. The app maps each case to a symbol.
public enum MenuBarIcon: Sendable, Hashable {
    case normal
    case syncing
    case paused
    /// Reviews or a confirmation are waiting for the user.
    case needsAttention
}

/// What the menu-bar menu shows and which of its commands are available, worked out from the engine's snapshot.
public struct MenuBarState: Sendable, Hashable {
    public enum PauseControl: Sendable, Hashable {
        case pause
        case resume
        /// Nothing to pause or resume (not approved yet, or syncing is off).
        case none
    }

    public var statusLine: String
    public var icon: MenuBarIcon
    public var pendingReviews: Int
    /// A confirmation is waiting; the menu points at the window instead of offering Sync now.
    public var needsConfirmation: Bool
    public var canSyncNow: Bool
    public var pauseControl: PauseControl

    /// "3 to review", or nil when nothing waits.
    public var reviewLine: String? { pendingReviews > 0 ? "\(pendingReviews) to review" : nil }

    /// - Parameter timeText: how a time of day reads in the status line ("3:41 PM"; other days carry the date).
    public init(_ snapshot: SyncSnapshot, timeText: (Date) -> String = { MenuBarState.defaultTimeText($0) }) {
        pendingReviews = snapshot.pendingReviews
        needsConfirmation = snapshot.confirmationSummary != nil
        statusLine = Self.statusLine(snapshot, timeText: timeText)

        let usable: Bool
        switch snapshot.status {
        case .notStarted, .disabled: usable = false
        default: usable = true
        }
        canSyncNow = usable && snapshot.firstSyncApproved && !snapshot.isRunning && !snapshot.isUserPaused && !needsConfirmation
        if !usable || !snapshot.firstSyncApproved {
            pauseControl = .none
        } else {
            pauseControl = snapshot.isUserPaused ? .resume : .pause
        }

        if needsConfirmation {
            icon = .needsAttention
        } else if snapshot.isRunning {
            icon = .syncing
        } else if case .paused = snapshot.status {
            icon = .paused
        } else if pendingReviews > 0 {
            icon = .needsAttention
        } else {
            icon = .normal
        }
    }

    private static func statusLine(_ snapshot: SyncSnapshot, timeText: (Date) -> String) -> String {
        switch snapshot.status {
        case .notStarted: return "Starting…"
        case .disabled: return "Syncing is off"
        case .notReady: return "Finish setup in Contact Bridge"
        case .running: return "Syncing…"
        case .paused(.user): return "Paused"
        case .paused(.needsConfirmation): return "Waiting for your OK"
        case .paused(let reason): return "Paused: \(reason.shortExplanation)"
        case .failed: return "Last sync failed, will retry"
        case .idle:
            guard snapshot.firstSyncApproved else { return "Syncing has not started" }
            guard let at = snapshot.lastRunAt else { return "Waiting for the first sync" }
            if snapshot.lastRun?.halted != nil { return "Stopped early, will retry" }
            return "Synced at \(timeText(at))"
        }
    }

    /// Today's times as "3:41 PM", other days with the date (as the Sync screen shows them).
    public static func defaultTimeText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension PauseReason {
    /// A few words, for a menu line or a notification.
    public var shortExplanation: String {
        switch self {
        case .user: "you paused it"
        case .accountChanged: "the Google account changed"
        case .containerChanged: "the iCloud account changed"
        case .googleEmpty: "Google returned no contacts"
        case .notesUnavailable: "notes can't be read"
        case .needsConfirmation: "waiting for your OK"
        }
    }
}
