import Foundation
import Testing
@testable import ContactBridgeCore

struct BackupCatalogTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Lists real backups newest first with counts and the notes flag; ignores everything else")
    func listsBackups() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InMemoryContactStore(records: [ContactRecord(id: "1", source: .icloud, sourceIdentifier: "1", givenName: "Ann")])
        let notes = InMemoryNotesStore(notes: ["1": "hello"])
        let clock = Clock()
        let withNotes = BackupWriter(store: store, notes: notes, baseDirectory: directory, now: { clock.next() })
        let without = BackupWriter(store: store, baseDirectory: directory, now: { clock.next() })
        let first = try await without.createBackup()
        let second = try await withNotes.createBackup()

        try FileManager.default.createDirectory(at: directory.appendingPathComponent("stray-folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".tmp-abandoned"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent("loose-file.txt"))

        let entries = BackupCatalog.list(in: directory)
        #expect(entries.map(\.folderURL.lastPathComponent) == [second.folderURL.lastPathComponent, first.folderURL.lastPathComponent])
        #expect(entries[0].notesIncluded && !entries[1].notesIncluded)
        #expect(entries[0].counts.icloud == 1 && entries[0].counts.googleConnections == nil)
        #expect(entries[0].createdAt == second.createdAt)
        #expect(entries.allSatisfy { $0.id == $0.folderURL.lastPathComponent })
    }

    @Test("A missing folder lists as empty")
    func missingFolder() {
        #expect(BackupCatalog.list(in: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).isEmpty)
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds = 1_800_000_000.0
        func next() -> Date { lock.withLock { seconds += 60; return Date(timeIntervalSince1970: seconds) } }
    }
}
