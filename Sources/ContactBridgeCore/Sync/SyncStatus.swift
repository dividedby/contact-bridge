import Foundation

// MARK: clock

/// Time as the sync engine sees it, so tests can drive debouncing, the timer and backoff without waiting.
public protocol SyncClock: Sendable {
    func now() -> Date
    /// Returns once `now()` has reached `deadline` (at once if it already has), or throws `CancellationError` if the task
    /// is cancelled first. Deadlines are absolute so that time passing before the sleep starts cannot stretch the wait.
    func sleep(until deadline: Date) async throws
}

public struct SystemSyncClock: SyncClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(until deadline: Date) async throws {
        try await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
    }
}

/// How often and how patiently the engine runs.
public struct SyncSchedule: Sendable, Hashable {
    /// Quiet time after a trigger before a run starts; a later trigger pushes it back.
    public var debounce: TimeInterval = 10
    /// A run is never put off longer than this by a stream of triggers.
    public var maxDebounce: TimeInterval = 60
    /// After a wake the network needs a moment.
    public var wakeDelay: TimeInterval = 30
    /// The regular check, whatever else happens.
    public var interval: TimeInterval = 15 * 60
    /// The pause after a failed or stopped run; doubles with each failure in a row up to `backoffMax`.
    public var backoffStart: TimeInterval = 60
    public var backoffMax: TimeInterval = 15 * 60
    /// Consecutive follow-up runs for work the mutation cap carried over.
    public var maxFollowUps = 50

    public init() {}
}

// MARK: environment

/// What a run works on right now. It is asked for again at the start of every run, because the chosen iCloud account, the
/// sign-in and the notes permission can change while the app is open.
public struct SyncEnvironment: Sendable {
    public var store: any ContactStoring
    /// Nil when notes cannot be read (no permission): the run carries no note information.
    public var notes: (any NotesProvider)?
    public var google: any GoogleContactsClient
    /// The signed-in Google account; a different one than the baselines were made for pauses sync. Nil when the email is
    /// unknown: a run then fails once an account is saved, and the first sync cannot be approved.
    public var accountEmail: String?
    /// The iCloud container `store` reads and writes; the backup has to cover exactly it.
    public var containerID: String?

    public init(
        store: any ContactStoring, notes: (any NotesProvider)? = nil, google: any GoogleContactsClient, accountEmail: String? = nil,
        containerID: String? = nil
    ) {
        self.store = store
        self.notes = notes
        self.google = google
        self.accountEmail = accountEmail
        self.containerID = containerID
    }
}

public enum SyncEnvironmentState: Sendable {
    case ready(SyncEnvironment)
    /// Phrased as the next step ("Sign in with Google in Setup first.").
    case notReady(String)
}

/// Things that make the engine look again. Each is debounced.
public enum SyncEvent: Sendable, Hashable {
    /// Contacts changed (including by this app's own Import, Merge and Clean up).
    case storeChanged
    case timer
    case wake
    case networkBack
    /// Sign-in, the chosen account or notes access changed.
    case settingsChanged
}

// MARK: published state

public enum SyncPhase: Sendable, Hashable {
    /// Import, Merge or Clean up holds the write gate.
    case waitingForOtherChanges
    case checkingInterruptedRun
    case readingICloud
    case readingGoogle
    case planning
    case applying

    public var title: String {
        switch self {
        case .waitingForOtherChanges: "Waiting for another change to finish"
        case .checkingInterruptedRun: "Checking the last run"
        case .readingICloud: "Reading iCloud contacts"
        case .readingGoogle: "Reading Google contacts"
        case .planning: "Working out changes"
        case .applying: "Applying changes"
        }
    }
}

public enum SyncStatus: Sendable, Hashable {
    /// `start()` has not run.
    case notStarted
    /// Sync cannot run in this process at all (another copy holds the lock).
    case disabled(String)
    /// Something in Setup is missing.
    case notReady(String)
    case idle
    case running(SyncPhase)
    case paused(PauseReason)
    /// The last run failed before it could finish; it is retried after a back-off.
    case failed(String)
}

extension PauseReason {
    /// What the sync screen says about a pause.
    public var explanation: String {
        switch self {
        case .user: "You paused syncing."
        case .accountChanged: "The signed-in Google account is not the one Contact Bridge has been syncing with. Sign back in to that account in Setup."
        case .containerChanged: "The iCloud contacts account is not the one Contact Bridge has been syncing with, or it looks empty. Choose the original account in Setup."
        case .googleEmpty: "Google reported no contacts at all while contacts are linked. That looks like a listing problem, not a deletion, so nothing was changed."
        case .notesUnavailable: "Notes cannot be read, so the note field is not being synced."
        case .needsConfirmation(let summary): summary
        }
    }
}

extension SyncField {
    /// How the field group is named on screen.
    public var title: String {
        switch self {
        case .name: "name"
        case .nickname: "nickname"
        case .organization: "company"
        case .phones: "phones"
        case .emails: "emails"
        case .postalAddresses: "addresses"
        case .urls: "websites"
        case .birthday: "birthday"
        case .note: "note"
        }
    }
}

/// What a finished run did, for the sync screen.
public struct SyncRunSummary: Sendable, Hashable {
    public var finishedAt: Date
    public var linksAdded = 0
    public var created = 0
    public var updated = 0
    public var deleted = 0
    /// Deletes where Google no longer had the contact.
    public var alreadyGone = 0
    public var recoveredWrites = 0
    /// Photos copied each way, and photos removed (only ever after the user chose it).
    public var photosToGoogle = 0
    public var photosToICloud = 0
    public var photosRemoved = 0
    public var reviewsAdded = 0
    public var conflictsFound = 0
    /// Work that waits for the next run.
    public var leftForNextRun = 0
    public var blockedByReview = 0
    /// Why the run stopped early (rate limit, sign-in or permission problem); the engine waits before trying again.
    public var halted: String?
    public var warnings: [String] = []

    public init(finishedAt: Date, report: SyncRunReport) {
        self.finishedAt = finishedAt
        linksAdded = report.linksAdded
        created = report.created
        updated = report.updated
        deleted = report.deleted
        alreadyGone = report.alreadyGone
        recoveredWrites = report.recovery.applied
        photosToGoogle = report.photo.copiedToGoogle
        photosToICloud = report.photo.copiedToICloud
        photosRemoved = report.photo.removedFromGoogle + report.photo.removedFromICloud
        reviewsAdded = report.reviewsAdded.count
        conflictsFound = report.conflictsFound.count
        leftForNextRun = report.leftForNextRun.count + report.photo.skipped.count + report.photo.carried
        blockedByReview = report.blockedByReview.count
        halted = report.halted
        warnings = report.warnings
    }

    public var didAnything: Bool {
        linksAdded + created + updated + deleted + alreadyGone + recoveredWrites + photosToGoogle + photosToICloud + photosRemoved > 0
    }

    private static func photos(_ count: Int) -> String { "\(count) photo\(count == 1 ? "" : "s")" }

    /// "Linked 3, created 2, updated 1." or "Nothing needed changing."
    public var text: String {
        var parts: [String] = []
        if linksAdded > 0 { parts.append("linked \(linksAdded)") }
        if created > 0 { parts.append("created \(created)") }
        if updated > 0 { parts.append("updated \(updated)") }
        if deleted > 0 { parts.append("deleted \(deleted)") }
        if alreadyGone > 0 { parts.append("\(alreadyGone) already gone from Google") }
        if recoveredWrites > 0 { parts.append("confirmed \(recoveredWrites) from an earlier run") }
        if photosToGoogle > 0 && photosToICloud > 0 {
            parts.append("copied \(Self.photos(photosToGoogle)) to Google, \(photosToICloud) to iCloud")
        } else if photosToGoogle > 0 {
            parts.append("copied \(Self.photos(photosToGoogle)) to Google")
        } else if photosToICloud > 0 {
            parts.append("copied \(Self.photos(photosToICloud)) to iCloud")
        }
        if photosRemoved > 0 { parts.append("removed \(photosRemoved) photo\(photosRemoved == 1 ? "" : "s")") }
        guard !parts.isEmpty else { return "Nothing needed changing." }
        let sentence = parts.joined(separator: ", ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }
}

/// One open question, as the sync screen lists it.
public struct SyncReviewSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ReviewKind
    public var name: String
    /// For a possible link, the Google contact it might be.
    public var detail: String?
    public var fields: [SyncField]
    /// For a photo question: what kind it is.
    public var photoReason: PhotoConflictReason?
    /// A conflict found when the two contacts were first linked ("Keep iCloud for all" applies to these).
    public var isFirstLink = false
}

/// The first-sync plan, in words. Nothing in it has been done.
public struct SyncPreview: Sendable, Hashable {
    public struct Item: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var detail: String?
    }

    public struct Counts: Sendable, Hashable {
        public var link = 0
        public var create = 0
        public var update = 0
        public var delete = 0
        public var review = 0
        /// Photos to copy or remove (not baseline records).
        public var photo = 0
    }

    /// Pairs found on both sides that will be tied together without changing either.
    public var links: [Item]
    /// iCloud contacts that will be created in Google.
    public var creates: [Item]
    /// Linked Google contacts that will be changed.
    public var updates: [Item]
    /// Google contacts that will be deleted because the iCloud contact is gone.
    public var deletes: [Item]
    /// Contact photos that will be copied (or removed) between the two sides.
    public var photos: [Item] = []
    public var reviews: [SyncReviewSummary]
    /// Links that will be forgotten because their contact is gone from iCloud (and perhaps from Google too). Links whose
    /// Google contact survives are re-matched instead and are not listed.
    public var forgottenLinks: [Item]
    public var waitingForNotes: Int
    public var unlinkedWaitingForFullListing: Int
    public var notesUnavailable: Bool
    /// Set when the plan cannot run as it stands (wrong account, a guard wants confirmation).
    public var pause: PauseReason?
    /// The backups that will be taken before anything is written.
    public var backups: [String]
    public var generatedAt: Date

    public var counts: Counts {
        Counts(link: links.count, create: creates.count, update: updates.count, delete: deletes.count, review: reviews.count, photo: photos.count)
    }

    /// Nothing would be linked, created, changed or deleted.
    public var isEmpty: Bool { links.isEmpty && creates.isEmpty && updates.isEmpty && deletes.isEmpty && photos.isEmpty }
}

/// The engine's whole published state. Every change is sent to `SyncEngine.snapshots()`.
public struct SyncSnapshot: Sendable, Hashable {
    public var status: SyncStatus = .notStarted
    /// Whether the user has pressed "Start syncing". Until then runs only build `preview`.
    public var firstSyncApproved = false
    public var preview: SyncPreview?
    /// When the last run finished without throwing, and what it did.
    public var lastRunAt: Date?
    public var lastRun: SyncRunSummary?
    /// The earliest a retry or the next debounced run may start (after a failure or a stop).
    public var nextAttemptAt: Date?
    /// Open questions, newest last.
    public var reviewItems: [SyncReviewSummary] = []
    /// New or newly linked contacts that wait because their notes could not be read.
    public var waitingForNotes = 0
    /// iCloud contacts that wait for a listing of every Google contact.
    public var unlinkedWaitingForFullListing = 0
    /// Creates Google may or may not have applied; held back until a later listing settles them.
    public var unconfirmedCreates = 0
    /// Notes were due but unreadable on the last run: the note field is skipped, and new contacts cannot sync.
    public var notesUnavailable = false
    /// The contacts a `.needsConfirmation` pause is about to forget links to, by name. The pause's own summary stays
    /// name-free (it is saved and compared as text); empty unless that guard is what paused.
    public var pauseDetails: [SyncPreview.Item] = []
    /// Set when the kill switch (pause or resume) could not be saved: it holds for now but may not after a relaunch.
    /// Cleared by the next switch that saves.
    public var pauseSaveWarning: String?

    public init() {}

    public var pendingReviews: Int { reviewItems.count }
    public var isUserPaused: Bool { status == .paused(.user) }
    public var isRunning: Bool {
        if case .running = status { true } else { false }
    }

    /// The summary of a pause that waits for the user to confirm or keep it paused.
    public var confirmationSummary: String? {
        if case .paused(.needsConfirmation(let summary)) = status { summary } else { nil }
    }
}
