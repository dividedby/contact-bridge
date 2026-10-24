import CryptoKit
import Foundation
import Synchronization

// MARK: journal

/// One Google write the executor is about to make (or has made but not yet recorded). Written to `sync-journal.json`
/// before the batch is sent, removed once the baselines are committed.
public struct SyncJournalEntry: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case create, update, delete
    }

    public var opID: String
    public var kind: Kind
    public var icloudID: String
    /// Nil for a create: the contact has no resource name until Google answers.
    public var resourceName: String?
    /// The ownership tag the write carries or relies on: the iCloud identifier.
    public var tag: String
    /// The etag the update was made against, or the etag a delete was checked at.
    public var baseEtag: String?
    /// An update: `projectionHash` of what was sent. A create: `ContactFingerprint` of the iCloud contact.
    public var payloadHash: String?
    /// The groups an update writes.
    public var fields: [SyncField]
    /// What to store if the write turns out to have been applied: the planned baseline, whose Google half is replaced with
    /// what Google returns (or, after a crash, what a refetch shows).
    public var baseline: SyncBaseline?
    /// When the batch holding this entry was sent. A create that Google may not have listed yet is judged against it.
    public var attemptedAt: Date?
    /// Set when recovery looked for a create by its tag, did not find it, and held it back because the attempt is too
    /// recent for a listing to be trusted (`SyncJournalRecovery.createGracePeriod`).
    public var recheckedAt: Date?

    public var id: String { opID }

    /// Digest of the pushed groups' values (and the note, when pushed), comparable between what was sent and what Google
    /// holds afterwards.
    static func projectionHash(of record: ContactRecord, fields: Set<SyncField>, noteHash: String) -> String {
        var probe = ContactRecord(id: "", source: .google, sourceIdentifier: "")
        for field in SyncField.recordFields where fields.contains(field) { probe.copy(field, from: record) }
        let text = ContactFingerprint.of(probe) + "|" + (fields.contains(.note) ? noteHash : "")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The contents of `sync-journal.json`. Empty (and the file absent) between runs.
public struct SyncJournal: Sendable, Hashable, Codable, VersionedFileContents {
    public static let currentVersion = 1

    public var version: Int
    public var entries: [SyncJournalEntry]

    public init(version: Int = SyncJournal.currentVersion, entries: [SyncJournalEntry] = []) {
        self.version = version
        self.entries = entries
    }
}

public protocol SyncJournalStoring: Sendable {
    /// Empty when nothing is pending.
    func load() throws -> SyncJournal
    /// Adds entries; call before sending the batch they describe.
    func append(_ entries: [SyncJournalEntry]) throws
    /// Overwrites the entries with the same `opID`.
    func replace(_ entries: [SyncJournalEntry]) throws
    /// Removes the entries once their outcome is committed. The file goes when the last one does.
    func remove(opIDs: [String]) throws
}

/// `sync-journal.json` next to `links.json`, rewritten atomically on every change.
public final class SyncJournalStore: SyncJournalStoring, Sendable {
    public static var defaultURL: URL { VersionedJSONFile<SyncJournal>.inSupportFolder("sync-journal.json") }

    private let file: VersionedJSONFile<SyncJournal>
    private let lock = Mutex(())

    public init(url: URL = SyncJournalStore.defaultURL) {
        file = VersionedJSONFile(url: url)
    }

    public func load() throws -> SyncJournal { try lock.withLock { _ in try file.read() ?? SyncJournal() } }

    public func append(_ entries: [SyncJournalEntry]) throws {
        guard !entries.isEmpty else { return }
        try lock.withLock { _ in
            var journal = try file.read() ?? SyncJournal()
            journal.entries += entries
            try file.write(journal)
        }
    }

    public func replace(_ entries: [SyncJournalEntry]) throws {
        guard !entries.isEmpty else { return }
        try lock.withLock { _ in
            guard var journal = try file.read() else { return }
            let new = Dictionary(entries.map { ($0.opID, $0) }, uniquingKeysWith: { _, last in last })
            journal.entries = journal.entries.map { new[$0.opID] ?? $0 }
            try file.write(journal)
        }
    }

    public func remove(opIDs: [String]) throws {
        try lock.withLock { _ in
            guard var journal = try file.read() else { return }
            let doomed = Set(opIDs)
            journal.entries.removeAll { doomed.contains($0.opID) }
            if journal.entries.isEmpty { try file.remove() } else { try file.write(journal) }
        }
    }
}

public final class InMemorySyncJournalStore: SyncJournalStoring, Sendable {
    private let journal = Mutex(SyncJournal())

    public init() {}

    public func load() throws -> SyncJournal { journal.withLock { $0 } }
    public func append(_ entries: [SyncJournalEntry]) throws { journal.withLock { $0.entries += entries } }
    public func replace(_ entries: [SyncJournalEntry]) throws {
        let new = Dictionary(entries.map { ($0.opID, $0) }, uniquingKeysWith: { _, last in last })
        journal.withLock { $0.entries = $0.entries.map { new[$0.opID] ?? $0 } }
    }
    public func remove(opIDs: [String]) throws {
        let doomed = Set(opIDs)
        journal.withLock { $0.entries.removeAll { doomed.contains($0.opID) } }
    }
}

// MARK: history

/// What a Google update or delete changed, kept so a mistake can be undone by hand. Every write appears twice: once
/// before it is sent (`confirmed` false, no `after`) and once when Google confirmed it.
public struct SyncHistoryEntry: Sendable, Hashable, Codable {
    public enum Operation: String, Sendable, Hashable, Codable {
        case update, delete
    }

    public var at: Date
    public var operation: Operation
    public var icloudID: String
    public var resourceName: String
    /// The person as Google had it before the write. Nil in the confirmation of a write found by crash recovery.
    public var before: GooglePerson?
    /// The person Google returned for an update.
    public var after: GooglePerson?
    public var confirmed: Bool

    public init(
        at: Date, operation: Operation, icloudID: String, resourceName: String, before: GooglePerson?, after: GooglePerson?, confirmed: Bool
    ) {
        self.at = at
        self.operation = operation
        self.icloudID = icloudID
        self.resourceName = resourceName
        self.before = before
        self.after = after
        self.confirmed = confirmed
    }
}

public protocol SyncHistoryStoring: Sendable {
    func append(_ entries: [SyncHistoryEntry]) throws
    /// Every stored entry, oldest day first.
    func entries() throws -> [SyncHistoryEntry]
    /// Deletes the days that are entirely older than the retention period (30 days).
    @discardableResult
    func prune(now: Date) throws -> Int
}

/// `sync-history/YYYY-MM-DD.jsonl` next to `links.json`: one JSON object per line, one file per day.
public final class SyncHistoryStore: SyncHistoryStoring, Sendable {
    public static var defaultDirectory: URL {
        LinkStore.defaultURL.deletingLastPathComponent().appendingPathComponent("sync-history", isDirectory: true)
    }

    private let directory: URL
    private let retentionDays: Int
    private let timeZone: TimeZone
    private let lock = Mutex(())

    /// - Parameters:
    ///   - retentionDays: days kept, counting today's.
    ///   - timeZone: decides which day an entry belongs to.
    public init(directory: URL = SyncHistoryStore.defaultDirectory, retentionDays: Int = 30, timeZone: TimeZone = .current) {
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

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public func append(_ entries: [SyncHistoryEntry]) throws {
        guard !entries.isEmpty else { return }
        let formatter = formatter()
        let encoder = encoder()
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

    public func entries() throws -> [SyncHistoryEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try lock.withLock { _ in
            try dayFiles().flatMap { url -> [SyncHistoryEntry] in
                let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
                // A line cut short by a crash is skipped rather than hiding the rest.
                return text.split(separator: "\n").compactMap { try? decoder.decode(SyncHistoryEntry.self, from: Data($0.utf8)) }
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

public final class InMemorySyncHistoryStore: SyncHistoryStoring, Sendable {
    private let stored = Mutex<[SyncHistoryEntry]>([])

    public init() {}

    public func append(_ entries: [SyncHistoryEntry]) throws { stored.withLock { $0 += entries } }
    public func entries() throws -> [SyncHistoryEntry] { stored.withLock { $0 } }
    public func prune(now: Date) throws -> Int {
        stored.withLock { entries in
            let before = entries.count
            entries.removeAll { now.timeIntervalSince($0.at) > 31 * 86400 }
            return before - entries.count
        }
    }
}

// MARK: after a write

extension SyncBaseline {
    /// The baseline once an update is confirmed: the planned one, with the groups that were pushed (and the note, when
    /// pushed) taken from what Google returned, so our own write echoes back as "unchanged".
    ///
    /// Groups held for review keep their old Google values. While any group still differs from what Google holds, the etag
    /// stays at the old one too: the planner treats "same etag as the baseline" as "nothing changed" and would otherwise
    /// never see the unreviewed Google edit again.
    func afterUpdate(fields: Set<SyncField>, returned person: GooglePerson, at now: Date) -> SyncBaseline {
        var baseline = self
        var unreviewed = false
        if let record = GooglePersonMapper.record(from: person, source: .google) {
            for field in SyncField.recordFields {
                if fields.contains(field) { baseline.google.copy(field, from: record) }
                var probe = baseline.google
                probe.copy(field, from: record)
                if probe != baseline.google { unreviewed = true }
            }
        }
        let noteHash = GooglePersonMapper.noteHash(of: person)
        if fields.contains(.note) { baseline.googleNoteHash = noteHash }
        if let known = baseline.googleNoteHash, known != noteHash { unreviewed = true }
        if !unreviewed, let etag = person.etag { baseline.googleEtag = etag }
        baseline.syncedAt = now
        return baseline
    }

    /// The baseline of a contact just created in Google: the iCloud half as planned, the Google half as returned.
    func afterCreate(returned person: GooglePerson, at now: Date) -> SyncBaseline {
        var baseline = self
        if let record = GooglePersonMapper.record(from: person, source: .google) { baseline.google = record }
        baseline.googleEtag = person.etag ?? ""
        baseline.googleNoteHash = GooglePersonMapper.noteHash(of: person)
        baseline.syncedAt = now
        return baseline
    }
}

// MARK: recovery

/// What recovery made of the journal's entries.
public struct SyncRecoveryReport: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        case applied, notApplied, unresolved
    }

    /// Writes Google had applied: their links and baselines are now stored.
    public var applied = 0
    /// Writes that did not happen, or no longer match what was sent; the next plan sees them again.
    public var notApplied = 0
    /// Entries that could not be checked (Google was unreachable); they stay in the journal for the next attempt.
    public var unresolved = 0
    /// Each entry's outcome, by `SyncJournalEntry.opID`.
    public var outcomes: [String: Outcome] = [:]

    public var isEmpty: Bool { applied + notApplied + unresolved == 0 }
}

/// Settles journal entries whose outcome is unknown: after a crash, or when a batch answered `ambiguous`. Never writes to
/// Google; it only looks, and records what it finds.
///
/// - A create is looked up by its ownership tag in a full listing: found means applied (linked, baselined from what Google
///   holds). Not found only means it did not happen once the attempt is `createGracePeriod` old: a listing can lag behind
///   a create, and creating again would duplicate the contact. Until then the entry stays in the journal (marked
///   `recheckedAt`) and the contact's create is held back.
/// - An update is refetched: the same etag as before means nothing happened; otherwise it counts as applied if the
///   pushed groups hold what was sent, and is left for the next plan to re-diff if not.
/// - A delete is applied when Google answers 404.
struct SyncJournalRecovery: Sendable {
    /// How long after a create was sent a full listing may still be missing it.
    static let createGracePeriod: TimeInterval = 10 * 60

    let google: any GoogleContactsClient
    let links: any LinkStoring
    let state: any SyncStateStoring
    let journal: any SyncJournalStoring
    let history: any SyncHistoryStoring
    let now: @Sendable () -> Date

    func recover() async throws -> SyncRecoveryReport {
        try await resolve(try journal.load().entries)
    }

    func resolve(_ entries: [SyncJournalEntry]) async throws -> SyncRecoveryReport {
        var report = SyncRecoveryReport()
        guard !entries.isEmpty else { return report }
        let at = now()

        var tagged: [String: GooglePerson]?
        if entries.contains(where: { $0.kind == .create }) {
            let feed = try? await GoogleChangeFeed(client: google).fetch(state: SyncState(), requireFullListing: true)
            tagged = feed.map { feed in feed.ownershipIndex.compactMapValues { feed.people[$0] } }
        }

        let knownBaselines = try state.load().baselines
        let knownLinks = try links.load().links
        var rechecked: [SyncJournalEntry] = []
        var baselines: [String: SyncBaseline] = [:]
        var newLinks: [ImportedLink] = []
        var droppedIDs: [String] = []
        var confirmations: [SyncHistoryEntry] = []
        var settled: [String] = []
        func mark(_ entry: SyncJournalEntry, _ outcome: SyncRecoveryReport.Outcome) {
            switch outcome {
            case .applied: report.applied += 1
            case .notApplied: report.notApplied += 1
            case .unresolved: report.unresolved += 1
            }
            report.outcomes[entry.opID] = outcome
        }

        for entry in entries {
            switch entry.kind {
            case .create:
                guard let tagged else {
                    mark(entry, .unresolved)
                    continue
                }
                if let person = tagged[entry.tag], let name = person.resourceName, let baseline = entry.baseline {
                    settled.append(entry.opID)
                    // The planner may have linked it already from a later listing; that baseline is newer than ours.
                    if knownBaselines[entry.icloudID] == nil || knownLinks[entry.icloudID] == nil {
                        baselines[entry.icloudID] = baseline.afterCreate(returned: person, at: at)
                        newLinks.append(ImportedLink(icloudID: entry.icloudID, googleResourceName: name, origin: .createdInGoogle))
                    }
                    mark(entry, .applied)
                } else if at.timeIntervalSince(entry.attemptedAt ?? entry.recheckedAt ?? at) < Self.createGracePeriod {
                    var held = entry
                    held.recheckedAt = at
                    rechecked.append(held)
                    mark(entry, .unresolved)
                } else {
                    settled.append(entry.opID)
                    mark(entry, .notApplied)
                }

            case .update:
                guard let name = entry.resourceName else { continue }
                let person: GooglePerson
                do {
                    person = try await google.getPerson(resourceName: name)
                } catch GoogleAPIError.notFound {
                    settled.append(entry.opID)
                    mark(entry, .notApplied)
                    continue
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    mark(entry, .unresolved)
                    continue
                }
                settled.append(entry.opID)
                let fields = Set(entry.fields)
                guard person.etag != entry.baseEtag, let record = GooglePersonMapper.record(from: person, source: .google),
                      SyncJournalEntry.projectionHash(of: record, fields: fields, noteHash: GooglePersonMapper.noteHash(of: person)) == entry.payloadHash,
                      let baseline = entry.baseline
                else {
                    mark(entry, .notApplied)
                    continue
                }
                baselines[entry.icloudID] = baseline.afterUpdate(fields: fields, returned: person, at: at)
                confirmations.append(SyncHistoryEntry(
                    at: at, operation: .update, icloudID: entry.icloudID, resourceName: name, before: nil, after: person, confirmed: true
                ))
                mark(entry, .applied)

            case .delete:
                guard let name = entry.resourceName else { continue }
                do {
                    _ = try await google.getPerson(resourceName: name)
                    settled.append(entry.opID)
                    mark(entry, .notApplied)
                } catch GoogleAPIError.notFound {
                    settled.append(entry.opID)
                    droppedIDs.append(entry.icloudID)
                    confirmations.append(SyncHistoryEntry(
                        at: at, operation: .delete, icloudID: entry.icloudID, resourceName: name, before: nil, after: nil, confirmed: true
                    ))
                    mark(entry, .applied)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    mark(entry, .unresolved)
                }
            }
        }

        try links.add(newLinks, at: at)
        try links.remove(icloudIDs: droppedIDs)
        try state.update { state in
            for (id, baseline) in baselines { state.baselines[id] = baseline }
            for id in droppedIDs { state.baselines[id] = nil }
        }
        // The history line is a convenience: the write is already recorded, so a failure here does not undo it.
        try? history.append(confirmations)
        try journal.replace(rechecked)
        try journal.remove(opIDs: settled)
        return report
    }
}
