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
    /// This store has no photo access.
    case photosUnsupported
}

/// What the store says about a contact's photo without reading the picture itself: whether there is one, and a hash of its
/// thumbnail, which changes when the photo does.
public struct PhotoSignature: Sendable, Hashable {
    public var hasPhoto: Bool
    /// `PhotoHash.sha256Hex` of the thumbnail data; nil when there is no photo or no thumbnail.
    public var thumbnailHash: String?

    public init(hasPhoto: Bool, thumbnailHash: String? = nil) {
        self.hasPhoto = hasPhoto
        self.thumbnailHash = thumbnailHash
    }
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

    /// The photo signature of each of these contacts that exists in the container; ids the store does not have are left out.
    /// Cheap enough to ask for many contacts at once: it never reads a full-size picture.
    func photoSignatures(ids: [String]) async throws -> [String: PhotoSignature]
    /// The full-size photo bytes, nil when the contact has none. Throws `notFound` if the contact is not there.
    func photoData(id: String) async throws -> Data?
    /// Sets the contact's photo to these image bytes, or removes it when `data` is nil. Throws `notFound` if the contact is
    /// not there and `outsideSelectedContainer` if it lives elsewhere.
    func setPhoto(id: String, data: Data?, backup: BackupReceipt) async throws
}

extension ContactStoring {
    /// Stores that cannot tell what changed (test doubles) report no token, which callers treat as "changed".
    public func changeToken() async throws -> Data? { nil }
    public func containerID() async throws -> String? { nil }

    /// Stores without photo access (test doubles) have no photos and refuse to write one.
    public func photoSignatures(ids: [String]) async throws -> [String: PhotoSignature] { [:] }
    public func photoData(id: String) async throws -> Data? { nil }
    public func setPhoto(id: String, data: Data?, backup: BackupReceipt) async throws { throw ContactStoreError.photosUnsupported }
}
