import Foundation
import Synchronization

/// One iCloud contact's counterpart in Google.
public struct LinkEntry: Sendable, Hashable, Codable {
    public var googleResourceName: String
    public var linkedAt: Date

    public init(googleResourceName: String, linkedAt: Date) {
        self.googleResourceName = googleResourceName
        self.linkedAt = linkedAt
    }
}

/// The contents of `links.json`: which iCloud contact corresponds to which Google contact. Phase 2 sync reads it so it
/// does not create what already exists on the other side.
///
/// ```json
/// { "version": 1, "links": { "<iCloud id>": { "googleResourceName": "people/c123", "linkedAt": "2026-10-21T15:04:05Z" } } }
/// ```
/// A Google contact belongs to at most one iCloud id. Readers must refuse a version they do not know.
public struct LinkTable: Sendable, Hashable, Codable {
    public static let currentVersion = 1
    public var version: Int
    /// Keyed by iCloud contact identifier.
    public var links: [String: LinkEntry]

    public init(version: Int = LinkTable.currentVersion, links: [String: LinkEntry] = [:]) {
        self.version = version
        self.links = links
    }

    public func icloudID(forGoogleResourceName name: String) -> String? {
        links.filter { $0.value.googleResourceName == name }.keys.min()
    }

    mutating func add(_ new: [ImportedLink], at date: Date) {
        for link in new {
            // One owner per Google contact, so reverse lookups are unambiguous.
            links = links.filter { $0.value.googleResourceName != link.googleResourceName }
            links[link.icloudID] = LinkEntry(googleResourceName: link.googleResourceName, linkedAt: date)
        }
    }

    mutating func remove(icloudIDs: [String]) {
        for id in icloudIDs { links[id] = nil }
    }
}

public enum LinkStoreError: Error, Sendable, Equatable {
    /// The file was written by a different version of the format; it is left alone.
    case unsupportedVersion(Int)
    /// The file exists but cannot be read or understood; it is left alone.
    case unreadable(String)
}

public protocol LinkStoring: Sendable {
    func load() throws -> LinkTable
    /// Merges `links` into what is stored, stamped `date`. Throws without changing anything if the stored data cannot be read.
    func add(_ links: [ImportedLink], at date: Date) throws
    func remove(icloudIDs: [String]) throws
}

/// `links.json`, rewritten atomically (temp file in the same folder, then rename) on every change.
public final class LinkStore: LinkStoring, Sendable {
    /// `~/Library/Application Support/Contact Bridge/links.json` (inside the app's container when sandboxed).
    public static var defaultURL: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Contact Bridge", isDirectory: true).appendingPathComponent("links.json")
    }

    private let url: URL
    /// Serializes read-modify-write within this process.
    private let lock = Mutex(())

    public init(url: URL = LinkStore.defaultURL) {
        self.url = url
    }

    public func load() throws -> LinkTable {
        try lock.withLock { _ in try read() }
    }

    public func add(_ links: [ImportedLink], at date: Date) throws {
        guard !links.isEmpty else { return }
        try lock.withLock { _ in
            var table = try read()
            table.add(links, at: date)
            try write(table)
        }
    }

    public func remove(icloudIDs: [String]) throws {
        try lock.withLock { _ in
            var table = try read()
            let before = table.links.count
            table.remove(icloudIDs: icloudIDs)
            if table.links.count != before { try write(table) }
        }
    }

    private struct Header: Decodable {
        var version: Int
    }

    private func read() throws -> LinkTable {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return LinkTable()
        } catch {
            throw LinkStoreError.unreadable(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let header = try decoder.decode(Header.self, from: data)
            guard header.version == LinkTable.currentVersion else { throw LinkStoreError.unsupportedVersion(header.version) }
            return try decoder.decode(LinkTable.self, from: data)
        } catch let error as LinkStoreError {
            throw error
        } catch {
            throw LinkStoreError.unreadable(error.localizedDescription)
        }
    }

    private func write(_ table: LinkTable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(table).write(to: url, options: .atomic)
    }
}

/// For previews, the demo mode and tests: same semantics, nothing on disk.
public final class InMemoryLinkStore: LinkStoring, Sendable {
    private let table = Mutex(LinkTable())

    public init() {}

    public func load() throws -> LinkTable { table.withLock { $0 } }
    public func add(_ links: [ImportedLink], at date: Date) throws { table.withLock { $0.add(links, at: date) } }
    public func remove(icloudIDs: [String]) throws { table.withLock { $0.remove(icloudIDs: icloudIDs) } }
}
