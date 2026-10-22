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
}
