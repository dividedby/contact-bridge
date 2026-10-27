import Foundation
import Testing
@testable import ContactBridgeCore

/// iCloud photos the Contacts framework refuses with error 134092, written through the Contacts app instead.
struct PhotoContactsAppFallbackTests {
    private let one = PhotoPictures.picture(1)
    private let two = PhotoPictures.picture(2)

    /// Writes the way the Contacts app does: the store's refusal does not apply.
    private struct ContactsAppStandIn: ContactsAppPhotoWriting {
        let store: InMemoryContactStore
        func setPhoto(_ data: Data?, forID id: String) async throws { try store.setPhotoAsContactsApp(id: id, data: data) }
    }

    private struct RefusingContactsApp: ContactsAppPhotoWriting {
        func setPhoto(_ data: Data?, forID id: String) async throws { throw NotesAccessError.notAuthorized }
    }

    /// I2's Google photo is to be copied into iCloud, where the framework refuses it.
    private func refusedCopy() async throws -> (PhotoRig, [PlannedPhotoOp]) {
        let rig = try await PhotoRig.linked(count: 2)
        try await rig.setGooglePhoto(2, two)
        rig.store.setRefusesPhotoWrites(["I2"])
        let ops = try await rig.look(.syncNow, fullListing: true).plan.photoOps.filter { $0.icloudID == "I2" }
        try #require(ops.map(\.kind) == [.copyToICloud(source: .googleContact)])
        return (rig, ops)
    }

    @Test("A photo the framework refuses with 134092 goes in through the Contacts app and counts once it reads back")
    func fallbackWrites() async throws {
        let (rig, ops) = try await refusedCopy()
        defer { rig.cleanUp() }

        let report = try await rig.executor(icloudFallback: ContactsAppStandIn(store: rig.store)).execute(ops)
        #expect(report.copiedToICloud == 1 && report.skipped.isEmpty && report.isComplete)
        #expect(try await rig.icloudPhoto("I2") != nil)
        #expect(try rig.photoBaseline("I2")?.icloudHint != nil && rig.photoBaseline("I2")?.failure == nil)
    }

    @Test("Without the Contacts app, or when it fails too, the photo is given up on with the 134092 message")
    func fallbackMissingOrFailing() async throws {
        for fallback in [nil, RefusingContactsApp()] as [(any ContactsAppPhotoWriting)?] {
            let (rig, ops) = try await refusedCopy()
            defer { rig.cleanUp() }
            let report = try await rig.executor(icloudFallback: fallback).execute(ops)
            #expect(report.copiedToICloud == 0 && report.givenUp.map(\.icloudID) == ["I2"])
            #expect(try rig.photoBaseline("I2")?.failure?.message.contains("134092") == true)
            #expect(try await rig.icloudPhoto("I2") == nil)
        }
    }

    /// I2's copy given up on for 134092, I1 settled with the same picture on both sides; then a quiet run, so the next
    /// listing is incremental and names nobody.
    private func givenUp() async throws -> (PhotoRig, settled: PhotoBaseline) {
        let (rig, ops) = try await refusedCopy()
        try await rig.setICloudPhoto("I1", one)
        try await rig.setGooglePhoto(1, one)
        _ = try await rig.executor().execute(ops)
        _ = try await rig.executor().execute(try await rig.look(.syncNow, fullListing: true).plan.photoOps)
        let settled = try #require(try rig.photoBaseline("I1"))
        try #require(try rig.photoBaseline("I2")?.failure != nil)
        // Stores the tokens: from here on Google lists only what changes.
        let quiet = try await rig.sync()
        #expect(try quiet.photos.copiedToICloud == 0 && rig.photoBaseline("I2")?.failure != nil, "given up on: not tried again")
        #expect(try await rig.look(.syncNow).feed.people.isEmpty, "an incremental listing that names nobody")
        return (rig, settled)
    }

    /// The next incremental run plans I2's copy and the Contacts app puts it in.
    private func copiesI2(_ rig: PhotoRig) async throws {
        let again = try await rig.look(.syncNow).plan.photoOps
        #expect(again.map(\.icloudID) == ["I2"])
        let report = try await rig.executor(icloudFallback: ContactsAppStandIn(store: rig.store)).execute(again)
        #expect(report.copiedToICloud == 1 && report.isComplete)
        #expect(try await rig.icloudPhoto("I2") != nil)
    }

    @Test("Repair from version 1 drops only the 134092 pair's record, skips version 1's step, and the photo then goes in")
    func repairRetriesLostPictureFiles() async throws {
        let (rig, settled) = try await givenUp()
        defer { rig.cleanUp() }

        try rig.base.stateStore.update { $0.photoRepairVersion = 1 }
        let fresh = try await PhotoRepair.run(store: rig.store, state: rig.base.stateStore, reviews: rig.base.reviews)
        #expect(try fresh.isEmpty && rig.photoBaseline("I1") == settled, "version 1's look afresh did not run again")
        #expect(try rig.photoBaseline("I2") == nil && rig.state.photoRepairVersion == PhotoRepair.currentVersion)
        try await copiesI2(rig)
    }

    @Test("Repair from version 2 (failure cleared, empty record kept) drops the empty record, and the photo then goes in")
    func repairDropsEmptyRecords() async throws {
        let (rig, settled) = try await givenUp()
        defer { rig.cleanUp() }
        try rig.base.stateStore.update {
            $0.baselines["I2"]?.photo?.failure = nil
            $0.photoRepairVersion = 2
        }
        #expect(try await rig.look(.syncNow).plan.photoOps.isEmpty, "an empty record leaves the pair unread")

        try await PhotoRepair.run(store: rig.store, state: rig.base.stateStore, reviews: rig.base.reviews)
        #expect(try rig.photoBaseline("I2") == nil && rig.photoBaseline("I1") == settled)
        try await copiesI2(rig)
    }

    @Test("Other failure markers are left alone by the repair")
    func repairKeepsOtherFailures() async throws {
        let rig = try await PhotoRig.linked(count: 2)
        defer { rig.cleanUp() }
        let stamp = PhotoBaseline.Failure(stamp: "s", message: "Google refused the picture", at: SyncFixtures.t0)
        try rig.base.stateStore.update { $0.baselines["I1"]?.photo = PhotoBaseline(syncedAt: SyncFixtures.t0, failure: stamp) }
        #expect(try PhotoRepair.retryLostPictureFiles(state: rig.base.stateStore).isEmpty)
        #expect(try rig.photoBaseline("I1")?.failure == stamp)
    }

    // MARK: the writer

    private let awake: Result<NSAppleEventDescriptor, AppleScriptError> = .success(NSAppleEventDescriptor(int32: 3))
    private let done: Result<NSAppleEventDescriptor, AppleScriptError> = .success(NSAppleEventDescriptor(boolean: true))

    @Test("Setting sends the id, its UUID part and a TIFF picture; removing sends no picture")
    func writerScripts() async throws {
        let runner = FakeAppleScriptRunner(responses: [awake, done, awake, done])
        let writer = ContactsAppPhotoWriter(runner: runner, retryDelay: .zero)
        try await writer.setPhoto(one, forID: "ABC-1:ABPerson")
        try await writer.setPhoto(nil, forID: "ABC-1:ABPerson")

        guard case .run(let wake) = runner.calls[0], case .call(let setHandler, _, let setArguments) = runner.calls[1],
              case .call(let removeHandler, _, let removeArguments) = runner.calls[3]
        else { Issue.record("expected a plain script before each handler call"); return }
        #expect(wake == ContactsAppScript.wakeScript)
        #expect(setHandler == "setPhoto" && removeHandler == "removePhoto")
        #expect(setArguments.prefix(2).map(\.stringValue) == ["ABC-1:ABPerson", "ABC-1"] && setArguments.count == 3)
        #expect(setArguments[2].descriptorType == ContactsAppPhotoWriter.tiffType)
        let tiff = setArguments[2].data
        #expect(tiff.starts(with: [0x4D, 0x4D]) || tiff.starts(with: [0x49, 0x49]), "TIFF byte-order mark")
        #expect(removeArguments.map(\.stringValue) == ["ABC-1:ABPerson", "ABC-1"])
    }

    @Test("Contacts not running yet is tried once more; a picture that cannot be decoded sends nothing")
    func writerRetryAndBadPicture() async throws {
        let runner = FakeAppleScriptRunner(responses: [
            .failure(AppleScriptError(number: AppleScriptError.appNotRunning, message: "not running")), awake, done,
        ])
        try await ContactsAppPhotoWriter(runner: runner, retryDelay: .zero).setPhoto(one, forID: "ABC-1:ABPerson")
        #expect(runner.calls.count == 3)

        let idle = FakeAppleScriptRunner()
        await #expect(throws: PhotoEncodingError.undecodable) {
            try await ContactsAppPhotoWriter(runner: idle, retryDelay: .zero).setPhoto(Data("not a picture".utf8), forID: "ABC-1:ABPerson")
        }
        #expect(idle.calls.isEmpty)
    }
}
