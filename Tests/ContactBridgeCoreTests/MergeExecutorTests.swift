import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

struct MergeExecutorTests {
    /// Records every call together with how many store mutations had been logged at that moment.
    private final class FakeNotes: NotesStoring {
        struct Event: Equatable {
            var name: String
            var mutationsSoFar: Int
        }
        let store: InMemoryContactStore
        let notes: [String: String]
        let fetchError: (any Error)?
        let writeError: (any Error)?
        private let log = Mutex<[Event]>([])
        private let fetched = Mutex<[String]>([])
        private let written = Mutex<[(id: String, note: String?)]>([])

        init(store: InMemoryContactStore, notes: [String: String] = [:], fetchError: (any Error)? = nil, writeError: (any Error)? = nil) {
            self.store = store
            self.notes = notes
            self.fetchError = fetchError
            self.writeError = writeError
        }

        var events: [Event] { log.withLock { $0 } }
        var fetchedIDs: [String] { fetched.withLock { $0 } }
        var writes: [(id: String, note: String?)] { written.withLock { $0 } }

        func fetchNotes(ids: [String]) async throws -> [String: String] {
            log.withLock { $0.append(Event(name: "fetch", mutationsSoFar: store.mutationLog.count)) }
            fetched.withLock { $0 = ids }
            if let fetchError { throw fetchError }
            return notes.filter { ids.contains($0.key) }
        }

        func setNote(_ note: String?, forID id: String) async throws {
            log.withLock { $0.append(Event(name: "write", mutationsSoFar: store.mutationLog.count)) }
            written.withLock { $0.append((id, note)) }
            if let writeError { throw writeError }
        }
    }

    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private func record(_ id: String, _ given: String) -> ContactRecord {
        ContactRecord(id: id, source: .icloud, sourceIdentifier: id, givenName: given, familyName: "Lee")
    }

    private func store() -> InMemoryContactStore {
        InMemoryContactStore(records: [record("s", "Sam"), record("d1", "Sam"), record("d2", "Sam")])
    }

    private let receipt = BackupReceipt.forTesting(createdAt: Date())

    @Test("Notes are read before the merge, written after it, and the combined text goes to the survivor")
    func ordering() async throws {
        let store = store()
        let notes = FakeNotes(store: store, notes: ["s": "Mine", "d1": "One", "d2": "Two"])
        let outcome = try await MergeExecutor(store: store, notes: notes)
            .execute(survivor: record("s", "Sam"), absorbing: ["d1", "d2"], backup: receipt)

        #expect(outcome.notes == .written)
        #expect(notes.events == [.init(name: "fetch", mutationsSoFar: 0), .init(name: "write", mutationsSoFar: 1)])
        #expect(Set(notes.fetchedIDs) == ["s", "d1", "d2"])
        #expect(notes.writes.count == 1)
        #expect(notes.writes[0].id == "s")
        #expect(notes.writes[0].note == "Mine\n\nOne\n\nTwo")
        #expect(store.mutationLog.map(\.kind) == [.merge])
        #expect(try await store.fetchAll().map(\.id) == ["s"])
    }

    @Test("Duplicate ids and the survivor listed among them are read once and absorbed once")
    func dedupesIDs() async throws {
        let store = store()
        let notes = FakeNotes(store: store, notes: ["d1": "One"])
        _ = try await MergeExecutor(store: store, notes: notes)
            .execute(survivor: record("s", "Sam"), absorbing: ["d1", "s", "d1", "d2"], backup: receipt)
        #expect(notes.fetchedIDs.sorted() == ["d1", "d2", "s"])
        #expect(notes.writes.first?.note == "One")
    }

    @Test("When the duplicates add nothing, the merge runs and no note is written")
    func unchanged() async throws {
        let store = store()
        let notes = FakeNotes(store: store, notes: ["s": "Same", "d1": " same "])
        let outcome = try await MergeExecutor(store: store, notes: notes)
            .execute(survivor: record("s", "Sam"), absorbing: ["d1", "d2"], backup: receipt)
        #expect(outcome.notes == .unchanged)
        #expect(notes.writes.isEmpty)
        #expect(store.mutationLog.count == 1)
    }

    @Test("No notes anywhere means unchanged, not a write of nil")
    func noNotesAtAll() async throws {
        let store = store()
        let notes = FakeNotes(store: store)
        let outcome = try await MergeExecutor(store: store, notes: notes)
            .execute(survivor: record("s", "Sam"), absorbing: ["d1"], backup: receipt)
        #expect(outcome.notes == .unchanged)
        #expect(notes.writes.isEmpty)
    }

    @Test("Empty note text (found, no note) counts as no note: nothing is written, and a duplicate's note still carries over")
    func emptyTextIsNoNote() async throws {
        let store = store()
        let none = FakeNotes(store: store, notes: ["s": "", "d1": ""])
        let outcome = try await MergeExecutor(store: store, notes: none)
            .execute(survivor: record("s", "Sam"), absorbing: ["d1"], backup: receipt)
        #expect(outcome.notes == .unchanged && none.writes.isEmpty)

        let store2 = self.store()
        let carry = FakeNotes(store: store2, notes: ["s": "", "d1": "One"])
        let carried = try await MergeExecutor(store: store2, notes: carry)
            .execute(survivor: record("s", "Sam"), absorbing: ["d1"], backup: receipt)
        #expect(carried.notes == .written && carry.writes.map(\.note) == ["One"])
    }

    @Test("A failed note write is reported with the combined text; the merge stays done")
    func writeFails() async throws {
        let store = store()
        let notes = FakeNotes(store: store, notes: ["s": "Mine", "d1": "One"], writeError: Boom())
        let outcome = try await MergeExecutor(store: store, notes: notes)
            .execute(survivor: record("s", "Sam"), absorbing: ["d1"], backup: receipt)
        #expect(outcome.notes == .writeFailed(combined: "Mine\n\nOne", reason: "boom"))
        #expect(store.mutationLog.map(\.kind) == [.merge])
        #expect(try await store.fetchAll().map(\.id) == ["s", "d2"])
    }

    @Test("A merge failure means no note is written")
    func mergeThrows() async throws {
        let store = store()
        let notes = FakeNotes(store: store, notes: ["s": "Mine", "d1": "One"])
        await #expect(throws: ContactStoreError.notFound(["ghost"])) {
            try await MergeExecutor(store: store, notes: notes)
                .execute(survivor: record("s", "Sam"), absorbing: ["d1", "ghost"], backup: receipt)
        }
        #expect(notes.writes.isEmpty)
        #expect(store.mutationLog.isEmpty)
    }

    @Test("If the notes cannot be read, nothing is merged and the error is thrown")
    func fetchThrows() async throws {
        let store = store()
        let notes = FakeNotes(store: store, fetchError: NotesAccessError.notAuthorized)
        await #expect(throws: NotesAccessError.notAuthorized) {
            try await MergeExecutor(store: store, notes: notes)
                .execute(survivor: record("s", "Sam"), absorbing: ["d1"], backup: receipt)
        }
        #expect(store.mutationLog.isEmpty)
        #expect(notes.writes.isEmpty)
    }

    @Test("A stale receipt is refused before anything is read or changed")
    func staleReceipt() async throws {
        let store = store()
        let notes = FakeNotes(store: store, notes: ["d1": "One"])
        let stale = BackupReceipt.forTesting(createdAt: Date(timeIntervalSinceNow: -7200))
        await #expect(throws: MergeExecutor.Failure.staleBackup) {
            try await MergeExecutor(store: store, notes: notes)
                .execute(survivor: record("s", "Sam"), absorbing: ["d1"], backup: stale)
        }
        #expect(notes.events.isEmpty)
        #expect(store.mutationLog.isEmpty)
    }

    @Test("Without a notes store the merge still runs and the outcome says notes were skipped")
    func noNotesStore() async throws {
        let store = store()
        let outcome = try await MergeExecutor(store: store, notes: nil)
            .execute(survivor: record("s", "Sam"), absorbing: ["d1"], backup: receipt)
        #expect(outcome.notes == .skipped)
        #expect(store.mutationLog.map(\.kind) == [.merge])
    }
}
