import Foundation

public enum SyncFileError: Error, Sendable, Equatable {
    /// The file was written by a different version of the format; it is left alone.
    case unsupportedVersion(file: String, version: Int)
    /// The file exists but cannot be read or understood; it is left alone.
    case unreadable(file: String, reason: String)
}

extension SyncFileError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let file, let version):
            "\(file) was written by a newer version of Contact Bridge (format \(version)) and was left as it was. Update the app."
        case .unreadable(let file, let reason):
            "\(file) could not be read and was left as it was: \(reason)"
        }
    }
}

/// What a `VersionedJSONFile` holds.
protocol VersionedFileContents: Codable, Sendable {
    static var currentVersion: Int { get }
    var version: Int { get }
}

/// One small JSON file next to `links.json`, with a `version` the reader must know, rewritten atomically (temp file in
/// the same folder, then rename). Callers serialize access themselves.
struct VersionedJSONFile<Contents: VersionedFileContents>: Sendable {
    let url: URL

    /// Next to `links.json`.
    static func inSupportFolder(_ name: String) -> URL {
        LinkStore.defaultURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    private struct Header: Decodable {
        var version: Int
    }

    /// Nil when there is no file. Throws, leaving the file alone, when it cannot be read or is of another version.
    func read() throws -> Contents? {
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw SyncFileError.unreadable(file: name, reason: error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let header = try decoder.decode(Header.self, from: data)
            guard header.version == Contents.currentVersion else { throw SyncFileError.unsupportedVersion(file: name, version: header.version) }
            return try decoder.decode(Contents.self, from: data)
        } catch let error as SyncFileError {
            throw error
        } catch {
            throw SyncFileError.unreadable(file: name, reason: error.localizedDescription)
        }
    }

    func write(_ contents: Contents) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(contents).write(to: url, options: .atomic)
    }

    func remove() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }
}
