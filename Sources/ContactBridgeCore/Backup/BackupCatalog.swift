import Foundation

/// One finished backup folder, as described by its manifest.
public struct BackupEntry: Sendable, Hashable, Identifiable {
    /// The folder name.
    public var id: String
    public var folderURL: URL
    public var createdAt: Date
    public var counts: BackupManifest.Counts
    public var notesIncluded: Bool
    public var sources: [String]
    public var appVersion: String
}

/// Reads the backups on disk. Read-only: nothing here changes or deletes a folder.
public enum BackupCatalog {
    /// Newest first. Folders without a readable manifest (not made by the app, or abandoned `.tmp-` ones) are skipped.
    public static func list(in directory: URL = BackupWriter.defaultDirectory) -> [BackupEntry] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = children.compactMap { url -> BackupEntry? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
                  let manifest = try? decoder.decode(BackupManifest.self, from: data)
            else { return nil }
            return BackupEntry(
                id: url.lastPathComponent, folderURL: url, createdAt: manifest.createdAt, counts: manifest.counts,
                notesIncluded: manifest.notesIncluded, sources: manifest.sources, appVersion: manifest.appVersion
            )
        }
        return entries.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }
}
