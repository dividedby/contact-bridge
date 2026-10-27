import Foundation

/// `manifest.json`: what a backup folder contains and how to check it.
public struct BackupManifest: Sendable, Hashable, Codable {
    public struct Counts: Sendable, Hashable, Codable {
        public var icloud: Int?
        public var googleConnections: Int?
        public var googleOther: Int?
        /// iCloud contacts whose photo is in `icloud.vcf`. Nil in backups made before photos were included.
        public var icloudPhotos: Int?
        /// Google contact photos saved under `google-photos/`. Nil when none were downloaded (no Google, or older backups).
        public var googlePhotos: Int?

        public init(
            icloud: Int? = nil, googleConnections: Int? = nil, googleOther: Int? = nil, icloudPhotos: Int? = nil, googlePhotos: Int? = nil
        ) {
            self.icloud = icloud
            self.googleConnections = googleConnections
            self.googleOther = googleOther
            self.icloudPhotos = icloudPhotos
            self.googlePhotos = googlePhotos
        }
    }

    public struct File: Sendable, Hashable, Codable {
        public var name: String
        /// Lower-case hex SHA-256 of the file's bytes.
        public var sha256: String
        public var bytes: Int
        /// Records in a JSON file; nil for the vCard.
        public var recordCount: Int?
    }

    public var appVersion: String
    public var createdAt: Date
    /// "icloud", "google", "googleOther": the sources this backup includes.
    public var sources: [String]
    public var counts: Counts
    /// Every file except the manifest itself.
    public var files: [File]
    /// True only when a notes provider contributed `icloud-notes.json`.
    public var notesIncluded: Bool
}
