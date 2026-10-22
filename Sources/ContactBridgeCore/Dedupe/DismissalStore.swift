import Foundation
import Synchronization

public enum DismissalStoreError: Error, Sendable, Equatable {
    case unsupportedVersion(Int)
    case unreadable(String)
}

extension DismissalStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "dismissed-clusters.json was written by a newer version of Contact Bridge (format \(version)) and was left as it was. Update the app."
        case .unreadable(let reason):
            "dismissed-clusters.json could not be read and was left as it was: \(reason)"
        }
    }
}

/// Groups of contacts the user said are not duplicates, as sets of contact ids. A cluster is hidden when its members are
/// all inside one dismissed set; a cluster that gained a member is shown again.
///
/// ```json
/// { "version": 1, "dismissed": [ { "memberIDs": ["id1", "id2"], "dismissedAt": "2026-10-21T15:04:05Z" } ] }
/// ```
public struct DismissalTable: Sendable, Hashable, Codable {
    public static let currentVersion = 1

    public struct Entry: Sendable, Hashable, Codable {
        /// Sorted, distinct, at least two.
        public var memberIDs: [String]
        public var dismissedAt: Date

        public init(memberIDs: [String], dismissedAt: Date) {
            self.memberIDs = memberIDs
            self.dismissedAt = dismissedAt
        }
    }

    public var version: Int
    public var dismissed: [Entry]

    public init(version: Int = DismissalTable.currentVersion, dismissed: [Entry] = []) {
        self.version = version
        self.dismissed = dismissed
    }

    public func isDismissed(_ ids: some Collection<String>) -> Bool {
        let set = Set(ids)
        guard !set.isEmpty else { return false }
        return dismissed.contains { set.isSubset(of: $0.memberIDs) }
    }

    /// Sets of fewer than two ids are ignored. Entries the new set swallows are dropped; a set already covered is a no-op.
    public mutating func dismiss(_ ids: some Collection<String>, at date: Date) {
        let sorted = Array(Set(ids)).sorted()
        guard sorted.count >= 2, !isDismissed(sorted) else { return }
        let new = Set(sorted)
        dismissed.removeAll { Set($0.memberIDs).isSubset(of: new) }
        dismissed.append(Entry(memberIDs: sorted, dismissedAt: date))
    }

    /// The clusters that are not dismissed, in their given order.
    public func visible(from clusters: [DuplicateCluster]) -> [DuplicateCluster] {
        clusters.filter { !isDismissed($0.members.map(\.id)) }
    }
}

public protocol DismissalStoring: Sendable {
    func load() throws -> DismissalTable
    func dismiss(memberIDs: [String], at date: Date) throws
    /// Forgets every dismissal.
    func clear() throws
}

/// `dismissed-clusters.json` next to `links.json`, rewritten atomically on every change.
public final class DismissalStore: DismissalStoring, Sendable {
    public static var defaultURL: URL {
        LinkStore.defaultURL.deletingLastPathComponent().appendingPathComponent("dismissed-clusters.json")
    }

    private let url: URL
    private let lock = Mutex(())

    public init(url: URL = DismissalStore.defaultURL) {
        self.url = url
    }

    public func load() throws -> DismissalTable { try lock.withLock { _ in try read() } }

    public func dismiss(memberIDs: [String], at date: Date) throws {
        try lock.withLock { _ in
            var table = try read()
            let before = table
            table.dismiss(memberIDs, at: date)
            if table != before { try write(table) }
        }
    }

    public func clear() throws {
        try lock.withLock { _ in
            let table = try read()
            if !table.dismissed.isEmpty { try write(DismissalTable()) }
        }
    }

    private struct Header: Decodable {
        var version: Int
    }

    private func read() throws -> DismissalTable {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return DismissalTable()
        } catch {
            throw DismissalStoreError.unreadable(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let header = try decoder.decode(Header.self, from: data)
            guard header.version == DismissalTable.currentVersion else { throw DismissalStoreError.unsupportedVersion(header.version) }
            return try decoder.decode(DismissalTable.self, from: data)
        } catch let error as DismissalStoreError {
            throw error
        } catch {
            throw DismissalStoreError.unreadable(error.localizedDescription)
        }
    }

    private func write(_ table: DismissalTable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(table).write(to: url, options: .atomic)
    }
}

public final class InMemoryDismissalStore: DismissalStoring, Sendable {
    private let table = Mutex(DismissalTable())

    public init() {}

    public func load() throws -> DismissalTable { table.withLock { $0 } }
    public func dismiss(memberIDs: [String], at date: Date) throws { table.withLock { $0.dismiss(memberIDs, at: date) } }
    public func clear() throws { table.withLock { $0 = DismissalTable() } }
}
