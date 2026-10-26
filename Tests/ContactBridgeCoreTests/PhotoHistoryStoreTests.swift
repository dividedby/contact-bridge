import Foundation
import Testing
@testable import ContactBridgeCore

struct PhotoHistoryStoreTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("photo-history-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func entry(_ id: String, at date: Date, _ operation: PhotoHistoryEntry.Operation = .replace) -> PhotoHistoryEntry {
        PhotoHistoryEntry(at: date, operation: operation, icloudID: id, resourceName: "people/c1", urlKey: "https://lh3.googleusercontent.com/k", photo: Data([1, 2, 3, 4]))
    }

    private func day(_ offset: Int) -> Date { SyncFixtures.t0.addingTimeInterval(Double(offset) * 86400) }

    @Test("Entries are kept per day in jsonl files, with the photo bytes, and read back oldest first")
    func roundTrip() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PhotoHistoryStore(directory: folder, timeZone: utc)
        try store.append([entry("I2", at: day(1)), entry("I1", at: day(0), .delete)])
        try store.append([entry("I3", at: day(1).addingTimeInterval(60))])

        let entries = try store.entries()
        #expect(entries.map(\.icloudID) == ["I1", "I2", "I3"] && entries[0].operation == .delete && entries[0].photo == Data([1, 2, 3, 4]))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files.count == 2 && files.allSatisfy { $0.hasSuffix(".jsonl") })
    }

    @Test("Days older than 30 days are pruned, the newer ones are kept")
    func retention() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PhotoHistoryStore(directory: folder, timeZone: utc)
        try store.append([entry("old", at: day(0)), entry("recent", at: day(20))])

        #expect(try store.prune(now: day(30)) == 0, "thirty days later the oldest day is still within the retention")
        #expect(try store.prune(now: day(32)) == 1)
        #expect(try store.entries().map(\.icloudID) == ["recent"])
    }

    @Test("A line cut short by a crash is skipped, and the next entry still lands on its own line")
    func truncatedLine() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PhotoHistoryStore(directory: folder, timeZone: utc)
        try store.append([entry("I1", at: day(0))])
        let file = try #require(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"at\":".utf8))
        try handle.close()
        try store.append([entry("I2", at: day(0))])

        #expect(try store.entries().map(\.icloudID) == ["I1", "I2"])
    }

    @Test("The in-memory store behaves the same")
    func inMemory() throws {
        let store = InMemoryPhotoHistoryStore()
        try store.append([entry("old", at: day(0)), entry("recent", at: day(40))])
        #expect(try store.prune(now: day(45)) == 1 && store.entries().map(\.icloudID) == ["recent"])
    }
}
