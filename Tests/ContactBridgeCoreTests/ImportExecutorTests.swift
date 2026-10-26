import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

struct ImportExecutorTests {
    private let receipt = BackupReceipt.forTesting(createdAt: Date())

    private func candidate(
        _ resourceName: String, _ given: String, source: ContactSource = .google, selected: Bool = true
    ) -> ImportCandidate {
        ImportCandidate(
            record: ContactRecord(
                id: resourceName, source: source, sourceIdentifier: resourceName, givenName: given, familyName: "Test",
                phones: [Labeled(label: "mobile", value: "415-555-0100")], emails: [Labeled(label: "home", value: "\(given)@example.com")]
            ),
            isSelected: selected
        )
    }

    /// Delegates to an in-memory store, but throws on the n-th create (1-based).
    private final class FlakyStore: ContactStoring {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "disk full" }
        }
        let base: InMemoryContactStore
        let failingCreate: Int
        private let creates = Mutex(0)

        init(base: InMemoryContactStore, failingCreate: Int) {
            self.base = base
            self.failingCreate = failingCreate
        }

        func authorizationStatus() async -> ContactAuthorization { await base.authorizationStatus() }
        func requestAccess() async throws -> ContactAuthorization { try await base.requestAccess() }
        func fetchAll() async throws -> [ContactRecord] { try await base.fetchAll() }
        func create(_ record: ContactRecord, backup: BackupReceipt) async throws -> ContactRecord {
            let number = creates.withLock { count -> Int in
                count += 1
                return count
            }
            if number == failingCreate { throw Boom() }
            return try await base.create(record, backup: backup)
        }
        func update(_ record: ContactRecord, backup: BackupReceipt) async throws { try await base.update(record, backup: backup) }
        func merge(survivor: ContactRecord, absorbing ids: [String], backup: BackupReceipt) async throws {
            try await base.merge(survivor: survivor, absorbing: ids, backup: backup)
        }
        func delete(ids: [String], backup: BackupReceipt) async throws { try await base.delete(ids: ids, backup: backup) }
        func exportVCard(ids: [String]) async throws -> Data { try await base.exportVCard(ids: ids) }
        func changes() -> AsyncStream<Void> { base.changes() }
    }

    private struct BrokenLinks: LinkStoring {
        func load() throws -> LinkTable { LinkTable() }
        func add(_ links: [ImportedLink], at date: Date) throws { throw LinkStoreError.unreadable("locked") }
        func remove(icloudIDs: [String]) throws {}
    }

    @Test("A stale receipt is refused before anything is created")
    func staleReceipt() async throws {
        let store = InMemoryContactStore()
        let old = BackupReceipt.forTesting(createdAt: Date(timeIntervalSinceNow: -7200))
        let executor = ImportExecutor(store: store, receipt: old)
        await #expect(throws: ImportExecutor.Failure.staleBackup) { _ = try await executor.execute([candidate("people/c1", "Ann")]) }
        #expect(store.mutationLog.isEmpty)
    }

    @Test("Every candidate is created, in order, under the receipt")
    func createsAll() async throws {
        let store = InMemoryContactStore()
        let result = try await ImportExecutor(store: store, receipt: receipt)
            .execute([candidate("people/c1", "Ann"), candidate("people/c2", "Bob")])
        #expect(result.isComplete && result.stopped == nil && result.notAttempted.isEmpty)
        #expect(result.created.map(\.candidateID) == ["people/c1", "people/c2"])
        #expect(try await store.fetchAll().map(\.givenName) == ["Ann", "Bob"])
        #expect(store.mutationLog.map(\.kind) == [.create, .create])
        #expect(store.mutationLog.allSatisfy { $0.receiptID == receipt.id })
        let first = try #require(result.created.first)
        #expect(first.record.source == .icloud && first.record.id == "mem-1")
    }

    @Test("Contacts created from a connection are linked to its resource name; other contacts are not")
    func linksOnlyConnections() async throws {
        let store = InMemoryContactStore()
        let links = InMemoryLinkStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try await ImportExecutor(store: store, receipt: .forTesting(createdAt: now), links: links)
            .execute([candidate("people/c1", "Ann"), candidate("otherContacts/c7", "Cara", source: .googleOther)], now: now)
        #expect(result.created.count == 2)
        #expect(result.links == [ImportedLink(icloudID: "mem-1", googleResourceName: "people/c1", displayName: "Ann Test")])
        let table = try links.load()
        #expect(table.links == ["mem-1": LinkEntry(googleResourceName: "people/c1", linkedAt: now)])
        #expect(table.links["mem-1"]?.displayName == "Ann Test", "the name is kept so a screen can say who the link was for after the contact is gone")
        #expect(result.linkSaveError == nil)
    }

    @Test("It stops at the first error and reports what was created and what was never tried")
    func stopsOnFirstError() async throws {
        let base = InMemoryContactStore()
        let links = InMemoryLinkStore()
        let store = FlakyStore(base: base, failingCreate: 2)
        let result = try await ImportExecutor(store: store, receipt: receipt, links: links)
            .execute([candidate("people/c1", "Ann"), candidate("people/c2", "Bob"), candidate("people/c3", "Cy")])
        #expect(!result.isComplete)
        #expect(result.created.map(\.candidateID) == ["people/c1"])
        #expect(result.stopped == .failed(candidateID: "people/c2", reason: "disk full"))
        #expect(result.notAttempted == ["people/c3"])
        #expect(try await base.fetchAll().map(\.givenName) == ["Ann"])
        // What was created before the error is still linked.
        #expect(try links.load().links.values.map(\.googleResourceName) == ["people/c1"])
    }

    @Test("A denied Contacts permission fails on the first record with nothing created")
    func accessDenied() async throws {
        let store = InMemoryContactStore(authorization: .denied)
        let result = try await ImportExecutor(store: store, receipt: receipt)
            .execute([candidate("people/c1", "Ann"), candidate("people/c2", "Bob")])
        #expect(result.created.isEmpty)
        guard case .failed(let id, let reason) = result.stopped else {
            Issue.record("expected a failure")
            return
        }
        #expect(id == "people/c1" && !reason.isEmpty)
        #expect(result.notAttempted == ["people/c2"])
    }

    @Test("A link file that cannot be written does not undo the import; the links are still returned")
    func linkSaveFailure() async throws {
        let store = InMemoryContactStore()
        let result = try await ImportExecutor(store: store, receipt: receipt, links: BrokenLinks()).execute([candidate("people/c1", "Ann")])
        #expect(result.isComplete && result.created.count == 1)
        #expect(result.links.count == 1)
        #expect(result.linkSaveError?.isEmpty == false)
        #expect(try await store.fetchAll().count == 1)
    }

    @Test("Nothing selected is a no-op that touches neither store")
    func emptySelection() async throws {
        let store = InMemoryContactStore()
        let links = InMemoryLinkStore()
        let result = try await ImportExecutor(store: store, receipt: receipt, links: links).execute([])
        #expect(result == ImportResult())
        #expect(store.mutationLog.isEmpty)
        #expect(try links.load().links.isEmpty)
    }

    @Test("Only the selected candidates are created when given a whole plan list")
    func skipsUnselected() async throws {
        let store = InMemoryContactStore()
        let result = try await ImportExecutor(store: store, receipt: receipt)
            .execute([candidate("people/c1", "Ann"), candidate("people/c2", "Bob", selected: false)])
        #expect(result.created.map(\.candidateID) == ["people/c1"])
    }

    @Test("A cancelled task stops between records and says so")
    func cancellation() async throws {
        let store = InMemoryContactStore()
        let executor = ImportExecutor(store: store, receipt: receipt)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.execute([candidate("people/c1", "Ann"), candidate("people/c2", "Bob")])
        }
        let result = try await task.value
        #expect(result.stopped == .cancelled)
        #expect(result.created.isEmpty && result.notAttempted == ["people/c1", "people/c2"])
    }
}
