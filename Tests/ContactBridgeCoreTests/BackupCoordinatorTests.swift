import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

struct BackupCoordinatorTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private final class Clock: Sendable {
        private let time = Mutex(1_800_000_000.0)
        func now() -> Date { Date(timeIntervalSince1970: time.withLock { $0 }) }
        func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
    }

    private func folders(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    @Test("A fresh receipt is reused; a stale one triggers a new backup")
    func reuseAndRefresh() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let store = InMemoryContactStore(records: [ContactRecord(id: "1", source: .icloud, sourceIdentifier: "1", givenName: "Ann")])
        let coordinator = BackupCoordinator(
            makeWriter: { BackupWriter(store: store, baseDirectory: directory, now: { clock.now() }) },
            maxAge: 3600, now: { clock.now() }
        )
        #expect(await coordinator.latest == nil)
        let first = try await coordinator.freshReceipt()
        clock.advance(600)
        let second = try await coordinator.freshReceipt()
        #expect(second == first)
        #expect(folders(directory).count == 1)

        clock.advance(4000)
        let third = try await coordinator.freshReceipt()
        #expect(third != first && third.isFresh(now: clock.now()))
        #expect(folders(directory).count == 2)
        #expect(await coordinator.latest == third)
    }

    @Test("backUpNow always takes a new backup")
    func backUpNowAlwaysBacksUp() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let store = InMemoryContactStore()
        let coordinator = BackupCoordinator(makeWriter: { BackupWriter(store: store, baseDirectory: directory, now: { clock.now() }) }, now: { clock.now() })
        let first = try await coordinator.backUpNow()
        clock.advance(5)
        let second = try await coordinator.backUpNow()
        #expect(first != second)
        #expect(folders(directory).count == 2)
    }

    @Test("Concurrent callers share one backup")
    func singleFlight() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let store = InMemoryContactStore()
        let coordinator = BackupCoordinator(makeWriter: { BackupWriter(store: store, baseDirectory: directory, now: { clock.now() }) }, now: { clock.now() })
        let receipts = try await withThrowingTaskGroup(of: BackupReceipt.self) { group in
            for _ in 0..<5 { group.addTask { try await coordinator.freshReceipt() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(receipts.map(\.id)).count == 1)
        #expect(folders(directory).count == 1)
    }

    @Test("A failed backup throws, leaves no receipt, and the next call tries again")
    func failure() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let denied = InMemoryContactStore(authorization: .denied)
        let coordinator = BackupCoordinator(makeWriter: { BackupWriter(store: denied, baseDirectory: directory) })
        await #expect(throws: ContactStoreError.accessDenied) { _ = try await coordinator.freshReceipt() }
        #expect(await coordinator.latest == nil)
        await #expect(throws: ContactStoreError.accessDenied) { _ = try await coordinator.freshReceipt() }
    }

    // MARK: what a cached receipt covers

    /// A coordinator whose writer reflects switchable state, like the app's.
    private final class World: Sendable {
        let container = Mutex<String?>("A")
        let notes = Mutex(false)
        let google = Mutex(false)
    }

    private func coordinator(_ world: World, _ directory: URL, _ clock: Clock) -> BackupCoordinator {
        let store = InMemoryContactStore(records: [ContactRecord(id: "1", source: .icloud, sourceIdentifier: "1", givenName: "Ann")])
        let notes = InMemoryNotesStore(notes: ["1": "n"])
        let google = FakeGoogleClient()
        return BackupCoordinator(makeSetup: {
            BackupSetup(
                writer: BackupWriter(
                    store: store, google: world.google.withLock { $0 } ? google : nil, notes: world.notes.withLock { $0 } ? notes : nil,
                    baseDirectory: directory, now: { clock.now() }
                ),
                containerID: world.container.withLock { $0 }
            )
        }, now: { clock.now() })
    }

    @Test("A receipt for one container is never handed to another")
    func containerSwitch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(), world = World()
        let backups = coordinator(world, directory, clock)
        let first = try await backups.freshReceipt(requiring: BackupRequirement(containerID: "A"))
        #expect(try await backups.freshReceipt(requiring: BackupRequirement(containerID: "A")) == first)

        clock.advance(5)
        world.container.withLock { $0 = "B" }
        let second = try await backups.freshReceipt(requiring: BackupRequirement(containerID: "B"))
        #expect(second != first)
        #expect(folders(directory).count == 2)
    }

    @Test("A backup without notes is not reused once a merge needs notes; one with notes serves both")
    func notesUpgrade() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(), world = World()
        let backups = coordinator(world, directory, clock)
        let plain = try await backups.freshReceipt(requiring: BackupRequirement(containerID: "A"))
        #expect(!plain.manifest.notesIncluded)

        clock.advance(5)
        world.notes.withLock { $0 = true }
        let withNotes = try await backups.freshReceipt(requiring: BackupRequirement(containerID: "A", needsNotes: true))
        #expect(withNotes != plain && withNotes.manifest.notesIncluded)
        #expect(try await backups.freshReceipt(requiring: BackupRequirement(containerID: "A")) == withNotes)
        #expect(try await backups.freshReceipt(requiring: BackupRequirement(containerID: "A", needsNotes: true)) == withNotes)
    }

    @Test("An import needs a backup that included Google")
    func googleRequirement() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(), world = World()
        let backups = coordinator(world, directory, clock)
        let plain = try await backups.freshReceipt(requiring: BackupRequirement(containerID: "A"))
        clock.advance(5)
        world.google.withLock { $0 = true }
        let withGoogle = try await backups.freshReceipt(requiring: BackupRequirement(containerID: "A", needsGoogle: true))
        #expect(withGoogle != plain && withGoogle.manifest.sources.contains("google"))
    }

    @Test("If a new backup still cannot meet the requirement, it throws instead of handing back a useless receipt")
    func requirementNotMet() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(), world = World()
        let backups = coordinator(world, directory, clock)
        await #expect(throws: BackupCoordinatorError.self) {
            _ = try await backups.freshReceipt(requiring: BackupRequirement(containerID: "A", needsNotes: true))
        }
        await #expect(throws: BackupCoordinatorError.self) {
            _ = try await backups.freshReceipt(requiring: BackupRequirement(containerID: "A", needsGoogle: true))
        }
        world.container.withLock { $0 = "A" }
        await #expect(throws: BackupCoordinatorError.self) {
            _ = try await backups.freshReceipt(requiring: BackupRequirement(containerID: "other"))
        }
    }

    @Test("invalidate forgets the cached receipt")
    func invalidate() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(), world = World()
        let backups = coordinator(world, directory, clock)
        let first = try await backups.freshReceipt(requiring: BackupRequirement(containerID: "A"))
        await backups.invalidate()
        #expect(await backups.latest == nil)
        clock.advance(5)
        #expect(try await backups.freshReceipt(requiring: BackupRequirement(containerID: "A")) != first)
    }
}
