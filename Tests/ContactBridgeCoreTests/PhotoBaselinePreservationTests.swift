import Foundation
import Testing
@testable import ContactBridgeCore

/// Photo sync owns `SyncBaseline.photo`; every other place that writes a baseline must leave it as it found it, or hand a new
/// baseline an empty one. One test per place that constructs or rewrites a baseline.
struct PhotoBaselinePreservationTests {
    private let marker = PhotoModelTests.photoBaseline(1)
    private let newer = PhotoModelTests.photoBaseline(7, at: SyncFixtures.t0.addingTimeInterval(600))

    private func mark(_ rig: ExecutorRig, _ ids: [String], _ photo: PhotoBaseline?) throws {
        try rig.stateStore.update { state in
            for id in ids { state.baselines[id]?.photo = photo }
        }
    }

    private func editGoogleNickname(_ world: SyncWorld, _ id: Int, to nickname: String) async throws {
        try await world.editGoogle("people/c\(id)", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: nickname)] }
    }

    /// Google rewrites the contact with the same content: the etag moves, nothing else does.
    private func churnGoogleEtag(_ world: SyncWorld, _ id: Int) async throws {
        try await world.editGoogle("people/c\(id)", mask: "phoneNumbers") { _ in }
    }

    // MARK: ThreeWayDiff

    @Test("ThreeWayDiff: the updated baseline keeps the photo, whether the diff pushes, takes Google's edit or holds one back")
    func threeWayDiff() throws {
        let icloud = SyncFixtures.icloud("I1", "Ann", "Lee", phones: ["415-555-0100"])
        var google = icloud
        google.id = "people/c1"
        google.source = .google
        google.sourceIdentifier = "people/c1"
        let base = SyncBaseline(
            icloud: icloud, google: google, googleEtag: "e1", icloudNoteHash: NoteHash.hash(""), googleNoteHash: NoteHash.hash(""),
            syncedAt: SyncFixtures.t0, photo: marker
        )
        var edited = icloud
        edited.nickname = "Annie"
        let push = ThreeWayDiff.diff(
            icloud: edited, google: google, base: base, icloudNoteHash: NoteHash.hash(""), googleNoteHash: NoteHash.hash(""), at: SyncFixtures.t0
        )
        #expect(push.needsPush && push.updatedBaseline.photo == marker)

        var googleEdited = google
        googleEdited.nickname = "A"
        let review = ThreeWayDiff.diff(
            icloud: icloud, google: googleEdited, base: base, icloudNoteHash: NoteHash.hash(""), googleNoteHash: NoteHash.hash(""),
            googleEtag: "e2", at: SyncFixtures.t0
        )
        #expect(review.needsReview && review.updatedBaseline.photo == marker)
    }

    // MARK: SyncPlanner

    @Test("SyncPlanner: an update's baseline and a refreshed baseline carry the photo baseline of the one they replace")
    func plannerUpdatesAndRefreshes() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try mark(rig, ["I1", "I2"], marker)
        try await rig.setPhone("I1", "415-555-9999")
        try await churnGoogleEtag(rig.world, 2)

        let plan = try await rig.plan()
        let update = try #require(plan.updates.first { $0.icloudID == "I1" })
        let refreshed = try #require(plan.baselineRefreshes["I2"])
        #expect(update.baseline.photo == marker && refreshed.photo == marker)
        #expect(refreshed.googleEtag != rig.world.state.baselines["I2"]?.googleEtag, "it really is a refreshed baseline")
    }

    @Test("SyncPlanner: a pair linked for the first time has no photo baseline, so its photos are looked at for the first time")
    func plannerNewLink() async throws {
        let icloud = SyncFixtures.icloud("I1", "Ann", "Lee", phones: ["415-555-0100"])
        let world = SyncWorld(icloud: [icloud], google: [SyncFixtures.person("Ann", "Lee", phones: ["415-555-0100"])])
        let plan = try await world.plan(.syncNow)
        let link = try #require(plan.links.first)
        #expect(link.baseline.photo == nil)
    }

    // MARK: SyncExecutor

    @Test("SyncExecutor: a pushed update keeps the photo baseline as it is in the state now, not as it was when the plan was made")
    func executorUpdate() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try mark(rig, ["I1"], marker)
        try await rig.setPhone("I1", "415-555-9999")
        let plan = try await rig.plan()
        #expect(plan.updates.first?.baseline.photo == marker)

        try mark(rig, ["I1"], newer)
        let report = try await rig.run(plan)
        #expect(report.updated == 1)
        let stored = try #require(try rig.state.baselines["I1"])
        #expect(stored.photo == newer && stored.icloud.phones.map(\.value) == ["415-555-9999"])
    }

    @Test("SyncExecutor: a baseline refresh keeps the current photo baseline")
    func executorRefresh() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try mark(rig, ["I2"], marker)
        try await churnGoogleEtag(rig.world, 2)
        let plan = try await rig.plan()
        #expect(plan.baselineRefreshes["I2"] != nil)

        try mark(rig, ["I2"], newer)
        _ = try await rig.run(plan)
        let stored = try #require(try rig.state.baselines["I2"])
        #expect(stored.photo == newer && stored.googleEtag == plan.baselineRefreshes["I2"]?.googleEtag)
    }

    @Test("SyncExecutor: a contact created in Google starts with no photo baseline, and a new link too")
    func executorCreate() async throws {
        let rig = try await ExecutorRig.linked(count: 2)
        defer { rig.cleanUp() }
        let carol = try await rig.addICloudContact("Carol", "Newman", phone: "415-555-0100", note: "n")
        let report = try await rig.sync()
        #expect(report.created == 1)
        let baseline = try #require(try rig.state.baselines[carol.sourceIdentifier])
        #expect(baseline.photo == nil)

        // A first-sync link (both contacts already existed) is the same.
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Ann", "Lee", phones: ["415-555-0100"])],
            google: [SyncFixtures.person("Ann", "Lee", phones: ["415-555-0100"])]
        )
        world.state.firstSyncApproved = true
        let linkRig = try ExecutorRig(world)
        defer { linkRig.cleanUp() }
        try await linkRig.sync()
        #expect(try linkRig.state.baselines["I1"] != nil && linkRig.state.baselines["I1"]?.photo == nil)
    }

    // MARK: SyncJournal recovery

    @Test("Journal recovery: an update recognised after a crash is baselined without touching the photo baseline")
    func journalRecovery() async throws {
        let rig = try await ExecutorRig.linked()
        defer { rig.cleanUp() }
        try mark(rig, ["I1"], marker)
        try await rig.setPhone("I1", "415-555-9999")
        rig.faulty.arm(.crashAfterApply, on: .batchUpdate)
        await #expect(throws: FaultyGoogle.Crash.self) { try await rig.sync() }
        try mark(rig, ["I1"], newer)

        let recovered = try await rig.makeExecutor().recoverInterruptedRun()
        #expect(recovered.applied == 1)
        let stored = try #require(try rig.state.baselines["I1"])
        #expect(stored.photo == newer)
        #expect(stored.googleEtag == (try await rig.googlePerson("people/c1")).etag)
    }

    // MARK: ReviewWorkflows

    private func googleEditedRig() async throws -> ReviewRig {
        let rig = try await ReviewRig.linked()
        try await rig.world.editGoogle("people/c2", mask: "organizations") { $0.organizations = [GoogleOrganization(name: "Fischer Design")] }
        try await rig.syncOnce()
        try mark(rig.base, ["I2"], marker)
        return rig
    }

    @Test("Review apply: a decision Google already agrees with only moves the baseline, and the photo baseline stays")
    func reviewApplyBaselineOnly() async throws {
        let rig = try await googleEditedRig()
        defer { rig.cleanUp() }
        let detail = try await rig.detail("googleEdited|I2|people/c2")
        #expect(try await rig.workflows.apply(detail) == .done(warnings: []))
        let baseline = try #require(try rig.state.baselines["I2"])
        #expect(baseline.photo == marker && baseline.icloud.organization == "Fischer Design")
    }

    @Test("Review apply: a decision that is copied to Google keeps the photo baseline through the executor")
    func reviewApplyUpdate() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.editGoogle("people/c2", mask: "organizations") { $0.organizations = [GoogleOrganization(name: "Brown Consulting")] }
        try await rig.world.editICloud("I2") { $0.organization = "Brown & Co" }
        try await rig.syncOnce()
        try mark(rig.base, ["I2"], marker)

        let detail = try await rig.detail("bothEdited|I2|people/c2")
        let planned = try #require(try rig.state.baselines["I2"])
        #expect(planned.photo == marker)
        #expect(try await rig.workflows.apply(detail) == .done(warnings: []))
        let baseline = try #require(try rig.state.baselines["I2"])
        let person = try await rig.base.googlePerson("people/c2")
        #expect(person.organizations?.first?.name == "Brown & Co" && baseline.googleEtag == person.etag && baseline.photo == marker)
    }

    @Test("Keep iCloud for all: baselines settled in bulk keep their photo baselines, for the baseline-only and the pushed alike")
    func reviewBulk() async throws {
        // I1: Google has an email iCloud lacks (nothing to write: baseline only). I2: the organisations differ (pushed).
        let icloud = [
            SyncFixtures.icloud("I1", "First1", "Last1", phones: ["415-555-0101"]),
            { var record = SyncFixtures.icloud("I2", "First2", "Last2", phones: ["415-555-0102"]); record.organization = "Acme 2"; return record }(),
        ]
        var withEmail = SyncFixtures.person("First1", "Last1", phones: ["415-555-0101"], emails: ["g1@example.com"])
        withEmail.organizations = nil
        var other = SyncFixtures.person("First2", "Last2", phones: ["415-555-0102"])
        other.organizations = [GoogleOrganization(name: "Other 2")]
        let rig = try ReviewRig.firstSync(SyncWorld(icloud: icloud, google: [withEmail, other]))
        defer { rig.cleanUp() }
        try await rig.syncOnce()
        let items = try rig.storedItems
        #expect(items.count == 2 && items.allSatisfy { $0.kind == .bothEdited })
        try mark(rig.base, ["I1", "I2"], marker)

        let report = try await rig.workflows.keepICloudForAll(items)
        #expect(report.applied.count == 2 && report.failed.isEmpty)
        #expect(try rig.state.baselines["I1"]?.photo == marker && rig.state.baselines["I2"]?.photo == marker)
        #expect(try rig.state.baselines["I2"]?.googleEtag == (try await rig.base.googlePerson("people/c2")).etag)
    }

    @Test("Review import: the new iCloud contact has no photo baseline yet")
    func reviewImport() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        _ = try await rig.world.google.createContact(SyncFixtures.person("Priya", "Patel", phones: ["415-555-0301"], note: "Met."))
        try await rig.syncOnce()
        let item = try #require(try rig.storedItems.first { $0.kind == .newInGoogle })
        let detail = try await rig.workflows.loadDetail(item)
        #expect(try await rig.workflows.importToICloud(detail) == .done(warnings: []))
        let created = try #require(try await rig.world.store.fetchAll().first { $0.givenName == "Priya" })
        #expect(try rig.state.baselines[created.sourceIdentifier] != nil && rig.state.baselines[created.sourceIdentifier]?.photo == nil)
    }

    @Test("Review restore: the restored contact is a new iCloud contact without a photo, so the old photo baseline is not carried over")
    func reviewRestore() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.store.delete(ids: ["I1"], backup: .forTesting())
        try await rig.world.editGoogle("people/c1", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Annie")] }
        try await rig.syncOnce()
        try mark(rig.base, ["I1"], marker)

        let detail = try await rig.detail("deletedInICloudEditedInGoogle|I1|people/c1")
        #expect(try await rig.workflows.restoreToICloud(detail) == .done(warnings: []))
        let restored = try #require(try await rig.world.store.fetchAll().first { $0.givenName == "First1" })
        #expect(try rig.state.baselines["I1"] == nil)
        #expect(try rig.state.baselines[restored.sourceIdentifier] != nil && rig.state.baselines[restored.sourceIdentifier]?.photo == nil)
    }

    @Test("Review put back in Google: the new Google contact has no photo, so the old photo baseline is not carried over")
    func reviewPutBack() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.google.deleteContact(resourceName: "people/c3")
        try await rig.syncOnce()
        try mark(rig.base, ["I3"], marker)

        let detail = try await rig.detail("deletedInGoogle|I3|people/c3")
        #expect(try await rig.workflows.putBackInGoogle(detail) == .done(warnings: []))
        let baseline = try #require(try rig.state.baselines["I3"])
        #expect(baseline.photo == nil, "photo sync looks at the pair afresh and copies iCloud's photo to the new contact")
    }

    // MARK: Dedupe merge

    @Test("Dedupe merge: the loser's baseline moves to the survivor with its photo baseline")
    func mergeMovesBaseline() async throws {
        func person(_ id: String) -> ContactRecord {
            ContactRecord(id: id, source: .icloud, sourceIdentifier: id, givenName: "Ann", familyName: "Lee", phones: [Labeled(label: "mobile", value: "415-555-0101")])
        }
        var survivor = person("a1")
        survivor.emails = [Labeled(label: "home", value: "ann@example.com")]
        let loser = person("a2")
        var google = loser
        google.id = "people/c1"
        google.source = .google
        google.sourceIdentifier = "people/c1"
        let synced = SyncBaseline(
            icloud: loser, google: google, googleEtag: "e1", icloudNoteHash: NoteHash.hash(""), googleNoteHash: NoteHash.hash(""),
            syncedAt: SyncFixtures.t0, photo: marker
        )

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-merge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InMemoryContactStore(records: [survivor, loser])
        let notes = InMemoryNotesStore()
        let links = InMemoryLinkStore()
        let state = InMemorySyncStateStore(SyncState(baselines: ["a2": synced], firstSyncApproved: true))
        try links.add([ImportedLink(icloudID: "a2", googleResourceName: "people/c1", origin: .matched)], at: SyncFixtures.t0)
        let backups = BackupCoordinator(makeSetup: {
            BackupSetup(writer: BackupWriter(store: store, notes: notes, baseDirectory: directory), containerID: "A")
        })
        let workflows = ContactWorkflows(
            store: store, google: nil, notes: notes, backups: backups, links: links, syncState: state, dismissals: InMemoryDismissalStore(),
            containerID: "A"
        )
        let draft = try #require(try await workflows.loadDuplicates().clusters.map(MergeDraft.init).first)
        #expect(draft.survivor.sourceIdentifier == "a1")

        let run = try await workflows.runMerge(draft)
        #expect(run.linksMoved == 1)
        let moved = try #require(try state.load().baselines["a1"])
        #expect(moved.photo == marker && moved.icloud.id == "a1")
    }

    // MARK: demo

    @Test("Demo data seeds baselines without a photo baseline: the demo's photos are looked at on the first run")
    func demoBaselines() throws {
        let demo = DemoData.make()
        let baselines = try demo.syncState.load().baselines
        #expect(!baselines.isEmpty && baselines.values.allSatisfy { $0.photo == nil })
    }
}
