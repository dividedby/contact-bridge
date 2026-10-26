import Foundation
import Synchronization

public struct StoreMutation: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case create
        case update
        case delete
        case merge
        /// A photo set or removed (`ids` holds the one contact).
        case photo
    }

    public var kind: Kind
    public var ids: [String]
    public var receiptID: UUID
}

/// Fake store for tests and previews. Behaves like the real adapter's contract: access gating, lookups by
/// `sourceIdentifier`, all-or-nothing deletes and merges, identity assigned on create, change notifications on mutation only.
public final class InMemoryContactStore: ContactStoring {
    private struct State {
        var records: [ContactRecord]
        /// Photo bytes by contact identifier.
        var photos: [String: Data]
        var authorization: ContactAuthorization
        var nextID = 1
        /// Bumped by every mutation; the change token.
        var version = 0
        var containerID: String?
        var log: [StoreMutation] = []
        var signatureReads = 0
        var dataReads = 0
        /// Photo saves report success but leave no photo, like a save iCloud did not keep.
        var dropsPhotoWrites = false
        var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    private let state: Mutex<State>
    private let grantsAccess: Bool

    public init(
        records: [ContactRecord] = [],
        photos: [String: Data] = [:],
        authorization: ContactAuthorization = .authorized,
        grantsAccess: Bool = true,
        containerID: String? = "mem-container"
    ) {
        state = Mutex(State(records: records, photos: photos, authorization: authorization, containerID: containerID))
        self.grantsAccess = grantsAccess
    }

    /// Every create/update/delete so far, with the receipt that authorized it.
    public var mutationLog: [StoreMutation] { state.withLock { $0.log } }

    /// How many `photoSignatures` calls and `photoData` calls have been made: the reads a scan that found nothing new avoids.
    public var photoReads: (signatures: Int, data: Int) { state.withLock { ($0.signatureReads, $0.dataReads) } }

    /// Simulates the user switching to another account's container.
    public func setContainerID(_ id: String?) { state.withLock { $0.containerID = id } }

    /// Simulates photo saves that report success but do not stay.
    public func setDropsPhotoWrites(_ drops: Bool) { state.withLock { $0.dropsPhotoWrites = drops } }

    public func authorizationStatus() async -> ContactAuthorization {
        state.withLock { $0.authorization }
    }

    public func requestAccess() async throws -> ContactAuthorization {
        state.withLock { state in
            if state.authorization == .notDetermined { state.authorization = grantsAccess ? .authorized : .denied }
            return state.authorization
        }
    }

    public func fetchAll() async throws -> [ContactRecord] {
        try state.withLock { state in
            try Self.requireAccess(state)
            return state.records
        }
    }

    public func create(_ record: ContactRecord, backup: BackupReceipt) async throws -> ContactRecord {
        let created: ContactRecord = try state.withLock { state in
            try Self.requireAccess(state)
            var stored = record
            stored.id = "mem-\(state.nextID)"
            stored.sourceIdentifier = stored.id
            stored.source = .icloud
            state.nextID += 1
            state.records.append(stored)
            state.version += 1
            state.log.append(StoreMutation(kind: .create, ids: [stored.id], receiptID: backup.id))
            return stored
        }
        notify()
        return created
    }

    public func update(_ record: ContactRecord, backup: BackupReceipt) async throws {
        try state.withLock { state in
            try Self.requireAccess(state)
            guard let index = state.records.firstIndex(where: { $0.sourceIdentifier == record.sourceIdentifier }) else {
                throw ContactStoreError.notFound([record.sourceIdentifier])
            }
            var stored = record
            stored.id = state.records[index].id
            stored.source = state.records[index].source
            stored.sourceIdentifier = state.records[index].sourceIdentifier
            state.records[index] = stored
            state.version += 1
            state.log.append(StoreMutation(kind: .update, ids: [stored.id], receiptID: backup.id))
        }
        notify()
    }

    public func delete(ids: [String], backup: BackupReceipt) async throws {
        try state.withLock { state in
            try Self.requireAccess(state)
            let existing = Set(state.records.map(\.sourceIdentifier))
            let missing = ids.filter { !existing.contains($0) }
            guard missing.isEmpty else { throw ContactStoreError.notFound(missing) }
            let doomed = Set(ids)
            state.records.removeAll { doomed.contains($0.sourceIdentifier) }
            for id in ids { state.photos[id] = nil }
            state.version += 1
            state.log.append(StoreMutation(kind: .delete, ids: ids, receiptID: backup.id))
        }
        notify()
    }

    public func merge(survivor: ContactRecord, absorbing ids: [String], backup: BackupReceipt) async throws {
        try state.withLock { state in
            try Self.requireAccess(state)
            guard let index = state.records.firstIndex(where: { $0.sourceIdentifier == survivor.sourceIdentifier }) else {
                throw ContactStoreError.notFound([survivor.sourceIdentifier])
            }
            var seen: Set<String> = [survivor.sourceIdentifier]
            let doomed = ids.filter { seen.insert($0).inserted }
            let existing = Set(state.records.map(\.sourceIdentifier))
            let missing = doomed.filter { !existing.contains($0) }
            guard missing.isEmpty else { throw ContactStoreError.notFound(missing) }

            var stored = survivor
            stored.id = state.records[index].id
            stored.source = state.records[index].source
            stored.sourceIdentifier = state.records[index].sourceIdentifier
            state.records[index] = stored
            let gone = Set(doomed)
            state.records.removeAll { gone.contains($0.sourceIdentifier) }
            // Like the real merge: the survivor keeps its own photo, else takes the first duplicate's.
            if state.photos[survivor.sourceIdentifier] == nil {
                for id in doomed {
                    if let photo = state.photos[id] {
                        state.photos[survivor.sourceIdentifier] = photo
                        break
                    }
                }
            }
            for id in doomed { state.photos[id] = nil }
            state.version += 1
            state.log.append(StoreMutation(kind: .merge, ids: [stored.sourceIdentifier] + doomed, receiptID: backup.id))
        }
        notify()
    }

    public func photoSignatures(ids: [String]) async throws -> [String: PhotoSignature] {
        try state.withLock { state in
            try Self.requireAccess(state)
            state.signatureReads += 1
            let existing = Set(state.records.map(\.sourceIdentifier))
            var signatures: [String: PhotoSignature] = [:]
            for id in ids where existing.contains(id) {
                let photo = state.photos[id]
                signatures[id] = PhotoSignature(hasPhoto: photo != nil, thumbnailHash: photo.map(PhotoHash.sha256Hex))
            }
            return signatures
        }
    }

    public func photoData(id: String) async throws -> Data? {
        try state.withLock { state in
            try Self.requireAccess(state)
            guard state.records.contains(where: { $0.sourceIdentifier == id }) else { throw ContactStoreError.notFound([id]) }
            state.dataReads += 1
            return state.photos[id]
        }
    }

    public func setPhoto(id: String, data: Data?, backup: BackupReceipt) async throws {
        try state.withLock { state in
            try Self.requireAccess(state)
            guard state.records.contains(where: { $0.sourceIdentifier == id }) else { throw ContactStoreError.notFound([id]) }
            state.photos[id] = state.dropsPhotoWrites ? nil : data
            state.version += 1
            state.log.append(StoreMutation(kind: .photo, ids: [id], receiptID: backup.id))
        }
        notify()
    }

    public func exportVCard(ids: [String]) async throws -> Data {
        let chosen: [ContactRecord] = try state.withLock { state in
            try Self.requireAccess(state)
            let byID = Dictionary(state.records.map { ($0.sourceIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
            let missing = ids.filter { byID[$0] == nil }
            guard missing.isEmpty else { throw ContactStoreError.notFound(missing) }
            return ids.compactMap { byID[$0] }
        }
        return Data(chosen.map(Self.vCard).joined().utf8)
    }

    public func changeToken() async throws -> Data? {
        try state.withLock { state in
            try Self.requireAccess(state)
            return Data("v\(state.version)".utf8)
        }
    }

    public func containerID() async throws -> String? {
        try state.withLock { state in
            try Self.requireAccess(state)
            return state.containerID
        }
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { $0.subscribers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.subscribers[id] = nil }
        }
        return stream
    }

    // MARK: helpers

    private func notify() {
        let subscribers = state.withLock { Array($0.subscribers.values) }
        for subscriber in subscribers { subscriber.yield() }
    }

    private static func requireAccess(_ state: State) throws {
        guard state.authorization == .authorized else { throw ContactStoreError.accessDenied }
    }

    /// Minimal vCard 3.0, enough for previews and tests; the real adapter uses CNContactVCardSerialization.
    private static func vCard(_ record: ContactRecord) -> String {
        func escape(_ text: String) -> String {
            text.replacing("\\", with: "\\\\").replacing(";", with: "\\;").replacing(",", with: "\\,")
                .replacing("\r\n", with: "\\n").replacing("\n", with: "\\n")
        }
        func line(_ name: String, label: String?, _ value: String) -> String {
            let type = label.flatMap { $0.isBlank ? nil : ";TYPE=\(escape($0))" } ?? ""
            return "\(name)\(type):\(escape(value))"
        }

        let display = [record.givenName, record.middleName, record.familyName].filter { !$0.isBlank }.joined(separator: " ")
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]
        lines.append("N:\(escape(record.familyName));\(escape(record.givenName));\(escape(record.middleName));;")
        lines.append("FN:\(escape(display.isEmpty ? record.organization : display))")
        if !record.nickname.isBlank { lines.append("NICKNAME:\(escape(record.nickname))") }
        if !record.organization.isBlank { lines.append("ORG:\(escape(record.organization))") }
        if !record.jobTitle.isBlank { lines.append("TITLE:\(escape(record.jobTitle))") }
        for phone in record.phones { lines.append(line("TEL", label: phone.label, phone.value)) }
        for email in record.emails { lines.append(line("EMAIL", label: email.label, email.value)) }
        for url in record.urls { lines.append(line("URL", label: url.label, url.value)) }
        for address in record.postalAddresses {
            let a = address.value
            let joined = ["", "", a.street, a.city, a.state, a.postalCode, a.country].map(escape).joined(separator: ";")
            lines.append("ADR\(address.label.map { ";TYPE=\(escape($0))" } ?? ""):\(joined)")
        }
        if let birthday = record.birthday, let month = birthday.month, let day = birthday.day {
            let year = birthday.year.map { String(format: "%04d", $0) } ?? "-"
            lines.append("BDAY:\(year)-\(String(format: "%02d-%02d", month, day))")
        }
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
