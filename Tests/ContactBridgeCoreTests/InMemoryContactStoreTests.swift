import Foundation
import Testing
@testable import ContactBridgeCore

struct InMemoryContactStoreTests {
    private func record(_ id: String, _ given: String, phones: [String] = []) -> ContactRecord {
        ContactRecord(
            id: id, source: .icloud, sourceIdentifier: id, givenName: given, familyName: "Lee",
            phones: phones.map { Labeled(label: "mobile", value: $0) }
        )
    }

    @Test("Receipts are unique tokens")
    func receipts() {
        #expect(BackupReceipt.forTesting() != BackupReceipt.forTesting())
        let id = UUID()
        #expect(BackupReceipt.forTesting(id: id) == BackupReceipt.forTesting(id: id))
    }

    @Test("Authorization starts as configured and request grants or denies once")
    func authorization() async throws {
        let granting = InMemoryContactStore(authorization: .notDetermined, grantsAccess: true)
        #expect(await granting.authorizationStatus() == .notDetermined)
        #expect(try await granting.requestAccess() == .authorized)
        #expect(await granting.authorizationStatus() == .authorized)

        let denying = InMemoryContactStore(authorization: .notDetermined, grantsAccess: false)
        #expect(try await denying.requestAccess() == .denied)
        #expect(try await denying.requestAccess() == .denied)
    }

    @Test("Everything throws accessDenied without authorization")
    func unauthorized() async {
        let store = InMemoryContactStore(records: [record("a", "Ann")], authorization: .denied)
        await #expect(throws: ContactStoreError.accessDenied) { try await store.fetchAll() }
        await #expect(throws: ContactStoreError.accessDenied) { try await store.delete(ids: ["a"], backup: .forTesting()) }
        await #expect(throws: ContactStoreError.accessDenied) { try await store.exportVCard(ids: ["a"]) }
        await #expect(throws: ContactStoreError.accessDenied) {
            try await store.merge(survivor: record("a", "Ann"), absorbing: [], backup: .forTesting())
        }
    }

    @Test("fetchAll returns records in a stable order")
    func fetchAll() async throws {
        let store = InMemoryContactStore(records: [record("b", "Bob"), record("a", "Ann")])
        #expect(try await store.fetchAll().map(\.id) == ["b", "a"])
    }

    @Test("create assigns an iCloud identity and returns the stored record")
    func create() async throws {
        let store = InMemoryContactStore()
        let created = try await store.create(record("ignored", "Ann"), backup: .forTesting())
        #expect(created.source == .icloud)
        #expect(created.id == created.sourceIdentifier)
        #expect(created.id != "ignored")
        #expect(created.givenName == "Ann")
        #expect(try await store.fetchAll() == [created])
    }

    @Test("update finds the contact by sourceIdentifier like the adapter, and keeps identity")
    func update() async throws {
        let store = InMemoryContactStore(records: [record("a", "Ann")])
        var changed = record("a", "Annie", phones: ["+14155552671"])
        changed.id = "someOtherID"
        try await store.update(changed, backup: .forTesting())
        let stored = try await store.fetchAll()
        #expect(stored.map(\.givenName) == ["Annie"])
        #expect(stored[0].id == "a" && stored[0].sourceIdentifier == "a")

        var wrong = record("a", "Nope")
        wrong.sourceIdentifier = "zzz"
        await #expect(throws: ContactStoreError.notFound(["zzz"])) { try await store.update(wrong, backup: .forTesting()) }
    }

    @Test("delete is all-or-nothing")
    func delete() async throws {
        let store = InMemoryContactStore(records: [record("a", "Ann"), record("b", "Bob")])
        await #expect(throws: ContactStoreError.notFound(["nope"])) {
            try await store.delete(ids: ["a", "nope"], backup: .forTesting())
        }
        #expect(try await store.fetchAll().count == 2)
        try await store.delete(ids: ["a"], backup: .forTesting())
        #expect(try await store.fetchAll().map(\.id) == ["b"])
    }

    @Test("Every mutation is logged with its receipt")
    func mutationLog() async throws {
        let store = InMemoryContactStore(records: [record("a", "Ann"), record("b", "Bob")])
        let receipt = BackupReceipt.forTesting()
        let created = try await store.create(record("", "Cy"), backup: receipt)
        try await store.update(record("a", "Anna"), backup: receipt)
        try await store.delete(ids: ["b"], backup: receipt)
        let log = store.mutationLog
        #expect(log.map(\.kind) == [.create, .update, .delete])
        #expect(log.map(\.ids) == [[created.id], ["a"], ["b"]])
        #expect(log.allSatisfy { $0.receiptID == receipt.id })
    }

    private func countNotifications(of store: InMemoryContactStore, during work: () async throws -> Void) async throws -> Int {
        let collector = Task {
            var count = 0
            for await _ in store.changes() { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(50))
        try await work()
        try await Task.sleep(for: .milliseconds(100))
        collector.cancel()
        return await collector.value
    }

    @Test("Reads never notify; each mutation notifies once")
    func changes() async throws {
        let store = InMemoryContactStore(records: [record("a", "Ann"), record("b", "Bob")])
        let reads = try await countNotifications(of: store) {
            _ = try await store.fetchAll()
            _ = await store.authorizationStatus()
            _ = try await store.exportVCard(ids: ["a"])
            _ = try await store.requestAccess()
        }
        #expect(reads == 0)

        let one = try await countNotifications(of: store) {
            try await store.update(record("a", "Anna"), backup: .forTesting())
        }
        #expect(one == 1)
        let merged = try await countNotifications(of: store) {
            try await store.merge(survivor: record("a", "Anne"), absorbing: ["b"], backup: .forTesting())
        }
        #expect(merged == 1)
    }

    // MARK: merge

    @Test("merge updates the survivor and deletes the duplicates in one logged step")
    func merge() async throws {
        let store = InMemoryContactStore(records: [
            record("a", "Ann", phones: ["+14155552671"]), record("b", "Ann"), record("c", "Anne"), record("d", "Dee"),
        ])
        let receipt = BackupReceipt.forTesting()
        let survivor = record("a", "Ann", phones: ["+14155552671", "+12125553344"])
        try await store.merge(survivor: survivor, absorbing: ["b", "c"], backup: receipt)
        let stored = try await store.fetchAll()
        #expect(stored.map(\.id) == ["a", "d"])
        #expect(stored[0].phones.count == 2)
        #expect(store.mutationLog == [StoreMutation(kind: .merge, ids: ["a", "b", "c"], receiptID: receipt.id)])
    }

    @Test("merge is all-or-nothing and never deletes the survivor")
    func mergeGuards() async throws {
        let store = InMemoryContactStore(records: [record("a", "Ann"), record("b", "Bob")])
        await #expect(throws: ContactStoreError.notFound(["nope"])) {
            try await store.merge(survivor: record("a", "Changed"), absorbing: ["b", "nope"], backup: .forTesting())
        }
        await #expect(throws: ContactStoreError.notFound(["ghost"])) {
            try await store.merge(survivor: record("ghost", "G"), absorbing: ["b"], backup: .forTesting())
        }
        var stored = try await store.fetchAll()
        #expect(stored.map(\.givenName) == ["Ann", "Bob"])
        #expect(store.mutationLog.isEmpty)

        try await store.merge(survivor: record("a", "Ann2"), absorbing: ["a", "b"], backup: .forTesting())
        stored = try await store.fetchAll()
        #expect(stored.map(\.id) == ["a"])
        #expect(stored[0].givenName == "Ann2")
    }

    @Test("vCard export contains the requested contacts in the requested order and rejects unknown ids")
    func vcard() async throws {
        let store = InMemoryContactStore(records: [
            record("a", "Ann", phones: ["+14155552671"]), record("b", "Bob"), record("c", "Cy"),
        ])
        let text = String(decoding: try await store.exportVCard(ids: ["c", "a"]), as: UTF8.self)
        #expect(text.components(separatedBy: "BEGIN:VCARD").count == 3)
        #expect(text.contains("FN:Ann Lee"))
        #expect(text.contains("TEL;TYPE=mobile:+14155552671"))
        #expect(!text.contains("Bob"))
        let cy = try #require(text.range(of: "FN:Cy Lee"))
        let ann = try #require(text.range(of: "FN:Ann Lee"))
        #expect(cy.lowerBound < ann.lowerBound)
        await #expect(throws: ContactStoreError.notFound(["x"])) { try await store.exportVCard(ids: ["a", "x"]) }
    }
}
