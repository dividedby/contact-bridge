import Foundation
import Testing
@testable import ContactBridgeCore

struct SyncJournalTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func entry(_ id: String, _ kind: SyncJournalEntry.Kind = .update) -> SyncJournalEntry {
        SyncJournalEntry(
            opID: id, kind: kind, icloudID: "I\(id)", resourceName: kind == .create ? nil : "people/c\(id)", tag: "I\(id)",
            baseEtag: "e1", payloadHash: "h", fields: kind == .update ? [.phones, .note] : [], baseline: nil
        )
    }

    // MARK: journal file

    @Test("The journal file is versioned, grows per batch, and disappears when the last entry is settled")
    func journalFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync-journal.json")
        let store = SyncJournalStore(url: url)
        #expect(try store.load() == SyncJournal() && !FileManager.default.fileExists(atPath: url.path))

        try store.append([entry("1"), entry("2", .create)])
        try store.append([entry("3", .delete)])
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let loaded = try SyncJournalStore(url: url).load()
        #expect(loaded.entries.map(\.opID) == ["1", "2", "3"] && loaded.entries[1].resourceName == nil && loaded.entries[0].fields == [.phones, .note])

        try store.remove(opIDs: ["1", "3"])
        #expect(try store.load().entries.map(\.opID) == ["2"])
        try store.remove(opIDs: ["2"])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try store.remove(opIDs: ["2"])
    }

    @Test("A journal of another version is left alone and refuses new entries")
    func journalVersion() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync-journal.json")
        let future = Data(#"{"version": 2, "entries": []}"#.utf8)
        try future.write(to: url)
        let store = SyncJournalStore(url: url)
        #expect(throws: SyncFileError.unsupportedVersion(file: "sync-journal.json", version: 2)) { try store.load() }
        #expect(throws: SyncFileError.unsupportedVersion(file: "sync-journal.json", version: 2)) { try store.append([entry("1")]) }
        #expect(try Data(contentsOf: url) == future)
    }

    @Test("The projection hash covers the pushed groups only, and the note only when it is pushed")
    func projectionHash() {
        var record = ContactRecord(id: "g", source: .google, sourceIdentifier: "g", givenName: "Ann", familyName: "Lee")
        record.phones = [Labeled(label: "mobile", value: "415-555-0001")]
        let phones = SyncJournalEntry.projectionHash(of: record, fields: [.phones], noteHash: "n1")
        var other = record
        other.nickname = "Annie"
        other.id = "different"
        #expect(SyncJournalEntry.projectionHash(of: other, fields: [.phones], noteHash: "n2") == phones, "other groups, identity and the unsent note do not matter")
        other.phones = [Labeled(label: "mobile", value: "415-555-0002")]
        #expect(SyncJournalEntry.projectionHash(of: other, fields: [.phones], noteHash: "n1") != phones)
        #expect(SyncJournalEntry.projectionHash(of: record, fields: [.phones, .note], noteHash: "n1") != SyncJournalEntry.projectionHash(of: record, fields: [.phones, .note], noteHash: "n2"))
    }

    // MARK: history

    private func historyEntry(_ at: Date, _ operation: SyncHistoryEntry.Operation = .update, confirmed: Bool = true) -> SyncHistoryEntry {
        SyncHistoryEntry(
            at: at, operation: operation, icloudID: "I1", resourceName: "people/c1",
            before: GooglePerson(resourceName: "people/c1", etag: "e1", names: [GoogleName(givenName: "Ann")]),
            after: operation == .update ? GooglePerson(resourceName: "people/c1", etag: "e2", names: [GoogleName(givenName: "Anne")]) : nil,
            confirmed: confirmed
        )
    }

    private let utc = TimeZone(identifier: "UTC") ?? .current
    private let day = TimeInterval(24 * 3600)
    /// 2027-01-15 08:00:00 UTC
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("History goes to one YYYY-MM-DD.jsonl file per day, one JSON object per line, before and after intact")
    func historyFiles() throws {
        let directory = try makeDirectory().appendingPathComponent("sync-history")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = SyncHistoryStore(directory: directory, timeZone: utc)
        try store.append([historyEntry(base, confirmed: false), historyEntry(base.addingTimeInterval(60))])
        try store.append([historyEntry(base.addingTimeInterval(day), .delete)])
        try store.append([])

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["2027-01-15.jsonl", "2027-01-16.jsonl"])
        let text = try String(contentsOf: directory.appendingPathComponent("2027-01-15.jsonl"), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2 && text.hasSuffix("\n"))
        for line in text.split(separator: "\n") {
            #expect(try JSONSerialization.jsonObject(with: Data(line.utf8)) is [String: Any])
        }
        let all = try store.entries()
        #expect(all.count == 3 && all.map(\.operation) == [.update, .update, .delete])
        #expect(all[1].before?.names?.first?.givenName == "Ann" && all[1].after?.etag == "e2" && all[2].after == nil)
        #expect(all[0].confirmed == false && all[1].confirmed == true)
    }

    @Test("A day is pruned once it is entirely more than 30 days old; unrelated files are left alone")
    func historyPruning() throws {
        let directory = try makeDirectory().appendingPathComponent("sync-history")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = SyncHistoryStore(directory: directory, retentionDays: 30, timeZone: utc)
        try store.append([historyEntry(base)])
        try Data("keep".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        let lastDay = Date(timeIntervalSince1970: 1_799_971_200 + 31 * 86400 - 1) // 2027-02-15 23:59:59 UTC
        let nextDay = lastDay.addingTimeInterval(1)

        #expect(try store.prune(now: base.addingTimeInterval(30 * day)) == 0)
        #expect(try store.prune(now: lastDay) == 0, "the day is still partly inside 30 days")
        #expect(try store.entries().count == 1)
        #expect(try store.prune(now: nextDay) == 1)
        #expect(try store.entries().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["notes.txt"])
    }

    @Test("A line cut short by a crash does not hide the rest, or the line appended after it")
    func historyTornLine() throws {
        let directory = try makeDirectory().appendingPathComponent("sync-history")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = SyncHistoryStore(directory: directory, timeZone: utc)
        try store.append([historyEntry(base)])
        let url = directory.appendingPathComponent("2027-01-15.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"at":"2027-01-15T08:"#.utf8))
        try handle.close()
        #expect(try store.entries().count == 1)
        try store.append([historyEntry(base.addingTimeInterval(5))])
        #expect(try store.entries().count == 2)
    }
}
