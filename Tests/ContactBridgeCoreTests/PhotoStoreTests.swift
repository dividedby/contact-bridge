import Foundation
import Testing
@testable import ContactBridgeCore

/// The photo half of `ContactStoring`, through the in-memory store (the CNContactStore adapter needs the real Contacts
/// database, so it is not exercised here).
struct PhotoStoreTests {
    private let red = PhotoTestImages.jpeg(PhotoTestImages.solid(.red))
    private let blue = PhotoTestImages.jpeg(PhotoTestImages.solid(.blue))

    private func record(_ id: String, _ given: String) -> ContactRecord {
        ContactRecord(id: id, source: .icloud, sourceIdentifier: id, givenName: given, familyName: "Lee")
    }

    private func store(photos: [String: Data] = [:], authorization: ContactAuthorization = .authorized) -> InMemoryContactStore {
        InMemoryContactStore(records: [record("a", "Ann"), record("b", "Bob"), record("c", "Cy")], photos: photos, authorization: authorization)
    }

    // MARK: signatures

    @Test("A signature says whether a contact has a photo and carries a hash that changes with the photo")
    func signatures() async throws {
        let store = store(photos: ["a": red, "b": blue])
        let signatures = try await store.photoSignatures(ids: ["a", "b", "c"])
        #expect(signatures["a"]?.hasPhoto == true && signatures["b"]?.hasPhoto == true && signatures["c"] == PhotoSignature(hasPhoto: false))
        #expect(signatures["a"]?.thumbnailHash == PhotoHash.sha256Hex(red) && signatures["a"]?.thumbnailHash != signatures["b"]?.thumbnailHash)
        #expect(signatures["a"]?.thumbnailHash?.count == 64)

        try await store.setPhoto(id: "c", data: red, backup: .forTesting())
        #expect(try await store.photoSignatures(ids: ["c"])["c"]?.thumbnailHash == signatures["a"]?.thumbnailHash, "same picture, same hash")
    }

    @Test("Ids the store does not have are left out, duplicates are fine, and no ids is no work")
    func signatureIDs() async throws {
        let store = store(photos: ["a": red])
        let signatures = try await store.photoSignatures(ids: ["a", "a", "ghost"])
        #expect(Set(signatures.keys) == ["a"])
        #expect(try await store.photoSignatures(ids: []).isEmpty)
    }

    @Test("Many ids at once are read in one call")
    func manyIDs() async throws {
        let records = (0..<500).map { record("id-\($0)", "Person \($0)") }
        let photos = Dictionary(uniqueKeysWithValues: records.prefix(250).map { ($0.sourceIdentifier, red) })
        let store = InMemoryContactStore(records: records, photos: photos)
        let signatures = try await store.photoSignatures(ids: records.map(\.sourceIdentifier))
        #expect(signatures.count == 500 && signatures.values.filter(\.hasPhoto).count == 250)
        #expect(store.photoReads.signatures == 1 && store.photoReads.data == 0, "no full-size picture was read")
    }

    // MARK: data

    @Test("photoData returns the bytes, nothing for a contact with no photo, and notFound for a missing contact")
    func data() async throws {
        let store = store(photos: ["a": red])
        #expect(try await store.photoData(id: "a") == red)
        #expect(try await store.photoData(id: "b") == nil)
        await #expect(throws: ContactStoreError.notFound(["ghost"])) { try await store.photoData(id: "ghost") }
        #expect(store.photoReads.data == 2, "only reads that found a contact count")
    }

    // MARK: writes

    @Test("setPhoto sets, replaces and removes a photo; each change is logged with its receipt, moves the change token and notifies once")
    func setPhoto() async throws {
        let store = store()
        let receipt = BackupReceipt.forTesting()
        let tokens = [try await store.changeToken()]

        try await store.setPhoto(id: "a", data: red, backup: receipt)
        #expect(try await store.photoData(id: "a") == red)
        let afterSet = try await store.changeToken()
        #expect(afterSet != tokens[0])

        try await store.setPhoto(id: "a", data: blue, backup: receipt)
        let afterReplace = try await store.changeToken()
        #expect(try await store.photoData(id: "a") == blue)
        #expect(afterReplace != afterSet)

        try await store.setPhoto(id: "a", data: nil, backup: receipt)
        #expect(try await store.photoData(id: "a") == nil)
        #expect(try await store.photoSignatures(ids: ["a"])["a"] == PhotoSignature(hasPhoto: false))
        #expect(store.mutationLog == (0..<3).map { _ in StoreMutation(kind: .photo, ids: ["a"], receiptID: receipt.id) })
    }

    @Test("A photo write notifies subscribers once, and reads do not")
    func notifications() async throws {
        let store = store(photos: ["a": red])
        let collector = Task {
            var count = 0
            for await _ in store.changes() { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await store.photoSignatures(ids: ["a"])
        _ = try await store.photoData(id: "a")
        try await store.setPhoto(id: "b", data: blue, backup: .forTesting())
        try await Task.sleep(for: .milliseconds(100))
        collector.cancel()
        #expect(await collector.value == 1)
    }

    @Test("A write to a contact that is not there changes and logs nothing")
    func setPhotoMissing() async throws {
        let store = store()
        let token = try await store.changeToken()
        await #expect(throws: ContactStoreError.notFound(["ghost"])) { try await store.setPhoto(id: "ghost", data: red, backup: .forTesting()) }
        let after = try await store.changeToken()
        #expect(store.mutationLog.isEmpty && after == token)
    }

    @Test("Without authorization every photo call throws accessDenied")
    func unauthorized() async {
        let store = store(photos: ["a": red], authorization: .denied)
        await #expect(throws: ContactStoreError.accessDenied) { try await store.photoSignatures(ids: ["a"]) }
        await #expect(throws: ContactStoreError.accessDenied) { try await store.photoData(id: "a") }
        await #expect(throws: ContactStoreError.accessDenied) { try await store.setPhoto(id: "a", data: nil, backup: .forTesting()) }
        #expect(store.mutationLog.isEmpty)
    }

    // MARK: other store operations

    @Test("Editing a contact's fields leaves its photo alone")
    func updateKeepsPhoto() async throws {
        let store = store(photos: ["a": red])
        try await store.update(record("a", "Anna"), backup: .forTesting())
        #expect(try await store.photoData(id: "a") == red)
    }

    @Test("A deleted contact's photo goes with it")
    func deleteDropsPhoto() async throws {
        let store = store(photos: ["a": red, "b": blue])
        try await store.delete(ids: ["a"], backup: .forTesting())
        #expect(Set(try await store.photoSignatures(ids: ["a", "b"]).keys) == ["b"])
        await #expect(throws: ContactStoreError.notFound(["a"])) { try await store.photoData(id: "a") }
    }

    @Test("Merging keeps the survivor's own photo, or takes the first duplicate's if it has none, and the duplicates' photos go")
    func mergePhotos() async throws {
        let own = store(photos: ["a": red, "b": blue])
        try await own.merge(survivor: record("a", "Ann"), absorbing: ["b"], backup: .forTesting())
        #expect(try await own.photoData(id: "a") == red)
        #expect(try await own.photoSignatures(ids: ["b"]).isEmpty)

        let inherits = store(photos: ["b": blue, "c": red])
        try await inherits.merge(survivor: record("a", "Ann"), absorbing: ["b", "c"], backup: .forTesting())
        #expect(try await inherits.photoData(id: "a") == blue)

        let nobody = store()
        try await nobody.merge(survivor: record("a", "Ann"), absorbing: ["b"], backup: .forTesting())
        #expect(try await nobody.photoData(id: "a") == nil)
    }

    @Test("A contact created through the store starts without a photo")
    func createdHasNone() async throws {
        let store = store()
        let created = try await store.create(record("", "New"), backup: .forTesting())
        #expect(try await store.photoSignatures(ids: [created.sourceIdentifier])[created.sourceIdentifier] == PhotoSignature(hasPhoto: false))
    }

    // MARK: defaults

    /// A store that implements only what the protocol requires, as a test double would.
    private struct BareStore: ContactStoring {
        func authorizationStatus() async -> ContactAuthorization { .authorized }
        func requestAccess() async throws -> ContactAuthorization { .authorized }
        func fetchAll() async throws -> [ContactRecord] { [] }
        func create(_ record: ContactRecord, backup: BackupReceipt) async throws -> ContactRecord { record }
        func update(_ record: ContactRecord, backup: BackupReceipt) async throws {}
        func merge(survivor: ContactRecord, absorbing ids: [String], backup: BackupReceipt) async throws {}
        func delete(ids: [String], backup: BackupReceipt) async throws {}
        func exportVCard(ids: [String]) async throws -> Data { Data() }
        func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    }

    @Test("A store without photo support reports no photos and refuses to write one")
    func defaults() async throws {
        let bare = BareStore()
        #expect(try await bare.photoSignatures(ids: ["a"]).isEmpty)
        #expect(try await bare.photoData(id: "a") == nil)
        await #expect(throws: ContactStoreError.photosUnsupported) { try await bare.setPhoto(id: "a", data: nil, backup: .forTesting()) }
        #expect(ContactStoreError.photosUnsupported.localizedDescription.contains("photos"))
    }
}
