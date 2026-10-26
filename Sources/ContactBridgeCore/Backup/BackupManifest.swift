import Foundation

/// `manifest.json`: what a backup folder contains and how to check it.
public struct BackupManifest: Sendable, Hashable, Codable {
    public struct Counts: Sendable, Hashable, Codable {
        public var icloud: Int?
        public var googleConnections: Int?
        public var googleOther: Int?

        public init(icloud: Int? = nil, googleConnections: Int? = nil, googleOther: Int? = nil) {
            self.icloud = icloud
            self.googleConnections = googleConnections
            self.googleOther = googleOther
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
