import CryptoKit
import Foundation

/// How a link between an iCloud contact and a Google contact came about.
public enum LinkOrigin: String, Sendable, Hashable, Codable {
    /// Copied from Google into iCloud by Import.
    case imported
    /// Found by the matching pass: both contacts already existed.
    case matched
    /// Created in Google from the iCloud contact by sync.
    case createdInGoogle
}

/// What a review item asks the user about.
public enum ReviewKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// Edited in Google only (iCloud has not changed that field since the last sync).
    case googleEdited
    /// Edited on both sides to different results, or two existing contacts that disagree when first linked.
    case bothEdited
    case newInGoogle
    case deletedInGoogle
    case deletedInICloudEditedInGoogle
    /// An iCloud and a Google contact that might be the same person: link them or keep them apart.
    case possibleLink
}

/// A stable digest of a contact's modeled fields, so a review item can tell that the contact moved on since it was made.
public enum ContactFingerprint {
    public static func of(_ record: ContactRecord) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(record)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Something the planner wants the user to decide. The persistent review list (ReviewStore) is built from these.
public struct ReviewCandidate: Sendable, Hashable, Identifiable {
    public var kind: ReviewKind
    public var icloudID: String?
    public var resourceName: String?
    /// The Google etag the decision is about; a moved etag means the item must be refreshed first.
    public var googleEtag: String?
    /// `ContactFingerprint` of the iCloud contact the decision is about.
    public var icloudFingerprint: String?
    /// The field groups in conflict, in `SyncField` order. Empty for kinds that concern a whole contact.
    public var fields: [SyncField]

    public var id: String { "\(kind.rawValue)|\(icloudID ?? "")|\(resourceName ?? "")" }

    public init(
        kind: ReviewKind, icloudID: String? = nil, resourceName: String? = nil, googleEtag: String? = nil,
        icloudFingerprint: String? = nil, fields: [SyncField] = []
    ) {
        self.kind = kind
        self.icloudID = icloudID
        self.resourceName = resourceName
        self.googleEtag = googleEtag
        self.icloudFingerprint = icloudFingerprint
        self.fields = fields
    }
}

/// A pair that is (or becomes) linked, with the baseline to store for it.
public struct PlannedLink: Sendable, Hashable {
    public var icloudID: String
    public var resourceName: String
    public var origin: LinkOrigin
    /// False when `links.json` already has this link and only the baseline is missing (a Phase 1 import).
    public var isNewLink: Bool
    /// Both sides as they are now, with both note hashes where they were read. Field groups that differ are also
    /// reported as a `bothEdited` review candidate and are not changed on either side until the user decides.
    public var baseline: SyncBaseline
    public var reasons: [String]
}

/// An iCloud contact with no Google counterpart: create one, tagged with the iCloud identifier.
public struct PlannedCreate: Sendable, Hashable {
    public var icloudID: String
    public var record: ContactRecord
    /// The iCloud note, when it was read and is not empty. `GooglePersonMapper.createPayload` does not carry it.
    public var note: String?
    public var icloudNoteHash: String?
}

/// Changes to send to a linked Google contact.
public struct PlannedUpdate: Sendable, Hashable {
    public var icloudID: String
    public var resourceName: String
    /// The etag the diff was made against; on `.etagMismatch` refetch, re-diff and retry once.
    public var etag: String
    /// The Google person as listed, when this run listed it at the etag above; nil means fetch it before building the payload.
    public var existing: GooglePerson?
    /// The mask: the groups to write, nothing else.
    public var fields: Set<SyncField>
    /// `LinkDiff.desiredGoogle`: for `GooglePersonMapper.updatePayload(for:existing:restrictedTo:note:)`.
    public var desired: ContactRecord
    /// The iCloud note text to send when `fields` has `.note`; blank clears Google's.
    public var note: String?
    /// `LinkDiff.updatedBaseline`. Provisional: replace `google` and `googleEtag` with what Google returns.
    public var baseline: SyncBaseline
}

public struct PlannedDelete: Sendable, Hashable {
    public var icloudID: String
    public var resourceName: String
    public var baseline: SyncBaseline
}

/// The state to save once a run's results are committed. `SyncPlan.checkpoint` is nil when the run left work behind.
public struct SyncCheckpoint: Sendable, Hashable {
    public var icloudChangeToken: Data?
    public var icloudContainerID: String?
    public var lastNotesReadAt: Date?
    public var googleSyncToken: String?
    public var fieldsVersion: String
    public var googleAccount: String?
    /// Whether the Google tokens move (an incremental feed that sent no token leaves the old one).
    var replacesGoogleToken: Bool

    public func applied(to state: SyncState) -> SyncState {
        var state = state
        state.icloudChangeToken = icloudChangeToken
        state.icloudContainerID = icloudContainerID ?? state.icloudContainerID
        state.lastNotesReadAt = lastNotesReadAt ?? state.lastNotesReadAt
        if replacesGoogleToken {
            state.googleSyncToken = googleSyncToken
            state.fieldsVersion = googleSyncToken == nil ? nil : fieldsVersion
        }
        state.googleAccount = googleAccount ?? state.googleAccount
        return state
    }
}

/// What one sync run would do. Pure data; building one changes nothing.
public struct SyncPlan: Sendable, Hashable {
    /// Work left for later runs because of the mutation cap.
    public struct Deferred: Sendable, Hashable {
        public var updates = 0
        public var deletes = 0
        public var creates = 0
        public var isEmpty: Bool { updates + deletes + creates == 0 }
    }

    /// Sync has not been approved: show this plan, do not run it.
    public var isPreview: Bool
    /// Set when nothing may run: the scan or the feed paused, or a guard wants the user's confirmation (the plan then
    /// still lists everything it would do).
    public var pause: PauseReason?
    /// New links and baselines for pairs that already exist on both sides.
    public var links: [PlannedLink] = []
    public var creates: [PlannedCreate] = []
    public var updates: [PlannedUpdate] = []
    public var deletes: [PlannedDelete] = []
    /// Baselines that move without any write (equal edits on both sides, Google-only changes, a churned etag), by iCloud id.
    public var baselineRefreshes: [String: SyncBaseline] = [:]
    /// iCloud ids whose link and baseline should be forgotten: the contact is gone from both sides, or its link has no
    /// baseline and its iCloud contact is gone.
    public var droppedLinks: [String] = []
    public var review: [ReviewCandidate] = []
    public var deferred = Deferred()

    /// Unlinked iCloud contacts that could not be matched or created because this run only saw part of Google's
    /// contacts. Run again with `requiresFullGoogleListing`.
    public var unlinkedWaitingForFullListing = 0
    /// Contacts that needed a baseline (new, or linked by an earlier import) while their notes were unreadable. They are
    /// neither created nor linked yet, because a baseline without note hashes would keep the note from ever syncing.
    public var waitingForNotes = 0
    /// Whether the ownership-tag check behind `creates` saw every Google contact (a full listing). If not, list fully
    /// before creating anything.
    public var createsVerifiedAgainstFullListing = true
    /// True when the review candidates cover every conflict (full iCloud fetch and full Google listing). Otherwise a
    /// stored review item that is absent here is not resolved, just not looked at.
    public var reviewIsComplete = false
    /// The notes were due but unreadable: note fields were left out of this run.
    public var notesUnavailable = false
    public var notesReason: NotesReadReason = .skipped

    public var checkpoint: SyncCheckpoint?

    public var mutationCount: Int { creates.count + updates.count + deletes.count }

    public var needsConfirmation: Bool {
        if case .needsConfirmation? = pause { true } else { false }
    }

    /// Nothing to write, link, refresh, drop or ask about, and nothing waiting for a full listing or for notes. A plan
    /// with contacts waiting is not settled, so a screen must not call it "up to date".
    public var isEmpty: Bool {
        links.isEmpty && mutationCount == 0 && baselineRefreshes.isEmpty && droppedLinks.isEmpty && review.isEmpty && deferred.isEmpty
            && waitingForNotes == 0 && unlinkedWaitingForFullListing == 0
    }
}
