import Foundation

/// Why a photo needs the user's decision (`ReviewKind.photoConflict`).
public enum PhotoConflictReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// Both sides changed their photo, to different pictures.
    case bothChanged
    /// Neither side had been compared yet and the two photos differ.
    case firstSightDiffers
    /// The iCloud photo was removed; the Google contact still has its own.
    case removedInICloud
    /// The Google photo was removed; the iCloud contact still has one.
    case removedInGoogle
    /// One side removed its photo while the other changed it.
    case removedOneChangedOther
    /// The iCloud photo was a copy of the Google profile photo and was removed.
    case profileRemovedInICloud
}

/// Which Google photo a copy to iCloud reads.
public enum PhotoSource: String, Sendable, Hashable, Codable {
    /// The contact's own photo.
    case googleContact
    /// The person's Google profile photo.
    case googleProfile
}

/// One photo change the planner wants made. Pure data, like the rest of `SyncPlan`; `PhotoExecutor` carries it out.
public struct PlannedPhotoOp: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case copyToGoogle
        case copyToICloud(source: PhotoSource)
        case deleteOnGoogle
        case deleteOnICloud
        /// Nothing is written: the photos already agree, or the user chose to leave them.
        case recordBaseline
    }

    public var icloudID: String
    public var resourceName: String
    public var kind: Kind
    /// The photo baseline to store once the op is done (for `recordBaseline`, straight away).
    public var baseline: PhotoBaseline
    /// The Google photo URL key the planner saw; a write or delete of Google's photo is skipped if it moved since.
    public var expectedGoogleURLKey: String?
    /// The iCloud thumbnail hint the planner saw; a write or delete of the iCloud photo is skipped if it moved since.
    public var expectedICloudHint: String?
    /// What a permanent failure of this op is recorded against (see `PhotoBaseline.Failure`): the signs of the photos it was
    /// planned on. The planner leaves the op out while the stored failure has the same stamp.
    public var failureStamp: String?

    public init(
        icloudID: String, resourceName: String, kind: Kind, baseline: PhotoBaseline, expectedGoogleURLKey: String? = nil,
        expectedICloudHint: String? = nil, failureStamp: String? = nil
    ) {
        self.icloudID = icloudID
        self.resourceName = resourceName
        self.kind = kind
        self.baseline = baseline
        self.expectedGoogleURLKey = expectedGoogleURLKey
        self.expectedICloudHint = expectedICloudHint
        self.failureStamp = failureStamp
    }
}

extension PlannedPhotoOp.Kind {
    /// What the sync screen says about the change.
    var text: String {
        switch self {
        case .copyToGoogle: "photo to Google"
        case .copyToICloud(let source): source == .googleProfile ? "Google profile photo to iCloud" : "photo to iCloud"
        case .deleteOnGoogle: "remove photo from Google"
        case .deleteOnICloud: "remove photo from iCloud"
        case .recordBaseline: "photos already agree"
        }
    }
}
