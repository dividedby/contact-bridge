import Foundation

public enum ContactAuthorization: String, Sendable, Hashable, Codable {
    case notDetermined
    case restricted
    case denied
    case authorized
}

public enum ContactStoreError: Error, Sendable, Equatable {
    case accessDenied
    /// No CardDAV (iCloud-type) container exists.
    case noICloudContainer
    /// Several plausible containers and no safe default: let the user pick, then build the adapter with that id.
    case containerChoiceRequired([ContactContainer])
    case notFound([String])
    /// The contact exists but lives outside the selected container; it is never touched.
    case outsideSelectedContainer([String])
}

/// The user's iCloud contacts. Reads are free; every mutation needs a `BackupReceipt`.
public protocol ContactStoring: Sendable {
    func authorizationStatus() async -> ContactAuthorization
    /// Prompts if undetermined. Returns the resulting status.
    func requestAccess() async throws -> ContactAuthorization

    /// Every contact in the iCloud container, as separate (non-unified) records.
    func fetchAll() async throws -> [ContactRecord]

    /// Returns the stored record, carrying its newly assigned identity.
    func create(_ record: ContactRecord, backup: BackupReceipt) async throws -> ContactRecord
    /// Overwrites the modeled fields of the contact named by the record's identifier.
    func update(_ record: ContactRecord, backup: BackupReceipt) async throws
    /// Makes `survivor` the single contact: applies its fields, folds in what ContactRecord cannot express from the
    /// duplicates (where the store has such data), and deletes `ids`, as one operation. `survivor` itself is never
    /// deleted even if listed. Throws `notFound` without changing anything if the survivor or any id is missing.
    func merge(survivor: ContactRecord, absorbing ids: [String], backup: BackupReceipt) async throws
    /// All-or-nothing: throws `notFound` without deleting anything if any id is missing.
    func delete(ids: [String], backup: BackupReceipt) async throws

    /// A single .vcf holding the given contacts, in the order requested.
    func exportVCard(ids: [String]) async throws -> Data

    /// Yields once whenever contacts change (including this process's own saves). Coalesced.
    func changes() -> AsyncStream<Void>

    /// An opaque marker of the store's current state: the same token as last time means nothing changed since. Nil when
    /// the store cannot tell, so callers must then assume a change.
    func changeToken() async throws -> Data?
    /// Identifier of the container every call reads from, or nil when the store has no such notion. Sync pauses when
    /// it differs from the one it last synced with.
    func containerID() async throws -> String?
}

extension ContactStoring {
    /// Stores that cannot tell what changed (test doubles) report no token, which callers treat as "changed".
    public func changeToken() async throws -> Data? { nil }
    public func containerID() async throws -> String? { nil }
}
