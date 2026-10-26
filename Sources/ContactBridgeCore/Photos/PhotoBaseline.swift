import Foundation

/// Which side of a linked pair.
public enum PhotoSide: String, Sendable, Hashable, Codable {
    case icloud
    case google
}

/// Where the photo on the iCloud contact came from.
public enum PhotoOrigin: String, Sendable, Hashable, Codable {
    /// Set by the user, or copied from the Google contact photo.
    case user
    /// Copied from the person's Google profile photo; follows profile changes until the user sets another photo.
    case googleProfile
}

/// What the photos of a linked pair looked like when sync last made them agree. Kept apart from the contact fields: photos
/// are not part of `ContactRecord`, `ThreeWayDiff` or `SyncField`. A side counts as "changed" when its picture is no longer
/// similar to that side's own fingerprint here. Nil `SyncBaseline.photo` means the pair has not been looked at yet.
public struct PhotoBaseline: Sendable, Hashable, Codable {
    /// A photo seen missing from one side; it only counts as removed once it is seen again, a while later, because the
    /// iCloud (CardDAV) copy of a contact can briefly come back without its photo.
    public struct PendingRemoval: Sendable, Hashable, Codable {
        public var side: PhotoSide
        public var firstSeenAt: Date

        public init(side: PhotoSide, firstSeenAt: Date) {
            self.side = side
            self.firstSeenAt = firstSeenAt
        }
    }

    /// Fingerprint of the iCloud contact's photo; nil when it had none.
    public var icloud: PhotoFingerprint?
    /// Fingerprint of the Google contact's own (CONTACT) photo; nil when it had none.
    public var google: PhotoFingerprint?
    /// Fingerprint of the Google profile photo last copied or seen, when profile photos are in use.
    public var googleProfile: PhotoFingerprint?
    /// `PhotoHash.sha256Hex` of the iCloud thumbnail data: the cheap sign that the iCloud photo did not change.
    public var icloudHint: String?
    /// The Google photo URL without its size suffix: the cheap sign that the Google photo did not change.
    public var googleURLKey: String?
    public var icloudOrigin: PhotoOrigin
    public var syncedAt: Date
    public var pendingRemoval: PendingRemoval?

    public init(
        icloud: PhotoFingerprint? = nil, google: PhotoFingerprint? = nil, googleProfile: PhotoFingerprint? = nil,
        icloudHint: String? = nil, googleURLKey: String? = nil, icloudOrigin: PhotoOrigin = .user, syncedAt: Date,
        pendingRemoval: PendingRemoval? = nil
    ) {
        self.icloud = icloud
        self.google = google
        self.googleProfile = googleProfile
        self.icloudHint = icloudHint
        self.googleURLKey = googleURLKey
        self.icloudOrigin = icloudOrigin
        self.syncedAt = syncedAt
        self.pendingRemoval = pendingRemoval
    }
}
