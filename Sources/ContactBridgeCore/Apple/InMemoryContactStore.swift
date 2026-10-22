import Foundation
import Synchronization

public struct StoreMutation: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case create
        case update
        case delete
        case merge
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
        var authorization: ContactAuthorization
        var nextID = 1
        var log: [StoreMutation] = []
        var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    private let state: Mutex<State>
    private let grantsAccess: Bool

    public init(
        records: [ContactRecord] = [],
        authorization: ContactAuthorization = .authorized,
        grantsAccess: Bool = true
    ) {
        state = Mutex(State(records: records, authorization: authorization))
        self.grantsAccess = grantsAccess
    }

    /// Every create/update/delete so far, with the receipt that authorized it.
    public var mutationLog: [StoreMutation] { state.withLock { $0.log } }

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
            state.log.append(StoreMutation(kind: .merge, ids: [stored.sourceIdentifier] + doomed, receiptID: backup.id))
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
