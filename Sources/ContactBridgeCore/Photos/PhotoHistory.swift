import Foundation
import Synchronization

/// A Google contact photo that photo sync replaced or removed, kept so a mistake can be undone by hand. The bytes are the
/// photo as Google served it (1024 px), taken before the write; if they could not be read the write does not happen.
public struct PhotoHistoryEntry: Sendable, Hashable, Codable {
    public enum Operation: String, Sendable, Hashable, Codable {
        case replace, delete
    }

    public var at: Date
    public var operation: Operation
    public var icloudID: String
    public var resourceName: String
    /// The URL key of the photo that was there.
    public var urlKey: String?
    public var photo: Data

    public init(at: Date, operation: Operation, icloudID: String, resourceName: String, urlKey: String?, photo: Data) {
        self.at = at
        self.operation = operation
        self.icloudID = icloudID
        self.resourceName = resourceName
        self.urlKey = urlKey
        self.photo = photo
    }
}

/// Same shape as `SyncHistoryStoring`: append-only, 30 days.
public protocol PhotoHistoryStoring: Sendable {
    func append(_ entries: [PhotoHistoryEntry]) throws
    /// Every stored entry, oldest day first.
    func entries() throws -> [PhotoHistoryEntry]
    /// Whether this photo of this contact is already kept, so a repeated attempt does not keep it twice.
    func hasEntry(resourceName: String, urlKey: String?) throws -> Bool
    /// Deletes the days that are entirely older than the retention period (30 days).
    @discardableResult
    func prune(now: Date) throws -> Int
}

extension PhotoHistoryStoring {
    public func hasEntry(resourceName: String, urlKey: String?) throws -> Bool {
        try entries().contains { $0.resourceName == resourceName && $0.urlKey == urlKey }
    }
}

/// `photo-history/YYYY-MM-DD.jsonl` next to `links.json`: one JSON object per line, one file per day.
public final class PhotoHistoryStore: PhotoHistoryStoring, Sendable {
    public static var defaultDirectory: URL {
        LinkStore.defaultURL.deletingLastPathComponent().appendingPathComponent("photo-history", isDirectory: true)
    }

    private let directory: URL
    private let retentionDays: Int
    private let timeZone: TimeZone
    private let lock = Mutex(())

    /// - Parameters:
    ///   - retentionDays: days kept, counting today's.
    ///   - timeZone: decides which day an entry belongs to.
    public init(directory: URL = PhotoHistoryStore.defaultDirectory, retentionDays: Int = 30, timeZone: TimeZone = .current) {
        self.directory = directory
        self.retentionDays = retentionDays
        self.timeZone = timeZone
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    public func append(_ entries: [PhotoHistoryEntry]) throws {
        guard !entries.isEmpty else { return }
        let formatter = formatter()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var lines: [String: Data] = [:]
        for entry in entries {
            lines[formatter.string(from: entry.at), default: Data()] += try encoder.encode(entry) + Data("\n".utf8)
        }
        try lock.withLock { _ in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (day, data) in lines {
                let url = directory.appendingPathComponent("\(day).jsonl")
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                let handle = try FileHandle(forUpdating: url)
                defer { try? handle.close() }
                var payload = data
                let size = try handle.seekToEnd()
                if size > 0 {
                    // A tail cut short by a crash must not swallow the line appended after it.
                    try handle.seek(toOffset: size - 1)
                    if try handle.read(upToCount: 1) != Data("\n".utf8) { payload = Data("\n".utf8) + data }
                    try handle.seekToEnd()
                }
                try handle.write(contentsOf: payload)
                try handle.synchronize()
            }
        }
    }

    public func entries() throws -> [PhotoHistoryEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try lock.withLock { _ in
            try dayFiles().flatMap { url -> [PhotoHistoryEntry] in
                let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
                // A line cut short by a crash is skipped rather than hiding the rest.
                return text.split(separator: "\n").compactMap { try? decoder.decode(PhotoHistoryEntry.self, from: Data($0.utf8)) }
            }
        }
    }

    @discardableResult
    public func prune(now: Date) throws -> Int {
        let formatter = formatter()
        let calendar = calendar
        return try lock.withLock { _ in
            var removed = 0
            for url in try dayFiles() {
                guard let day = formatter.date(from: String(url.lastPathComponent.dropLast(".jsonl".count))),
                      let expires = calendar.date(byAdding: .day, value: retentionDays + 1, to: day), now >= expires
                else { continue }
                try FileManager.default.removeItem(at: url)
                removed += 1
            }
            return removed
        }
    }

    /// The day files, named `YYYY-MM-DD.jsonl`, oldest first. Anything else in the folder is left alone.
    private func dayFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let formatter = formatter()
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" && formatter.date(from: String($0.lastPathComponent.dropLast(".jsonl".count))) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

public final class InMemoryPhotoHistoryStore: PhotoHistoryStoring, Sendable {
    private let stored = Mutex<[PhotoHistoryEntry]>([])

    public init() {}

    public func append(_ entries: [PhotoHistoryEntry]) throws { stored.withLock { $0 += entries } }
    public func entries() throws -> [PhotoHistoryEntry] { stored.withLock { $0 } }
    public func prune(now: Date) throws -> Int {
        stored.withLock { entries in
            let before = entries.count
            entries.removeAll { now.timeIntervalSince($0.at) > 31 * 86400 }
            return before - entries.count
        }
    }
}
