import Foundation

/// Proof that a verified backup exists for the changes a mutating store call is about to make.
///
/// Opaque by construction: the initializer is internal, so only Core (the backup writer) can mint one. Tests use
/// `BackupReceipt.forTesting()` from the test target via `@testable`.
public struct BackupReceipt: Sendable, Hashable {
    public let id: UUID
    public let createdAt: Date
    /// The finished backup folder.
    public let folderURL: URL
    public let manifest: BackupManifest

    init(id: UUID, createdAt: Date, folderURL: URL, manifest: BackupManifest) {
        self.id = id
        self.createdAt = createdAt
        self.folderURL = folderURL
        self.manifest = manifest
    }

    /// True if the backup is at most `maxAge` seconds old at `now`. Later mutating services use this to demand a recent backup.
    public func isFresh(maxAge: TimeInterval = 3600, now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) <= maxAge
    }
}
