import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

struct WriteGateTests {
    private struct Boom: Error {}

    /// A gate-holder that stays inside until `release()`.
    private final class Holder: Sendable {
        private let continuation: AsyncStream<Void>.Continuation
        let task: Mutex<Task<Void, any Error>?> = Mutex(nil)

        /// Returns once the holder is inside the gate.
        static func holding(_ gate: WriteGate) async -> Holder {
            let holder = Holder(gate)
            for await _ in holder.entered { break }
            return holder
        }

        private let entered: AsyncStream<Void>

        private init(_ gate: WriteGate) {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
            self.continuation = continuation
            self.entered = entered
            task.withLock { $0 = Task { try await gate.withLock { enteredSignal.yield(); for await _ in stream { break } } } }
        }

        func release() async throws {
            continuation.yield(())
            try await task.withLock { $0 }?.value
        }
    }

    @Test("Bodies never overlap, however many callers there are")
    func exclusion() async throws {
        let gate = WriteGate()
        let active = Mutex((now: 0, peak: 0, total: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await gate.withLock {
                        active.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
                        for _ in 0..<5 { await Task.yield() }
                        active.withLock { $0.now -= 1; $0.total += 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        let result = active.withLock { $0 }
        #expect(result.peak == 1 && result.total == 20)
        #expect(await !gate.isLocked)
    }

    @Test("Callers are served in the order they arrived")
    func firstInFirstOut() async throws {
        let gate = WriteGate()
        let order = Mutex<[Int]>([])
        let holder = await Holder.holding(gate)
        var tasks: [Task<Void, any Error>] = []
        for index in 1...4 {
            tasks.append(Task { try await gate.withLock { order.withLock { $0.append(index) } } })
            await gate.waitUntilQueued(index)
        }
        try await holder.release()
        for task in tasks { try await task.value }
        #expect(order.withLock { $0 } == [1, 2, 3, 4])
    }

    @Test("A body that throws still releases the gate")
    func releasesOnThrow() async throws {
        let gate = WriteGate()
        await #expect(throws: Boom.self) { try await gate.withLock { throw Boom() } }
        #expect(try await gate.withLock { 7 } == 7)
    }

    @Test("A waiter that is cancelled leaves the queue; the ones behind it still get their turn")
    func cancelledWaiter() async throws {
        let gate = WriteGate()
        let ran = Mutex(false)
        let holder = await Holder.holding(gate)
        let cancelled = Task { try await gate.withLock { ran.withLock { $0 = true } } }
        await gate.waitUntilQueued(1)
        let behind = Task { try await gate.withLock { 42 } }
        await gate.waitUntilQueued(2)

        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await gate.waitingCount == 1)
        try await holder.release()
        #expect(try await behind.value == 42 && !ran.withLock { $0 })
        #expect(await !gate.isLocked)
    }

    @Test("A task that is already cancelled never takes the gate")
    func cancelledBeforeStart() async throws {
        let gate = WriteGate()
        let task = Task {
            try await Task.sleep(for: .seconds(60))
            try await gate.withLock {}
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await !gate.isLocked)
    }

    // MARK: workflows

    @Test("Clean up, Import and Merge wait for the gate: nothing is deleted while a sync run holds it")
    func workflowsWaitForTheGate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gate-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = [SyncFixtures.icloud("A", "Ann", "Lee", phones: ["415-555-0001"]), SyncFixtures.icloud("B", "Bob", "Stone", phones: ["415-555-0002"])]
        let store = InMemoryContactStore(records: records)
        let notes = InMemoryNotesStore()
        let backups = BackupCoordinator(makeWriter: { BackupWriter(store: store, notes: notes, baseDirectory: directory) })
        let gate = WriteGate()
        let workflows = ContactWorkflows(
            store: store, google: nil, notes: notes, backups: backups, links: InMemoryLinkStore(), gate: gate, dismissals: InMemoryDismissalStore()
        )

        let holder = await Holder.holding(gate)
        let deleting = Task { try await workflows.deleteContacts(ids: ["B"]) }
        await gate.waitUntilQueued(1)
        let during = try await store.fetchAll().count
        #expect(during == 2, "the delete is waiting, not done")

        try await holder.release()
        let run = try await deleting.value
        #expect(run.deletedCount == 1)
        #expect(try await store.fetchAll().map(\.sourceIdentifier) == ["A"])
        #expect(await !gate.isLocked)
    }
}

struct SyncProcessLockTests {
    private func lockURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lock-tests-\(UUID().uuidString)/Contact Bridge/sync.lock")
    }

    @Test("A second holder is refused while the first is alive, and gets in once it lets go")
    func exclusive() throws {
        let url = lockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let first = try SyncProcessLock.acquire(at: url)
        #expect(throws: SyncLockError.heldByAnotherInstance) { try SyncProcessLock.acquire(at: url) }
        first.release()
        first.release() // harmless twice
        let second = try SyncProcessLock.acquire(at: url)
        #expect(throws: SyncLockError.heldByAnotherInstance) { try SyncProcessLock.acquire(at: url) }
        second.release()
    }

    @Test("The lock is dropped when its holder goes away, as when a process dies")
    func droppedOnDeinit() throws {
        let url = lockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        do {
            let held = try SyncProcessLock.acquire(at: url)
            #expect(throws: SyncLockError.heldByAnotherInstance) { try SyncProcessLock.acquire(at: url) }
            withExtendedLifetime(held) {}
        }
        let again = try SyncProcessLock.acquire(at: url)
        again.release()
    }

    @Test("A lock file that cannot be created is reported, with a message that says syncing is off")
    func unavailable() {
        let url = URL(fileURLWithPath: "/dev/null/Contact Bridge/sync.lock")
        do {
            _ = try SyncProcessLock.acquire(at: url)
            Issue.record("should not be able to lock a path under /dev/null")
        } catch let error as SyncLockError {
            guard case .unavailable = error else {
                Issue.record("expected unavailable, got \(error)")
                return
            }
            #expect(error.localizedDescription.contains("syncing is off"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("The refusal message tells the user what to do")
    func message() {
        let text = SyncLockError.heldByAnotherInstance.localizedDescription
        #expect(text.contains("Another copy") && text.contains("Quit"))
    }
}
