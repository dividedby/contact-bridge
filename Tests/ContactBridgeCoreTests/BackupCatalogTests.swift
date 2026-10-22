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

    @Test("Moving a backup to the Trash hands exactly its folder to the trasher and it leaves the list")
    func trashesBackup() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InMemoryContactStore(records: [ContactRecord(id: "1", source: .icloud, sourceIdentifier: "1", givenName: "Ann")])
        let clock = Clock()
        let writer = BackupWriter(store: store, baseDirectory: directory, now: { clock.next() })
        _ = try await writer.createBackup()
        _ = try await writer.createBackup()
        let entries = BackupCatalog.list(in: directory)
        let trashed = Trashed()
        // Resolve before the folder is gone: symlink resolution needs the path to exist (/var → /private/var).
        let expected = entries[1].folderURL.resolvingSymlinksInPath().path

        try BackupCatalog.moveToTrash(entries[1], in: directory, trash: { url in
            trashed.urls.append(url)
            try FileManager.default.removeItem(at: url)
        })

        #expect(trashed.urls.map(\.path) == [expected])
        #expect(BackupCatalog.list(in: directory).map(\.id) == [entries[0].id])
    }

    @Test("Refuses anything that is not a backup folder directly inside the backups directory")
    func refusesNonBackups() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InMemoryContactStore(records: [ContactRecord(id: "1", source: .icloud, sourceIdentifier: "1", givenName: "Ann")])
        let receipt = try await BackupWriter(store: store, baseDirectory: directory).createBackup()
        let real = try #require(BackupCatalog.list(in: directory).first)
        let neverCalled: @Sendable (URL) throws -> Void = { _ in Issue.record("trash must not be called") }

        let stray = directory.appendingPathComponent("stray-folder")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        var noManifest = real
        noManifest.folderURL = stray
        #expect(throws: BackupCatalogError.notABackup) { try BackupCatalog.moveToTrash(noManifest, in: directory, trash: neverCalled) }

        let elsewhere = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let copy = elsewhere.appendingPathComponent(receipt.folderURL.lastPathComponent)
        try FileManager.default.copyItem(at: receipt.folderURL, to: copy)
        var outside = real
        outside.folderURL = copy
        #expect(throws: BackupCatalogError.notABackup) { try BackupCatalog.moveToTrash(outside, in: directory, trash: neverCalled) }

        var escaping = real
        escaping.folderURL = directory.appendingPathComponent("..").appendingPathComponent(elsewhere.lastPathComponent)
        #expect(throws: BackupCatalogError.notABackup) { try BackupCatalog.moveToTrash(escaping, in: directory, trash: neverCalled) }

        #expect(BackupCatalog.list(in: directory).count == 1)
    }

    private final class Trashed: @unchecked Sendable {
        var urls: [URL] = []
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds = 1_800_000_000.0
        func next() -> Date { lock.withLock { seconds += 60; return Date(timeIntervalSince1970: seconds) } }
    }
}
