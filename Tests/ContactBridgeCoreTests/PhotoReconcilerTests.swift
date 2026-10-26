import Foundation
import Testing
@testable import ContactBridgeCore

/// What `PhotoReconciler.observe` reads, and (as importantly) what it leaves unread.
struct PhotoReconcilerTests {
    /// Four linked contacts whose photos have all been looked at once: I1 holds a photo that Google now has too.
    private func settledRig(count: Int = 4) async throws -> PhotoRig {
        let rig = try await PhotoRig.linked(count: count)
        try await rig.setICloudPhoto("I1", PhotoPictures.picture(1))
        try await rig.sync()
        return rig
    }

    // MARK: iCloud

    @Test("A pair whose photos were never looked at is read even though the iCloud scan found nothing")
    func firstSightReadsWithUnchangedScan() async throws {
        let rig = try await PhotoRig.linked(count: 3)
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", PhotoPictures.picture(1))
        let before = rig.store.photoReads
        let token = try await rig.store.changeToken()
        try rig.base.stateStore.update { $0.icloudChangeToken = token }

        let look = try await rig.look()
        #expect(look.scan.status == .unchanged && look.observed.wasObserved)
        #expect(look.observed.pairs.keys.sorted() == ["I1", "I2", "I3"] && look.observed.unevaluated.isEmpty)
        let seen = try #require(look.observed.pairs["I1"]?.seen.icloud)
        #expect(seen.token == PhotoHash.sha256Hex(PhotoPictures.picture(1)))
        #expect(look.observed.pairs["I2"]?.seen.icloud == nil)
        #expect(rig.store.photoReads.signatures == before.signatures + 1 && rig.store.photoReads.data == before.data + 1)
    }

    @Test("When the iCloud scan is unchanged and every pair has been looked at, no picture or signature is read at all")
    func unchangedScanReadsNothing() async throws {
        let rig = try await settledRig()
        defer { rig.cleanUp() }
        let before = rig.store.photoReads
        let requested = await rig.fetcher.requested.count

        let look = try await rig.look()
        #expect(look.scan.status == .unchanged)
        #expect(look.observed.pairs.count == 4 && look.plan.photoOps.isEmpty)
        #expect(rig.store.photoReads.data == before.data && rig.store.photoReads.signatures == before.signatures)
        #expect(await rig.fetcher.requested.count == requested)
    }

    @Test("A changed scan reads one signature per pair and a full picture only where the thumbnail hash differs from the baseline's")
    func changedScanReadsOnlyMovedPictures() async throws {
        let rig = try await settledRig()
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I2", PhotoPictures.picture(2))
        let before = rig.store.photoReads

        let look = try await rig.look()
        #expect(look.scan.status == .changed)
        #expect(rig.store.photoReads.signatures == before.signatures + 1, "all linked pairs in one call")
        #expect(rig.store.photoReads.data == before.data + 1, "only I2's picture is new; I1's hash still matches")
        #expect(look.observed.pairs["I1"]?.seen.icloud?.fingerprint == (try rig.photoBaseline("I1")?.icloud))
        #expect(look.observed.pairs["I2"]?.seen.icloud?.token == PhotoHash.sha256Hex(PhotoPictures.picture(2)))
    }

    @Test("A baseline whose hint does not match (moved by Dedupe) is compared by fingerprint: a similar picture is no change")
    func staleHintSimilarPicture() async throws {
        let rig = try await settledRig()
        defer { rig.cleanUp() }
        try rig.base.stateStore.update { $0.baselines["I1"]?.photo?.icloudHint = "the old contact's hash" }
        try await rig.setPhone("I2")
        let before = rig.store.photoReads.data

        let look = try await rig.look()
        #expect(rig.store.photoReads.data == before + 1, "the picture is read to be compared")
        let ops = look.plan.photoOps.filter { $0.icloudID == "I1" }
        #expect(ops.count == 1 && ops[0].kind == .recordBaseline, "recorded with the right hint, not copied anywhere")
        #expect(ops[0].baseline.icloudHint == PhotoHash.sha256Hex(PhotoPictures.picture(1)))
        #expect(look.plan.review.filter { $0.kind == .photoConflict }.isEmpty)
    }

    @Test("A pair waiting to confirm a removal is read again even when the iCloud scan found nothing")
    func pendingRemovalReadAgain() async throws {
        let rig = try await settledRig()
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", nil)
        try await rig.sync()
        #expect(try rig.photoBaseline("I1")?.pendingRemoval?.side == .icloud)
        let token = try await rig.store.changeToken()
        try rig.base.stateStore.update { $0.icloudChangeToken = token }
        rig.base.clock.advance(minutes: 6)

        let look = try await rig.look()
        #expect(look.scan.status == .unchanged)
        #expect(look.observed.pairs["I1"]?.seen.icloud == nil)
        #expect(look.plan.review.map(\.photoReason) == [.removedInICloud])
    }

    @Test("A pair the user is already being asked about is not read again while nothing about it changes")
    func questionedPairIsLeftAlone() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", PhotoPictures.picture(1))
        try await rig.setGooglePhoto(1, PhotoPictures.picture(2))
        let token = try await rig.store.changeToken()
        let listed = try await GoogleChangeFeed(client: rig.google, fieldsVersion: rig.base.world.feedFieldsVersion)
            .fetch(state: try rig.state, accountEmail: rig.base.world.account)
        try rig.base.stateStore.update {
            $0.icloudChangeToken = token
            $0.googleSyncToken = listed.nextSyncToken
        }
        let look = try await rig.look()
        #expect(look.scan.status == .unchanged && look.feed.people.isEmpty)
        let before = rig.store.photoReads

        let skipped = try await rig.reconciler().observe(
            icloud: look.scan, feed: look.feed, state: try rig.state, links: try rig.base.linkStore.load(), questioned: ["I1"]
        )
        #expect(skipped.pairs.keys.sorted() == ["I2"] && skipped.unevaluated.isEmpty)
        #expect(rig.store.photoReads.data == before.data, "only I2 was read (it has no picture)")

        let changed = try await rig.look(.syncNow)
        let again = try await rig.reconciler().observe(
            icloud: changed.scan, feed: changed.feed, state: try rig.state, links: try rig.base.linkStore.load(), questioned: ["I1"]
        )
        #expect(again.pairs["I1"] != nil, "a changed scan looks at everything")
    }

    // MARK: Google

    @Test("A person the listing did not mention is not downloaded, and neither is a listed one whose photo URL key is the baseline's")
    func googleSkipsKnownPhotos() async throws {
        let rig = try await settledRig()
        defer { rig.cleanUp() }
        let requested = await rig.fetcher.requested.count

        // Not listed: only iCloud moved.
        try await rig.setICloudPhoto("I2", PhotoPictures.picture(2))
        _ = try await rig.look()
        #expect(await rig.fetcher.requested.count == requested)

        // Listed (the contact was edited) with the same photo.
        try await rig.base.world.editGoogle("people/c1", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Annie")] }
        let look = try await rig.look()
        #expect(look.feed.people["people/c1"] != nil)
        #expect(await rig.fetcher.requested.count == requested)
        #expect(look.observed.pairs["I1"]?.seen.google?.fingerprint == (try rig.photoBaseline("I1")?.google))
    }

    @Test("A listed person whose photo URL key moved has it downloaded at 128 px")
    func googleDownloadsChangedPhoto() async throws {
        let rig = try await settledRig()
        defer { rig.cleanUp() }
        try await rig.setGooglePhoto(1, PhotoPictures.picture(7))
        let requested = await rig.fetcher.requested.count

        let look = try await rig.look()
        let downloads = await rig.fetcher.requested
        #expect(downloads.count == requested + 1 && downloads.last?.absoluteString.hasSuffix("=s128") == true)
        #expect(look.observed.downloads == 1 && look.observed.pairs["I1"]?.seen.google != nil)
    }

    @Test("A person Google did not list is fetched when its pair was never looked at, and its photo downloaded")
    func unlistedFirstSightPairIsFetched() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setGooglePhoto(2, PhotoPictures.picture(3))
        let token = try await rig.store.changeToken()
        try rig.base.stateStore.update { $0.icloudChangeToken = token }
        // Everything is in the baselines already, so the incremental listing is empty... after the photo edit it lists c2 only;
        // take the listing's token past it so the feed really does not mention the person.
        let first = try await GoogleChangeFeed(client: rig.google, fieldsVersion: rig.base.world.feedFieldsVersion).fetch(state: try rig.state, accountEmail: rig.base.world.account)
        try rig.base.stateStore.update { $0.googleSyncToken = first.nextSyncToken }

        let look = try await rig.look()
        #expect(look.feed.people.isEmpty && !look.feed.isFullListing)
        #expect(look.observed.pairs["I2"]?.seen.google != nil, "read with getPerson, then downloaded")
        #expect(look.plan.photoOps.contains { $0.icloudID == "I2" && $0.kind == .copyToICloud(source: .googleContact) })
    }

    @Test("Downloads stop at the limit: the pairs left over are unevaluated, the plan keeps its checkpoint back, and the review is incomplete")
    func downloadLimit() async throws {
        let rig = try await PhotoRig.linked(count: 5)
        defer { rig.cleanUp() }
        for index in 1...5 { try await rig.setGooglePhoto(index, PhotoPictures.picture(UInt64(index))) }

        let look = try await rig.look(.syncNow, maxDownloads: 2)
        #expect(look.observed.downloads == 2 && look.observed.unevaluated == ["I3", "I4", "I5"])
        #expect(look.observed.pairs.keys.sorted() == ["I1", "I2"])
        #expect(look.plan.photosUnevaluated == 3 && look.plan.checkpoint == nil && !look.plan.photoReviewIsComplete && !look.plan.isEmpty)
        #expect(PhotoReconciler.maxDownloads == 300 && PhotoReconciler.parallelDownloads == 4)
    }

    @Test("At most four photos are downloaded at once")
    func parallelDownloads() async throws {
        let rig = try await PhotoRig.linked(count: 12)
        defer { rig.cleanUp() }
        for index in 1...12 { try await rig.setGooglePhoto(index, PhotoPictures.picture(UInt64(index))) }
        let probe = ConcurrencyProbe(rig.fetcher)

        let look = try await rig.look(.syncNow, fetcher: probe)
        #expect(look.observed.downloads == 12 && look.observed.pairs.count == 12)
        let peak = await probe.peak
        #expect(peak > 1 && peak <= 4)
    }

    @Test("A download that fails leaves that pair unevaluated; the others are decided")
    func failedDownload() async throws {
        let rig = try await PhotoRig.linked(count: 3)
        defer { rig.cleanUp() }
        for index in 1...3 { try await rig.setGooglePhoto(index, PhotoPictures.picture(UInt64(index))) }
        await rig.fetcher.failNext(with: .http(503))

        let look = try await rig.look(.syncNow)
        #expect(look.observed.unevaluated.count == 1 && look.observed.pairs.count == 2)
        #expect(look.plan.photoOps.count == 2 && look.plan.checkpoint == nil)
    }

    @Test("A pair the user keeps apart, or whose Google contact is ignored, is not looked at")
    func ignoredAndKeptSeparate() async throws {
        let rig = try await PhotoRig.linked(count: 3)
        defer { rig.cleanUp() }
        try rig.base.stateStore.update {
            $0.ignoredGoogle.insert("people/c1")
            $0.keepSeparate.insert("I2|people/c2")
        }
        let look = try await rig.look(.syncNow)
        #expect(look.observed.pairs.keys.sorted() == ["I3"])
    }

    // MARK: the switches

    @Test("With photo sync off nothing is read at all and nothing is planned")
    func masterSwitchOff() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        try await rig.setICloudPhoto("I1", PhotoPictures.picture(1))
        try rig.base.stateStore.update { $0.syncPhotos = false }
        let before = rig.store.photoReads

        let look = try await rig.look(.syncNow)
        #expect(!look.observed.wasObserved && look.observed.pairs.isEmpty && look.plan.photoOps.isEmpty)
        #expect(rig.store.photoReads.signatures == before.signatures && rig.store.photoReads.data == before.data)
        #expect(await rig.fetcher.requested.isEmpty)
    }

    @Test("The profile photo is downloaded only for a contact with no photo of its own")
    func profileDownloadedOnlyWhenUseful() async throws {
        let rig = try await PhotoRig.linked(count: 3)
        defer { rig.cleanUp() }
        try rig.base.stateStore.update { $0.useGoogleProfilePhotos = true }
        for index in 1...3 { try await rig.setGoogleProfile(index, PhotoPictures.picture(UInt64(10 + index))) }
        try await rig.setGooglePhoto(2, PhotoPictures.picture(2))       // its own Google photo
        try await rig.setICloudPhoto("I3", PhotoPictures.picture(3))    // its own iCloud photo

        let look = try await rig.look(.syncNow)
        #expect(look.observed.pairs["I1"]?.seen.profile != nil)
        #expect(look.observed.pairs["I2"]?.seen.profile == nil && look.observed.pairs["I3"]?.seen.profile == nil)
        #expect(look.observed.downloads == 2, "I1's profile photo and I2's contact photo; nothing for I3's profile")
        #expect(look.plan.photoOps.first { $0.icloudID == "I1" }?.kind == .copyToICloud(source: .googleProfile))
    }

    @Test("Profile photos off, or the contact opted out: the profile photo is never downloaded")
    func profileOffOrOptedOut() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        for index in 1...2 { try await rig.setGoogleProfile(index, PhotoPictures.picture(UInt64(index))) }
        var look = try await rig.look(.syncNow)
        #expect(look.observed.downloads == 0 && look.plan.photoOps.allSatisfy { $0.kind == .recordBaseline })

        try rig.base.stateStore.update {
            $0.useGoogleProfilePhotos = true
            $0.profilePhotoOptOut = ["I1"]
        }
        look = try await rig.look(.syncNow)
        #expect(look.observed.downloads == 1 && look.observed.pairs["I1"]?.seen.profile == nil && look.observed.pairs["I2"]?.seen.profile != nil)
    }

    @Test("With profile photos on, a full Google listing is due once a day; otherwise never")
    func fullListingDue() {
        let t0 = SyncFixtures.t0
        var state = SyncState()
        #expect(!PhotoReconciler.fullListingDue(state: state, now: t0), "profile photos off")
        state.useGoogleProfilePhotos = true
        #expect(PhotoReconciler.fullListingDue(state: state, now: t0), "never listed for photos")
        state.lastPhotoFullListingAt = t0
        #expect(!PhotoReconciler.fullListingDue(state: state, now: t0.addingTimeInterval(24 * 3600 - 1)))
        #expect(PhotoReconciler.fullListingDue(state: state, now: t0.addingTimeInterval(24 * 3600)))
        state.syncPhotos = false
        #expect(!PhotoReconciler.fullListingDue(state: state, now: t0.addingTimeInterval(48 * 3600)))
    }
}

extension PhotoRig {
    /// Any edit that moves the iCloud token without touching photos.
    func setPhone(_ id: String) async throws { try await base.setPhone(id, "415-555-8888") }
}
