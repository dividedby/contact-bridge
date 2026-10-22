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

public enum BackupCatalogError: Error, Equatable {
    /// The folder is not a backup the app made directly inside the backups directory.
    case notABackup
}

/// Reads the backups on disk. The only change it makes is `moveToTrash`, which the user can undo from the Trash.
public enum BackupCatalog {
    /// Moves one backup folder to the Trash. Refuses anything that is not a manifest-bearing folder directly inside
    /// `directory`, so a stale or crafted entry can never trash something else.
    public static func moveToTrash(
        _ entry: BackupEntry,
        in directory: URL = BackupWriter.defaultDirectory,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        let folder = entry.folderURL.standardizedFileURL.resolvingSymlinksInPath()
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard folder.deletingLastPathComponent().path == parent.path,
              !folder.lastPathComponent.hasPrefix("."),
              list(in: directory).contains(where: { $0.folderURL.standardizedFileURL.resolvingSymlinksInPath() == folder })
        else { throw BackupCatalogError.notABackup }
        try trash(folder)
    }

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
