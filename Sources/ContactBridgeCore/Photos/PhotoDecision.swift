import Foundation

/// One photo as it looks now: its fingerprint, and the cheap sign that says whether it moved (the iCloud thumbnail hash, or
/// the Google URL key).
public struct PhotoSeen: Sendable, Hashable {
    public var fingerprint: PhotoFingerprint
    public var token: String?

    public init(fingerprint: PhotoFingerprint, token: String? = nil) {
        self.fingerprint = fingerprint
        self.token = token
    }
}

/// A linked pair's photos right now. A side with no photo is nil. A photo that the reconciler did not need to read again
/// (its sign still matches the baseline) carries the baseline's own fingerprint, so it compares as unchanged.
public struct PhotoSnapshot: Sendable, Hashable {
    public var icloud: PhotoSeen?
    /// The Google contact's own photo.
    public var google: PhotoSeen?
    /// The person's Google profile photo. Only filled where the profile rules can use it (see `PhotoReconciler`).
    public var profile: PhotoSeen?

    public init(icloud: PhotoSeen? = nil, google: PhotoSeen? = nil, profile: PhotoSeen? = nil) {
        self.icloud = icloud
        self.google = google
        self.profile = profile
    }
}

/// The decision table for one linked pair's photos. Pure: what the sides look like, what the last sync recorded and the
/// clock go in; what to do comes out. Nothing here reads or writes a photo.
///
/// A side counts as changed when its picture is no longer similar to that side's own fingerprint in the baseline, so a
/// recompressed or rescaled copy is not a change. Removal is never mirrored on its own: a removed photo is only asked about
/// (`review`), and only once it has been seen missing on two runs at least `removalWait` apart (a CardDAV copy of a contact
/// can come back without its photo for a moment). The Google profile photo is read-only: it only ever fills an iCloud
/// contact that has no photo of its own, and is never written to Google, compared as a side, or deleted.
public enum PhotoDecision {
    public enum Outcome: Sendable, Hashable {
        /// Nothing to do and nothing to store.
        case settled
        /// Nothing is written: store this baseline (the photos agree, a sign moved, or a removal was seen for the first time).
        case record(PhotoBaseline)
        /// Copy the iCloud photo to Google; store the baseline once done.
        case copyToGoogle(PhotoBaseline)
        /// Copy a Google photo to iCloud; store the baseline once done.
        case copyToICloud(PhotoSource, PhotoBaseline)
        /// The user decides.
        case review(PhotoConflictReason)
    }

    /// How long a removal has to have been visible before it is asked about.
    public static let removalWait: TimeInterval = 5 * 60

    private enum Change {
        case absent, unchanged, added, removed, changed

        init(_ now: PhotoSeen?, since base: PhotoFingerprint?) {
            switch (now, base) {
            case (nil, nil): self = .absent
            case (nil, _?): self = .removed
            case (_?, nil): self = .added
            case (let now?, let base?): self = now.fingerprint.isSimilar(to: base) ? .unchanged : .changed
            }
        }

        var isSettled: Bool { self == .absent || self == .unchanged }
        var isNew: Bool { self == .added || self == .changed }
    }

    /// - Parameters:
    ///   - baseline: nil the first time the pair's photos are looked at.
    ///   - profileEnabled: profile photos are on and this contact is not opted out.
    public static func decide(
        baseline: PhotoBaseline?, seen: PhotoSnapshot, profileEnabled: Bool, now: Date, removalWait: TimeInterval = removalWait
    ) -> Outcome {
        guard let baseline else { return firstSight(seen, profileEnabled: profileEnabled, now: now) }
        let profile = profileEnabled ? seen.profile : nil
        let icloud = Change(seen.icloud, since: baseline.icloud)
        let google = Change(seen.google, since: baseline.google)

        func removal(of side: PhotoSide, _ reason: PhotoConflictReason) -> Outcome {
            if let pending = baseline.pendingRemoval, pending.side == side {
                return now.timeIntervalSince(pending.firstSeenAt) >= removalWait ? .review(reason) : .settled
            }
            var seenOnce = baseline
            seenOnce.pendingRemoval = PhotoBaseline.PendingRemoval(side: side, firstSeenAt: now)
            return .record(seenOnce)
        }

        // A removal first: what is left of the other side decides what it means.
        if icloud == .removed {
            switch google {
            case .removed: return record(baseline, seen, profile: nil, now: now)
            case .added, .changed: return .review(.removedOneChangedOther)
            case .absent, .unchanged:
                if baseline.icloudOrigin == .googleProfile {
                    // The photo was a copy of their profile picture; with profile photos off there is nothing to ask.
                    return profileEnabled
                        ? removal(of: .icloud, .profileRemovedInICloud)
                        : record(baseline, seen, profile: nil, origin: .user, now: now)
                }
                return google == .unchanged ? removal(of: .icloud, .removedInICloud) : record(baseline, seen, profile: nil, now: now)
            }
        }
        if google == .removed {
            switch icloud {
            case .added, .changed: return .review(.removedOneChangedOther)
            case .unchanged: return removal(of: .google, .removedInGoogle)
            default: return record(baseline, seen, profile: nil, now: now)
            }
        }

        if icloud.isSettled && google.isSettled {
            if let outcome = profileOutcome(baseline, seen, icloud: icloud, google: google, profile: profile, now: now) { return outcome }
            // Only a profile copy keeps track of the profile photo; for anyone else it plays no part.
            return record(baseline, seen, profile: baseline.icloudOrigin == .googleProfile ? profile : nil, now: now)
        }

        // At least one side has a new picture.
        switch (icloud.isNew, google.isNew) {
        case (true, false):
            guard let source = seen.icloud else { return .settled }
            return .copyToGoogle(copied(baseline, from: source, seen: seen, now: now, to: .google))
        case (false, true):
            guard let source = seen.google else { return .settled }
            return .copyToICloud(.googleContact, copied(baseline, from: source, seen: seen, now: now, to: .icloud))
        default:
            guard let here = seen.icloud, let there = seen.google else { return .settled }
            if here.fingerprint.isSimilar(to: there.fingerprint) {
                return .record(agreed(baseline, seen, profile: nil, origin: .user, now: now))
            }
            return .review(.bothChanged)
        }
    }

    // MARK: first sight

    private static func firstSight(_ seen: PhotoSnapshot, profileEnabled: Bool, now: Date) -> Outcome {
        switch (seen.icloud, seen.google) {
        case (nil, nil):
            if let profile = profileEnabled ? seen.profile : nil {
                return .copyToICloud(.googleProfile, PhotoBaseline(
                    icloud: profile.fingerprint, googleProfile: profile.fingerprint, googleProfileKey: profile.token,
                    icloudOrigin: .googleProfile, syncedAt: now
                ))
            }
            return .record(PhotoBaseline(syncedAt: now))
        case (let icloud?, nil):
            return .copyToGoogle(PhotoBaseline(
                icloud: icloud.fingerprint, google: icloud.fingerprint, icloudHint: icloud.token, syncedAt: now
            ))
        case (nil, let google?):
            return .copyToICloud(.googleContact, PhotoBaseline(
                icloud: google.fingerprint, google: google.fingerprint, googleURLKey: google.token, syncedAt: now
            ))
        case (let icloud?, let google?):
            guard icloud.fingerprint.isSimilar(to: google.fingerprint) else { return .review(.firstSightDiffers) }
            return .record(PhotoBaseline(
                icloud: icloud.fingerprint, google: google.fingerprint, icloudHint: icloud.token, googleURLKey: google.token, syncedAt: now
            ))
        }
    }

    // MARK: profile photos

    /// Both contact photos are as the baseline says; the profile photo may still fill or refresh the iCloud one.
    private static func profileOutcome(
        _ baseline: PhotoBaseline, _ seen: PhotoSnapshot, icloud: Change, google: Change, profile: PhotoSeen?, now: Date
    ) -> Outcome? {
        if baseline.icloudOrigin == .googleProfile {
            guard icloud == .unchanged else { return record(baseline, seen, profile: nil, origin: .user, now: now) }
            // Profile photos turned off, or the profile photo is gone: the copy stays, as the user's own from now on.
            guard let profile else { return record(baseline, seen, profile: nil, origin: .user, now: now) }
            guard let known = baseline.googleProfile, profile.fingerprint.isSimilar(to: known) else {
                return .copyToICloud(.googleProfile, PhotoBaseline(
                    icloud: profile.fingerprint, googleProfile: profile.fingerprint, googleProfileKey: profile.token,
                    icloudOrigin: .googleProfile, syncedAt: now
                ))
            }
            return nil
        }
        if icloud == .absent, google == .absent, let profile {
            var filled = baseline
            filled.icloud = profile.fingerprint
            filled.icloudHint = nil
            filled.googleProfile = profile.fingerprint
            filled.googleProfileKey = profile.token
            filled.icloudOrigin = .googleProfile
            filled.syncedAt = now
            filled.pendingRemoval = nil
            return .copyToICloud(.googleProfile, filled)
        }
        return nil
    }

    // MARK: baselines

    /// The baseline for a pair whose photos agree as they are now: nothing is stored unless something moved.
    private static func record(
        _ baseline: PhotoBaseline, _ seen: PhotoSnapshot, profile: PhotoSeen?, origin: PhotoOrigin? = nil, now: Date
    ) -> Outcome {
        let updated = agreed(baseline, seen, profile: profile, origin: origin ?? baseline.icloudOrigin, now: now)
        var unstamped = updated
        unstamped.syncedAt = baseline.syncedAt
        return unstamped == baseline ? .settled : .record(updated)
    }

    /// The baseline with both sides as seen now. A picture still similar to the baseline's keeps the baseline's fingerprint,
    /// so many tiny differences cannot add up to a change; only its sign (hint or URL key) moves.
    private static func agreed(
        _ baseline: PhotoBaseline, _ seen: PhotoSnapshot, profile: PhotoSeen?, origin: PhotoOrigin, now: Date
    ) -> PhotoBaseline {
        var updated = baseline
        updated.icloud = settledFingerprint(seen.icloud, baseline.icloud)
        updated.icloudHint = seen.icloud?.token
        updated.google = settledFingerprint(seen.google, baseline.google)
        updated.googleURLKey = seen.google?.token
        if let profile {
            updated.googleProfile = settledFingerprint(profile, baseline.googleProfile)
            updated.googleProfileKey = profile.token
        }
        updated.icloudOrigin = origin
        updated.syncedAt = now
        updated.pendingRemoval = nil
        return updated
    }

    private static func settledFingerprint(_ seen: PhotoSeen?, _ known: PhotoFingerprint?) -> PhotoFingerprint? {
        guard let seen else { return nil }
        if let known, seen.fingerprint.isSimilar(to: known) { return known }
        return seen.fingerprint
    }

    /// The baseline after `source` has been copied to the `target` side: both sides then hold that picture. The target's own
    /// sign is not known until it is written, so it is left for the executor.
    private static func copied(
        _ baseline: PhotoBaseline, from source: PhotoSeen, seen: PhotoSnapshot, now: Date, to target: PhotoSide
    ) -> PhotoBaseline {
        var updated = baseline
        updated.icloud = source.fingerprint
        updated.google = source.fingerprint
        switch target {
        case .google:
            updated.icloudHint = source.token
            updated.googleURLKey = nil
        case .icloud:
            updated.icloudHint = nil
            updated.googleURLKey = source.token
        }
        updated.icloudOrigin = .user
        updated.syncedAt = now
        updated.pendingRemoval = nil
        return updated
    }
}
