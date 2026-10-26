import CryptoKit
import Foundation

/// What a linked pair looked like when sync last made them agree. The three-way diff compares each side's current
/// record against its half of this.
public struct SyncBaseline: Sendable, Hashable, Codable {
    /// The iCloud contact as of the last sync.
    public var icloud: ContactRecord
    /// `GooglePersonMapper.record(from:)` of the person Google returned for the last write (or listing), so our own
    /// writes echo back as "unchanged". Entries present here and absent from `icloud` are Google-only data.
    public var google: ContactRecord
    public var googleEtag: String
    /// `NoteHash.hash` of each side's note as of the last sync; nil when that side's notes were not readable.
    public var icloudNoteHash: String?
    public var googleNoteHash: String?
    public var syncedAt: Date
    /// What the pair's photos looked like at the last sync. Nil until the pair's photos are first looked at, and in files
    /// written before photo sync. Whole-baseline rewrites leave it alone: only photo sync moves it (`SyncState.store`).
    public var photo: PhotoBaseline?

    public init(
        icloud: ContactRecord, google: ContactRecord, googleEtag: String,
        icloudNoteHash: String? = nil, googleNoteHash: String? = nil, syncedAt: Date, photo: PhotoBaseline? = nil
    ) {
        self.icloud = icloud
        self.google = google
        self.googleEtag = googleEtag
        self.icloudNoteHash = icloudNoteHash
        self.googleNoteHash = googleNoteHash
        self.syncedAt = syncedAt
        self.photo = photo
    }
}

/// Why sync is stopped until the user acts.
public enum PauseReason: Sendable, Hashable, Codable {
    /// The user's kill switch.
    case user
    case accountChanged
    case containerChanged
    /// A full Google listing came back empty while contacts are linked: the account or the listing is wrong, not every
    /// contact deleted.
    case googleEmpty
    /// Contacts notes cannot be read, so the note field is skipped.
    case notesUnavailable
    /// A run would exceed the delete or update guard; `summary` says what it wanted to do.
    case needsConfirmation(summary: String)
}

/// The contents of `sync-state.json`.
public struct SyncState: Sendable, Hashable, Codable {
    public static let currentVersion = 1

    public var version: Int
    /// Keyed by iCloud contact identifier.
    public var baselines: [String: SyncBaseline]
    public var googleSyncToken: String?
    /// Hash of the `personFields` the sync token was issued for; a mismatch forces a full listing.
    public var fieldsVersion: String?
    public var icloudChangeToken: Data?
    /// The iCloud container the baselines were taken from; a different one pauses sync.
    public var icloudContainerID: String?
    /// When the notes were last read from Contacts; drives the once-a-day refresh.
    public var lastNotesReadAt: Date?
    public var googleAccount: String?
    /// Resource names of Google contacts the user chose not to import.
    public var ignoredGoogle: Set<String>
    /// `"<iCloud id>|<Google resource name>"` pairs the user said are different people, so the matching pass never offers
    /// them again (`SyncPlanner.plan(keepSeparate:)`). Missing in files written before stage 5; read as empty.
    public var keepSeparate: Set<String>
    public var firstSyncApproved: Bool
    public var pause: PauseReason?
    /// The master switch for photo sync. When off, no photo is read, written or reviewed.
    public var syncPhotos: Bool
    /// Copy a Google contact's profile photo to iCloud when neither side has a photo of its own, and keep it up to date.
    public var useGoogleProfilePhotos: Bool
    /// iCloud ids of contacts whose Google profile photo is never used (the user chose "stop using it").
    public var profilePhotoOptOut: Set<String>
    /// When Google was last listed in full for its photos; with profile photos on, a full listing is forced once a day.
    public var lastPhotoFullListingAt: Date?
    /// The last `PhotoRepair` this state went through. Missing in older files, read as 0.
    public var photoRepairVersion: Int

    public init(
        version: Int = SyncState.currentVersion, baselines: [String: SyncBaseline] = [:], googleSyncToken: String? = nil,
        fieldsVersion: String? = nil, icloudChangeToken: Data? = nil, icloudContainerID: String? = nil,
        lastNotesReadAt: Date? = nil, googleAccount: String? = nil, ignoredGoogle: Set<String> = [],
        keepSeparate: Set<String> = [], firstSyncApproved: Bool = false, pause: PauseReason? = nil, syncPhotos: Bool = true,
        useGoogleProfilePhotos: Bool = false, profilePhotoOptOut: Set<String> = [], lastPhotoFullListingAt: Date? = nil,
        photoRepairVersion: Int = PhotoRepair.currentVersion
    ) {
        self.version = version
        self.baselines = baselines
        self.googleSyncToken = googleSyncToken
        self.fieldsVersion = fieldsVersion
        self.icloudChangeToken = icloudChangeToken
        self.icloudContainerID = icloudContainerID
        self.lastNotesReadAt = lastNotesReadAt
        self.googleAccount = googleAccount
        self.ignoredGoogle = ignoredGoogle
        self.keepSeparate = keepSeparate
        self.firstSyncApproved = firstSyncApproved
        self.pause = pause
        self.syncPhotos = syncPhotos
        self.useGoogleProfilePhotos = useGoogleProfilePhotos
        self.profilePhotoOptOut = profilePhotoOptOut
        self.lastPhotoFullListingAt = lastPhotoFullListingAt
        self.photoRepairVersion = photoRepairVersion
    }

    // Adding `keepSeparate` and the photo settings needs no version bump: a file without them decodes as before, with none
    // kept apart, photo sync on and profile photos off.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        baselines = try values.decode([String: SyncBaseline].self, forKey: .baselines)
        googleSyncToken = try values.decodeIfPresent(String.self, forKey: .googleSyncToken)
        fieldsVersion = try values.decodeIfPresent(String.self, forKey: .fieldsVersion)
        icloudChangeToken = try values.decodeIfPresent(Data.self, forKey: .icloudChangeToken)
        icloudContainerID = try values.decodeIfPresent(String.self, forKey: .icloudContainerID)
        lastNotesReadAt = try values.decodeIfPresent(Date.self, forKey: .lastNotesReadAt)
        googleAccount = try values.decodeIfPresent(String.self, forKey: .googleAccount)
        ignoredGoogle = try values.decode(Set<String>.self, forKey: .ignoredGoogle)
        keepSeparate = try values.decodeIfPresent(Set<String>.self, forKey: .keepSeparate) ?? []
        firstSyncApproved = try values.decode(Bool.self, forKey: .firstSyncApproved)
        pause = try values.decodeIfPresent(PauseReason.self, forKey: .pause)
        syncPhotos = try values.decodeIfPresent(Bool.self, forKey: .syncPhotos) ?? true
        useGoogleProfilePhotos = try values.decodeIfPresent(Bool.self, forKey: .useGoogleProfilePhotos) ?? false
        profilePhotoOptOut = try values.decodeIfPresent(Set<String>.self, forKey: .profilePhotoOptOut) ?? []
        lastPhotoFullListingAt = try values.decodeIfPresent(Date.self, forKey: .lastPhotoFullListingAt)
        photoRepairVersion = try values.decodeIfPresent(Int.self, forKey: .photoRepairVersion) ?? 0
    }

    /// Writes a whole baseline for `id` the way every field-sync rewrite does: the photo half of an existing baseline is
    /// kept, because only photo sync moves it. A rewrite built from an older copy therefore cannot undo a photo update.
    /// A baseline for an id with none yet is stored as given.
    public mutating func store(_ baseline: SyncBaseline, for id: String) {
        var baseline = baseline
        if let existing = baselines[id] { baseline.photo = existing.photo }
        baselines[id] = baseline
    }
}

/// Notes are compared by hash so baselines never hold note text. Both sides must hash through here to be comparable.
public enum NoteHash {
    /// SHA-256 (hex) of the note with line endings unified and surrounding whitespace trimmed, since Google and Contacts
    /// disagree about both.
    public static func hash(_ note: String) -> String {
        let text = note.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
