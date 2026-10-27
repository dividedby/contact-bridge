import Foundation
import Testing
@testable import ContactBridgeCore

/// The demo has one contact for each photo case, so the whole flow can be tried with --demo.
struct DemoPhotoTests {
    private func rig(_ demo: DemoEnvironment, directory: URL) -> (engine: SyncEngine, workflows: ReviewWorkflows) {
        let store = demo.store, google = demo.google, notes = demo.notes, email = demo.accountEmail
        let backups = BackupCoordinator(makeSetup: {
            BackupSetup(writer: BackupWriter(store: store, google: google, notes: notes, baseDirectory: directory), containerID: "demo-icloud")
        })
        let support = SyncPhotoSupport(fetcher: FakeGooglePhotoFetcher(client: google), history: demo.photoHistory, sleep: { _ in })
        let engine = SyncEngine(
            environment: { .ready(SyncEnvironment(store: store, notes: notes, google: google, accountEmail: email, containerID: "demo-icloud")) },
            links: demo.links, state: demo.syncState, reviews: demo.reviews, journal: demo.journal, history: demo.history, backups: backups,
            photos: support
        )
        let workflows = ReviewWorkflows(
            store: store, google: google, notes: notes, backups: backups, links: demo.links, state: demo.syncState, reviews: demo.reviews,
            journal: demo.journal, history: demo.history, gate: WriteGate(), containerID: "demo-icloud", photos: support
        )
        return (engine, workflows)
    }

    private func approved(_ demo: DemoEnvironment, directory: URL) async -> (engine: SyncEngine, workflows: ReviewWorkflows) {
        let parts = rig(demo, directory: directory)
        await parts.engine.start()
        await parts.engine.refreshPreview()
        _ = await parts.engine.approveFirstSync()
        return parts
    }

    private func icloudPhoto(_ demo: DemoEnvironment, _ given: String) async throws -> Data? {
        let record = try #require(try await demo.store.fetchAll().first { $0.givenName == given })
        return try await demo.store.photoData(id: record.sourceIdentifier)
    }

    private func googlePhoto(_ demo: DemoEnvironment, _ given: String) async -> Data? {
        guard let name = await demo.google.allPeople.first(where: { $0.names?.first?.givenName == given })?.resourceName else { return nil }
        return await demo.google.contactPhotoBytes(for: name)
    }

    @Test("The demo seeds the photo setting on for profile photos, and one linked contact for each photo case")
    func seeded() throws {
        let demo = DemoData.make()
        let state = try demo.syncState.load()
        #expect(state.syncPhotos && state.useGoogleProfilePhotos)
        for given in ["Grace", "Alan", "Ada", "Edsger", "Margaret"] {
            let id = try #require(demo.links.load().links.keys.first { state.baselines[$0]?.icloud.givenName == given })
            #expect(state.baselines[id] != nil)
        }
    }

    @Test("Start syncing copies a photo each way, asks about the conflict and the removal, and fills the profile contact")
    func eachCase() async throws {
        let demo = DemoData.make()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-photos-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (engine, _) = await approved(demo, directory: directory)

        let toGoogle = await googlePhoto(demo, "Grace")
        let toICloud = try await icloudPhoto(demo, "Alan")
        #expect(toGoogle != nil && toICloud != nil)
        let profile = try await icloudPhoto(demo, "Margaret")
        let margaret = await demo.google.allPeople.first { $0.names?.first?.givenName == "Margaret" }
        #expect(profile != nil && margaret.flatMap { GooglePersonMapper.photos(of: $0).contact } == nil, "the profile photo is never written to Google")

        let items = await engine.current.reviewItems.filter { $0.kind == .photoConflict }
        #expect(items.map(\.name).sorted() == ["Ada Lovelace", "Edsger Dijkstra"])
        #expect(items.first { $0.name == "Ada Lovelace" }?.photoReason == .firstSightDiffers)
        #expect(items.first { $0.name == "Edsger Dijkstra" }?.photoReason == .removedInICloud)
        let run = try #require(await engine.current.lastRun)
        #expect(run.photosToGoogle == 1 && run.photosToICloud == 2)
        await engine.stop()
    }

    @Test("Each photo question of the demo can be decided, and the next run finds nothing left to ask")
    func decide() async throws {
        let demo = DemoData.make()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-photos-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (engine, workflows) = await approved(demo, directory: directory)
        let stored = try demo.reviews.load().filter { $0.kind == .photoConflict }
        try #require(stored.count == 2)

        for item in stored {
            let detail = try await workflows.loadDetail(item)
            let choice: PhotoChoice = item.photoReason == .removedInICloud ? .keepGoogle : .keepICloud
            #expect(try await workflows.applyPhoto(detail, choice: choice) == .done(warnings: []))
        }
        await engine.syncNow()
        let after = await engine.current
        #expect(!after.reviewItems.contains { $0.kind == .photoConflict })
        let edsger = try await icloudPhoto(demo, "Edsger")
        let ada = await googlePhoto(demo, "Ada")
        #expect(edsger != nil && ada != nil, "Edsger's photo came back to iCloud; Ada's iCloud photo went to Google")
        await engine.stop()
    }
}
