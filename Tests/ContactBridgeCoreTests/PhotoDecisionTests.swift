import Foundation
import Testing
@testable import ContactBridgeCore

/// The decision table for one pair's photos, scenario by scenario. Fingerprints are made up: `a` and `b` are different
/// pictures, `a2` is `a` after a recompression.
struct PhotoDecisionTests {
    private let t0 = SyncFixtures.t0
    private let a = PhotoDecisionTests.print(0x00, colour: 40)
    private let a2 = PhotoDecisionTests.print(0x03, colour: 44)
    private let b = PhotoDecisionTests.print(UInt64.max, colour: 210)
    private let c = PhotoDecisionTests.print(0xFFFF_FFFF_0000_0000, colour: 120)
    private let profile = PhotoDecisionTests.print(0x0F0F_0F0F_0F0F_0F0F, colour: 90)
    private let profile2 = PhotoDecisionTests.print(0xF0F0_F0F0_F0F0_F0F0, colour: 170)

    private static func print(_ hash: UInt64, colour: UInt8) -> PhotoFingerprint {
        PhotoFingerprint(hash: hash, colors: Data(repeating: colour, count: 48))
    }

    private func seen(_ fingerprint: PhotoFingerprint?, _ token: String?) -> PhotoSeen? {
        fingerprint.map { PhotoSeen(fingerprint: $0, token: token) }
    }

    private func snapshot(
        icloud: PhotoFingerprint? = nil, google: PhotoFingerprint? = nil, profile: PhotoFingerprint? = nil, hint: String? = "h",
        key: String? = "k", profileKey: String? = "pk"
    ) -> PhotoSnapshot {
        PhotoSnapshot(icloud: seen(icloud, hint), google: seen(google, key), profile: seen(profile, profileKey))
    }

    private func baseline(
        icloud: PhotoFingerprint? = nil, google: PhotoFingerprint? = nil, profile: PhotoFingerprint? = nil,
        origin: PhotoOrigin = .user, pending: PhotoBaseline.PendingRemoval? = nil
    ) -> PhotoBaseline {
        PhotoBaseline(
            icloud: icloud, google: google, googleProfile: profile, icloudHint: icloud == nil ? nil : "h",
            googleURLKey: google == nil ? nil : "k", googleProfileKey: profile == nil ? nil : "pk", icloudOrigin: origin, syncedAt: t0,
            pendingRemoval: pending
        )
    }

    private func decide(
        _ base: PhotoBaseline?, _ now: PhotoSnapshot, profileOn: Bool = false, after seconds: TimeInterval = 0
    ) -> PhotoDecision.Outcome {
        PhotoDecision.decide(baseline: base, seen: now, profileEnabled: profileOn, now: t0.addingTimeInterval(seconds))
    }

    private func recorded(_ outcome: PhotoDecision.Outcome) -> PhotoBaseline? {
        if case .record(let baseline) = outcome { baseline } else { nil }
    }

    // MARK: first sight

    @Test("First sight, no photo on either side: an empty baseline is recorded, so the pair is not looked at again")
    func firstSightNeither() {
        let outcome = decide(nil, snapshot())
        let stored = recorded(outcome)
        #expect(stored?.icloud == nil && stored?.google == nil && stored?.icloudOrigin == .user && stored?.pendingRemoval == nil)
    }

    @Test("First sight, only iCloud has a photo: it is copied to Google")
    func firstSightOnlyICloud() throws {
        guard case .copyToGoogle(let base) = decide(nil, snapshot(icloud: a, hint: "ih")) else { Issue.record("expected a copy to Google"); return }
        #expect(base.icloud == a && base.google == a && base.icloudHint == "ih" && base.icloudOrigin == .user)
    }

    @Test("First sight, only the Google contact photo exists: it is copied to iCloud")
    func firstSightOnlyGoogle() throws {
        guard case .copyToICloud(.googleContact, let base) = decide(nil, snapshot(google: a, key: "gk")) else {
            Issue.record("expected a copy to iCloud")
            return
        }
        #expect(base.icloud == a && base.google == a && base.googleURLKey == "gk")
    }

    @Test("First sight, both sides have the same picture: baseline only")
    func firstSightSame() throws {
        let stored = try #require(recorded(decide(nil, snapshot(icloud: a, google: a2, hint: "ih", key: "gk"))))
        #expect(stored.icloud == a && stored.google == a2 && stored.icloudHint == "ih" && stored.googleURLKey == "gk")
    }

    @Test("First sight, both sides have different pictures: a review, nothing written")
    func firstSightDiffers() {
        #expect(decide(nil, snapshot(icloud: a, google: b)) == .review(.firstSightDiffers))
    }

    @Test("First sight with only a profile photo and profile photos off: the profile photo is ignored")
    func firstSightProfileIgnoredWhenOff() throws {
        let stored = try #require(recorded(decide(nil, snapshot(profile: profile))))
        #expect(stored.icloud == nil && stored.googleProfile == nil && stored.googleProfileKey == nil)
    }

    // MARK: with a baseline

    @Test("Nothing changed, or only recompressed: nothing is stored")
    func unchanged() {
        #expect(decide(baseline(icloud: a, google: a), snapshot(icloud: a2, google: a2, hint: "h", key: "k")) == .settled)
        #expect(decide(baseline(), snapshot()) == .settled)
    }

    @Test("A moved sign over a similar picture (a baseline moved by Dedupe) is recorded as unchanged, never as a change")
    func movedSignSimilarPicture() throws {
        let stored = try #require(recorded(decide(baseline(icloud: a, google: a), snapshot(icloud: a2, google: a, hint: "other", key: "k"))))
        #expect(stored.icloudHint == "other" && stored.icloud == a, "the baseline fingerprint stays the reference")
    }

    @Test("Changed in iCloud only: copied to Google")
    func icloudChanged() {
        guard case .copyToGoogle(let base) = decide(baseline(icloud: a, google: a), snapshot(icloud: b, google: a, hint: "new")) else {
            Issue.record("expected a copy to Google")
            return
        }
        #expect(base.icloud == b && base.google == b && base.icloudHint == "new")
    }

    @Test("Changed in Google only: copied to iCloud")
    func googleChanged() {
        guard case .copyToICloud(.googleContact, let base) = decide(baseline(icloud: a, google: a), snapshot(icloud: a, google: b, key: "new")) else {
            Issue.record("expected a copy to iCloud")
            return
        }
        #expect(base.icloud == b && base.googleURLKey == "new")
    }

    @Test("A photo added in iCloud where there was none is copied to Google; one added in Google, to iCloud")
    func photoAdded() {
        if case .copyToGoogle = decide(baseline(), snapshot(icloud: a)) {} else { Issue.record("iCloud's new photo goes to Google") }
        if case .copyToICloud(.googleContact, _) = decide(baseline(), snapshot(google: a)) {} else { Issue.record("Google's new photo goes to iCloud") }
    }

    @Test("Changed on both sides to the same picture: baseline only")
    func bothChangedSame() throws {
        let stored = try #require(recorded(decide(baseline(icloud: a, google: a), snapshot(icloud: b, google: b))))
        #expect(stored.icloud == b && stored.google == b)
    }

    @Test("Changed on both sides to different pictures: a review")
    func bothChangedDifferently() {
        #expect(decide(baseline(icloud: a, google: a), snapshot(icloud: b, google: c)) == .review(.bothChanged))
    }

    // MARK: removals

    @Test("Removed in iCloud, Google unchanged: only noted the first time; no question yet")
    func removedInICloudFirstSighting() throws {
        let stored = try #require(recorded(decide(baseline(icloud: a, google: a), snapshot(google: a), after: 60)))
        #expect(stored.pendingRemoval == PhotoBaseline.PendingRemoval(side: .icloud, firstSeenAt: t0.addingTimeInterval(60)))
        #expect(stored.icloud == a && stored.google == a, "the baseline still says what both sides last agreed on")
    }

    @Test("Removed in iCloud and seen again five minutes later: the user is asked")
    func removedInICloudSecondSighting() {
        let pending = PhotoBaseline.PendingRemoval(side: .icloud, firstSeenAt: t0)
        let base = baseline(icloud: a, google: a, pending: pending)
        #expect(decide(base, snapshot(google: a), after: 300) == .review(.removedInICloud))
        #expect(decide(base, snapshot(google: a), after: 299) == .settled, "a run too soon after the first changes nothing")
    }

    @Test("Removed in Google, iCloud unchanged: noted once, then the user is asked")
    func removedInGoogle() throws {
        let first = try #require(recorded(decide(baseline(icloud: a, google: a), snapshot(icloud: a), after: 10)))
        #expect(first.pendingRemoval?.side == .google)
        #expect(decide(first, snapshot(icloud: a), after: 10 + 600) == .review(.removedInGoogle))
    }

    @Test("A removal that was only a flap (the photo is back on the next run) is forgotten")
    func removalFlap() throws {
        let pending = PhotoBaseline.PendingRemoval(side: .icloud, firstSeenAt: t0)
        let stored = try #require(recorded(decide(baseline(icloud: a, google: a, pending: pending), snapshot(icloud: a, google: a), after: 900)))
        #expect(stored.pendingRemoval == nil)
    }

    @Test("Removed on one side and changed on the other: a review at once")
    func removedAndChanged() {
        #expect(decide(baseline(icloud: a, google: a), snapshot(google: b)) == .review(.removedOneChangedOther))
        #expect(decide(baseline(icloud: a, google: a), snapshot(icloud: b)) == .review(.removedOneChangedOther))
    }

    @Test("Removed on both sides: baseline only")
    func removedOnBoth() throws {
        let stored = try #require(recorded(decide(baseline(icloud: a, google: a), snapshot())))
        #expect(stored.icloud == nil && stored.google == nil && stored.pendingRemoval == nil)
    }

    @Test("A photo removed in iCloud that Google never had has nothing to ask about")
    func removedInICloudGoogleNever() throws {
        let stored = try #require(recorded(decide(baseline(icloud: a), snapshot())))
        #expect(stored.icloud == nil && stored.pendingRemoval == nil)
    }

    // MARK: Google profile photos

    @Test("Profile photos on and neither side has a photo: the profile photo goes to iCloud, tagged as a profile copy")
    func profileFillsEmptyContact() {
        guard case .copyToICloud(.googleProfile, let base) = decide(baseline(), snapshot(profile: profile, profileKey: "p1"), profileOn: true) else {
            Issue.record("expected the profile photo to be copied to iCloud")
            return
        }
        #expect(base.icloudOrigin == .googleProfile && base.icloud == profile && base.google == nil)
        #expect(base.googleProfile == profile && base.googleProfileKey == "p1")
    }

    @Test("First sight with profile photos on and no photos: the same, with nothing written to Google")
    func profileFillsEmptyContactAtFirstSight() {
        guard case .copyToICloud(.googleProfile, let base) = decide(nil, snapshot(profile: profile), profileOn: true) else {
            Issue.record("expected the profile photo to be copied to iCloud")
            return
        }
        #expect(base.icloudOrigin == .googleProfile && base.google == nil)
    }

    @Test("The profile photo is not a side: an iCloud photo of the user's own is left alone, and nothing is pushed to Google")
    func profileIsNeverASide() {
        #expect(decide(baseline(icloud: a, google: a), snapshot(icloud: a, google: a, profile: profile), profileOn: true) == .settled)
        // iCloud's own new photo is copied to Google as usual, and the profile photo plays no part.
        if case .copyToGoogle(let base) = decide(baseline(), snapshot(icloud: a, profile: profile), profileOn: true) {
            #expect(base.icloudOrigin == .user)
        } else {
            Issue.record("iCloud's own photo goes to Google")
        }
    }

    @Test("A profile-origin iCloud photo follows a changed profile photo")
    func profileChangeFollowed() {
        let base = baseline(icloud: profile, profile: profile, origin: .googleProfile)
        guard case .copyToICloud(.googleProfile, let after) = decide(base, snapshot(icloud: profile, profile: profile2, profileKey: "p2"), profileOn: true) else {
            Issue.record("expected the new profile photo to be copied")
            return
        }
        #expect(after.icloud == profile2 && after.googleProfileKey == "p2" && after.icloudOrigin == .googleProfile)
    }

    @Test("A profile-origin iCloud photo and an unchanged profile photo: nothing happens")
    func profileUnchanged() {
        let base = baseline(icloud: profile, profile: profile, origin: .googleProfile)
        #expect(decide(base, snapshot(icloud: profile, profile: profile, hint: "h", profileKey: "pk"), profileOn: true) == .settled)
    }

    @Test("The user sets a different iCloud photo over a profile copy: it becomes theirs and is copied to Google")
    func userPhotoOverProfileCopy() {
        let base = baseline(icloud: profile, profile: profile, origin: .googleProfile)
        guard case .copyToGoogle(let after) = decide(base, snapshot(icloud: b, profile: profile2), profileOn: true) else {
            Issue.record("expected a copy to Google")
            return
        }
        #expect(after.icloudOrigin == .user && after.icloud == b)
    }

    @Test("Google gains its own contact photo: it replaces a profile copy in iCloud, and the photo is the user's from then on")
    func contactPhotoReplacesProfileCopy() {
        let base = baseline(icloud: profile, profile: profile, origin: .googleProfile)
        guard case .copyToICloud(.googleContact, let after) = decide(base, snapshot(icloud: profile, google: b, profile: profile), profileOn: true) else {
            Issue.record("expected the contact photo to replace the profile copy")
            return
        }
        #expect(after.icloudOrigin == .user && after.icloud == b && after.google == b)
    }

    @Test("Profile photos turned off: the copy stays in iCloud, as the user's own, and is never removed")
    func profileSettingTurnedOff() throws {
        let base = baseline(icloud: profile, profile: profile, origin: .googleProfile)
        let stored = try #require(recorded(decide(base, snapshot(icloud: profile, profile: profile), profileOn: false)))
        #expect(stored.icloudOrigin == .user && stored.icloud == profile)
    }

    @Test("The profile photo disappears: the copy stays, as the user's own")
    func profilePhotoGone() throws {
        let base = baseline(icloud: profile, profile: profile, origin: .googleProfile)
        let stored = try #require(recorded(decide(base, snapshot(icloud: profile), profileOn: true)))
        #expect(stored.icloudOrigin == .user)
    }

    @Test("A profile copy removed in iCloud: noted once, then asked about as a profile removal")
    func profileCopyRemoved() throws {
        let base = baseline(icloud: profile, profile: profile, origin: .googleProfile)
        let first = try #require(recorded(decide(base, snapshot(profile: profile), profileOn: true)))
        #expect(first.pendingRemoval?.side == .icloud)
        #expect(decide(first, snapshot(profile: profile), profileOn: true, after: 400) == .review(.profileRemovedInICloud))
    }

    @Test("A profile copy removed while profile photos are off: nothing to ask, and the profile photo is not brought back")
    func profileCopyRemovedWhileOff() throws {
        let base = baseline(icloud: profile, profile: profile, origin: .googleProfile)
        let stored = try #require(recorded(decide(base, snapshot(profile: profile), profileOn: false)))
        #expect(stored.icloud == nil && stored.icloudOrigin == .user && stored.pendingRemoval == nil)
    }

    @Test("A contact opted out of profile photos never gets one")
    func profileOptOut() {
        #expect(decide(baseline(), snapshot(profile: profile), profileOn: false) == .settled)
        if case .record = decide(nil, snapshot(profile: profile), profileOn: false) {} else { Issue.record("an empty baseline is recorded") }
    }
}
