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

    /// A photo that cannot be read or copied however often it is tried (a picture Google rejects, a download that is refused).
    /// It is left alone until the photo it failed on changes.
    public struct Failure: Sendable, Hashable, Codable {
        /// What the failure was about: the photos' signs when it happened. A different stamp means a photo changed.
        public var stamp: String
        public var message: String
        public var at: Date

        public init(stamp: String, message: String, at: Date) {
            self.stamp = stamp
            self.message = message
            self.at = at
        }
    }

    /// Fingerprint of the iCloud contact's photo; nil when it had none.
    public var icloud: PhotoFingerprint?
    /// Fingerprint of the Google contact's own (CONTACT) photo; nil when it had none.
    public var google: PhotoFingerprint?
    /// Fingerprint of the Google profile photo last copied or seen, when profile photos are in use.
    public var googleProfile: PhotoFingerprint?
    /// The Google profile photo URL key it was taken at, so an unchanged profile photo is not downloaded again.
    public var googleProfileKey: String?
    /// `PhotoHash.sha256Hex` of the iCloud thumbnail data: the cheap sign that the iCloud photo did not change.
    public var icloudHint: String?
    /// The Google photo URL without its size suffix: the cheap sign that the Google photo did not change.
    public var googleURLKey: String?
    public var icloudOrigin: PhotoOrigin
    public var syncedAt: Date
    public var pendingRemoval: PendingRemoval?
    public var failure: Failure?

    public init(
        icloud: PhotoFingerprint? = nil, google: PhotoFingerprint? = nil, googleProfile: PhotoFingerprint? = nil,
        icloudHint: String? = nil, googleURLKey: String? = nil, googleProfileKey: String? = nil, icloudOrigin: PhotoOrigin = .user,
        syncedAt: Date, pendingRemoval: PendingRemoval? = nil, failure: Failure? = nil
    ) {
        self.icloud = icloud
        self.google = google
        self.googleProfile = googleProfile
        self.icloudHint = icloudHint
        self.googleURLKey = googleURLKey
        self.googleProfileKey = googleProfileKey
        self.icloudOrigin = icloudOrigin
        self.syncedAt = syncedAt
        self.pendingRemoval = pendingRemoval
        self.failure = failure
    }
}
