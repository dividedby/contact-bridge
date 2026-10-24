import Foundation
import Testing
@testable import ContactBridgeCore

struct SyncStateStoreTests {
    private let t0 = SyncFixtures.t0

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sync-state-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sampleState() -> SyncState {
        let record = SyncFixtures.icloud("I1", "Ann", "Lee", phones: ["415-555-0100"])
        return SyncState(
            baselines: ["I1": SyncBaseline(icloud: record, google: record, googleEtag: "e1", icloudNoteHash: NoteHash.hash("n"), syncedAt: t0)],
            googleSyncToken: "tok", fieldsVersion: "fv", icloudChangeToken: Data([1, 2]), icloudContainerID: "c1", lastNotesReadAt: t0,
            googleAccount: "me@example.com", ignoredGoogle: ["people/c9"], firstSyncApproved: true, pause: .needsConfirmation(summary: "x")
        )
    }

    @Test("A missing file loads as a fresh state and loading does not create it")
    func missingFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync-state.json")
        #expect(try SyncStateStore(url: url).load() == SyncState())
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("State survives a reload, including the new fields, in a versioned file next to links.json")
    func roundTrip() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync-state.json")
        try SyncStateStore(url: url).save(sampleState())
        #expect(try SyncStateStore(url: url).load() == sampleState())
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(SyncStateStore.defaultURL.lastPathComponent == "sync-state.json")
        #expect(SyncStateStore.defaultURL.deletingLastPathComponent() == LinkStore.defaultURL.deletingLastPathComponent())
    }

    @Test("A file written before the container and notes-read fields existed still loads")
    func olderFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync-state.json")
        try Data(#"{"version":1,"baselines":{},"ignoredGoogle":[],"firstSyncApproved":true}"#.utf8).write(to: url)
        let state = try SyncStateStore(url: url).load()
        #expect(state.firstSyncApproved && state.icloudContainerID == nil && state.lastNotesReadAt == nil)
    }

    @Test("update is one read-modify-write; a throwing change or an unchanged state writes nothing")
    func update() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync-state.json")
        let store = SyncStateStore(url: url)
        try store.update { _ in }
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let stored = try store.update { $0.ignoredGoogle.insert("people/c1") }
        #expect(stored.ignoredGoogle == ["people/c1"])
        struct Boom: Error {}
        #expect(throws: Boom.self) { try store.update { _ in throw Boom() } }
        #expect(try store.load().ignoredGoogle == ["people/c1"])
    }

    @Test("An unknown version or unreadable file is left alone and every operation refuses it")
    func refusesBadFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync-state.json")
        let store = SyncStateStore(url: url)

        try Data(#"{"version":2}"#.utf8).write(to: url)
        #expect(throws: SyncStateStoreError.unsupportedVersion(2)) { try store.load() }
        #expect(throws: SyncStateStoreError.unsupportedVersion(2)) { try store.save(SyncState()) }
        #expect(throws: SyncStateStoreError.unsupportedVersion(2)) { try store.update { $0.firstSyncApproved = true } }
        #expect(try Data(contentsOf: url) == Data(#"{"version":2}"#.utf8))

        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(SyncStateStoreError.unsupportedVersion(2).errorDescription?.contains("newer version") == true)
    }

    @Test("The in-memory store behaves the same")
    func inMemory() throws {
        let store = InMemorySyncStateStore()
        #expect(try store.load() == SyncState())
        try store.save(sampleState())
        let updated = try store.update { $0.firstSyncApproved = false }
        #expect(!updated.firstSyncApproved)
        #expect(try store.load() == updated)
        struct Boom: Error {}
        #expect(throws: Boom.self) { try store.update { $0.googleAccount = "x"; throw Boom() } }
        #expect(try store.load().googleAccount == "me@example.com")
    }
}
