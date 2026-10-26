import Contacts
import CryptoKit
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import ContactBridgeCore

struct BackupWriterTests {
    // MARK: fixtures

    private final class Sandbox {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ContactBridgeBackupTests-\(UUID().uuidString)")
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }

        var entries: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
        }
    }

    private final class Clock: Sendable {
        private let value: Mutex<Date>
        let step: TimeInterval
        init(_ start: Date, step: TimeInterval = 60) {
            value = Mutex(start)
            self.step = step
        }
        func now() -> Date { value.withLock { current in defer { current += step }; return current } }
    }

    /// 2026-10-21 19:32:05 UTC.
    private let start = Date(timeIntervalSince1970: 1_792_611_125)
    private let centralDaylight = TimeZone(secondsFromGMT: -5 * 3600)!

    private func record(_ id: String, _ given: String) -> ContactRecord {
        ContactRecord(
            id: id, source: .icloud, sourceIdentifier: id, givenName: given, familyName: "Lee",
            phones: [Labeled(label: "mobile", value: "+14155552671")], emails: [Labeled(label: "home", value: "\(given.lowercased())@x.com")]
        )
    }

    private func person(_ given: String) -> GooglePerson {
        GooglePerson(names: [GoogleName(givenName: given, familyName: "G")], emailAddresses: [GoogleEmailAddress(value: "\(given)@g.com")])
    }

    private func store() -> InMemoryContactStore {
        InMemoryContactStore(records: [record("c", "Cy"), record("a", "Ann"), record("b", "Bob")])
    }

    private func google() -> FakeGoogleClient {
        FakeGoogleClient(
            people: (0..<5).map { person("P\($0)") },
            otherContacts: (0..<3).map { GooglePerson(emailAddresses: [GoogleEmailAddress(value: "o\($0)@g.com")]) },
            pageSize: 2
        )
    }

    private func writer(
        _ sandbox: Sandbox, store: any ContactStoring? = nil, google: (any GoogleContactsClient)? = nil,
        notes: (any NotesProvider)? = nil, photoFetcher: (any GooglePhotoFetching)? = nil, retention: Int = 20, clock: Clock? = nil
    ) -> BackupWriter {
        let clock = clock ?? Clock(start)
        return BackupWriter(
            store: store ?? self.store(), google: google, notes: notes, photoFetcher: photoFetcher, baseDirectory: sandbox.url,
            appVersion: "9.9.9", retention: retention, now: { clock.now() }, timeZone: centralDaylight
        )
    }

    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func manifest(in folder: URL) throws -> BackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    // MARK: happy path

    @Test("A full backup writes every file, a manifest, and returns a receipt for the folder")
    func happyPath() async throws {
        let sandbox = Sandbox()
        let receipt = try await writer(sandbox, google: google()).createBackup()
        let folder = receipt.folderURL

        #expect(folder.deletingLastPathComponent().standardizedFileURL == sandbox.url.standardizedFileURL)
        #expect(folder.lastPathComponent == "2026-10-21T143205-0500")
        #expect(sandbox.entries == ["2026-10-21T143205-0500"])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["google-connections.json", "google-other.json", "icloud.json", "icloud.vcf", "manifest.json"])

        let decoder = JSONDecoder()
        let records = try decoder.decode([ContactRecord].self, from: Data(contentsOf: folder.appendingPathComponent("icloud.json")))
        #expect(records.map(\.id) == ["a", "b", "c"])
        let vcf = String(decoding: try Data(contentsOf: folder.appendingPathComponent("icloud.vcf")), as: UTF8.self)
        #expect(vcf.components(separatedBy: "BEGIN:VCARD").count == 4)
        #expect(vcf.contains("FN:Ann Lee"))
        let connections = try decoder.decode([GooglePerson].self, from: Data(contentsOf: folder.appendingPathComponent("google-connections.json")))
        let others = try decoder.decode([GooglePerson].self, from: Data(contentsOf: folder.appendingPathComponent("google-other.json")))
        #expect(connections.count == 5 && others.count == 3)
        #expect(connections.compactMap { $0.names?.first?.givenName } == ["P0", "P1", "P2", "P3", "P4"])

        let written = try manifest(in: folder)
        #expect(written == receipt.manifest)
        #expect(written.appVersion == "9.9.9")
        #expect(written.createdAt == Date(timeIntervalSince1970: 1_792_611_125))
        #expect(written.sources == ["icloud", "google", "googleOther"])
        #expect(written.counts == BackupManifest.Counts(icloud: 3, googleConnections: 5, googleOther: 3, icloudPhotos: 0))
        #expect(written.notesIncluded == false)
        #expect(written.files.map(\.name) == ["icloud.vcf", "icloud.json", "google-connections.json", "google-other.json"])
        #expect(receipt.createdAt == written.createdAt)
        #expect(receipt.isFresh(maxAge: 3600, now: written.createdAt.addingTimeInterval(10)))
    }

    @Test("Manifest hashes and sizes match the files on disk")
    func hashes() async throws {
        let sandbox = Sandbox()
        let receipt = try await writer(sandbox, google: google()).createBackup()
        #expect(!receipt.manifest.files.isEmpty)
        for entry in receipt.manifest.files {
            let data = try Data(contentsOf: receipt.folderURL.appendingPathComponent(entry.name))
            #expect(entry.sha256 == sha256(data), "hash of \(entry.name)")
            #expect(entry.bytes == data.count)
        }
        #expect(receipt.manifest.files.first { $0.name == "icloud.json" }?.recordCount == 3)
        #expect(receipt.manifest.files.first { $0.name == "icloud.vcf" }?.recordCount == 3)
        #expect(receipt.manifest.files.first { $0.name == "google-connections.json" }?.recordCount == 5)
    }

    @Test("Without a Google client only iCloud files are written")
    func icloudOnly() async throws {
        let sandbox = Sandbox()
        let receipt = try await writer(sandbox).createBackup()
        let files = try FileManager.default.contentsOfDirectory(atPath: receipt.folderURL.path).sorted()
        #expect(files == ["icloud.json", "icloud.vcf", "manifest.json"])
        #expect(receipt.manifest.sources == ["icloud"])
        #expect(receipt.manifest.counts == BackupManifest.Counts(icloud: 3, icloudPhotos: 0))
    }

    @Test("Backups in the same second get distinct folders; names are filesystem-safe")
    func folderNames() async throws {
        let sandbox = Sandbox()
        let frozen = Clock(start, step: 0)
        let w = writer(sandbox, clock: frozen)
        let first = try await w.createBackup()
        let second = try await w.createBackup()
        #expect(first.folderURL != second.folderURL)
        #expect(second.folderURL.lastPathComponent == "2026-10-21T143205-0500-2")
        for name in sandbox.entries {
            #expect(name.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{6}[+-]\d{4}(-\d+)?/) != nil, "\(name)")
            #expect(!name.contains(":") && !name.contains("/"))
        }
    }

    @Test("The default location is Contact Bridge/Backups under Application Support")
    func defaultDirectory() {
        let path = BackupWriter.defaultDirectory.path
        #expect(path.hasSuffix("Application Support/Contact Bridge/Backups"))
    }

    // MARK: failures leave nothing behind

    private final class FlakyGoogle: GoogleContactsClient {
        let inner: FakeGoogleClient
        let failConnectionsCall: Int?
        let failOtherCall: Int?
        private let calls = Mutex((connections: 0, others: 0))

        init(_ inner: FakeGoogleClient, failConnectionsCall: Int? = nil, failOtherCall: Int? = nil) {
            self.inner = inner
            self.failConnectionsCall = failConnectionsCall
            self.failOtherCall = failOtherCall
        }

        func listConnections(syncToken: String?, pageToken: String?) async throws -> GooglePeoplePage {
            let n = calls.withLock { $0.connections += 1; return $0.connections }
            if n == failConnectionsCall { throw GoogleAPIError.rateLimited(retryAfter: 1) }
            return try await inner.listConnections(syncToken: syncToken, pageToken: pageToken)
        }

        func listOtherContacts(pageToken: String?) async throws -> GooglePeoplePage {
            let n = calls.withLock { $0.others += 1; return $0.others }
            if n == failOtherCall { throw GoogleAPIError.unauthorized }
            return try await inner.listOtherContacts(pageToken: pageToken)
        }

        func getPerson(resourceName: String) async throws -> GooglePerson { try await inner.getPerson(resourceName: resourceName) }
        func createContact(_ person: GooglePerson) async throws -> GooglePerson { try await inner.createContact(person) }
        func updateContact(resourceName: String, etag: String, person: GooglePerson, updatePersonFields: String) async throws -> GooglePerson {
            try await inner.updateContact(resourceName: resourceName, etag: etag, person: person, updatePersonFields: updatePersonFields)
        }
        func deleteContact(resourceName: String) async throws { try await inner.deleteContact(resourceName: resourceName) }
        func batchCreate(_ people: [GooglePerson]) async throws -> [GoogleBatchResult] { try await inner.batchCreate(people) }
        func batchUpdate(_ updates: [GoogleContactUpdate]) async throws -> [GoogleBatchResult] { try await inner.batchUpdate(updates) }
        func batchDelete(_ resourceNames: [String]) async throws -> [GoogleBatchResult] { try await inner.batchDelete(resourceNames) }
        func ensureGroup(named name: String) async throws -> String { try await inner.ensureGroup(named: name) }
        func addMembers(groupResourceName: String, memberResourceNames: [String]) async throws {
            try await inner.addMembers(groupResourceName: groupResourceName, memberResourceNames: memberResourceNames)
        }
    }

    @Test("A Google failure on a later connections page leaves no folder and no receipt")
    func googleFailsMidPage() async throws {
        let sandbox = Sandbox()
        let flaky = FlakyGoogle(google(), failConnectionsCall: 2)
        await #expect(throws: GoogleAPIError.rateLimited(retryAfter: 1)) { try await writer(sandbox, google: flaky).createBackup() }
        #expect(sandbox.entries.isEmpty)
    }

    @Test("A failure paging other contacts also leaves nothing behind")
    func otherContactsFail() async throws {
        let sandbox = Sandbox()
        let flaky = FlakyGoogle(google(), failOtherCall: 2)
        await #expect(throws: GoogleAPIError.unauthorized) { try await writer(sandbox, google: flaky).createBackup() }
        #expect(sandbox.entries.isEmpty)
    }

    @Test("A store failure leaves nothing behind")
    func storeFails() async throws {
        let sandbox = Sandbox()
        let denied = InMemoryContactStore(records: [record("a", "Ann")], authorization: .denied)
        await #expect(throws: ContactStoreError.accessDenied) { try await writer(sandbox, store: denied).createBackup() }
        #expect(sandbox.entries.isEmpty)
    }

    @Test("A file that does not verify removes the temp folder and throws; no folder, no receipt")
    func verificationFailure() async throws {
        let sandbox = Sandbox()
        var failing = writer(sandbox, google: google())
        failing.beforeVerify = { folder in try Data("tampered".utf8).write(to: folder.appendingPathComponent("icloud.json")) }
        await #expect(throws: BackupError.verificationFailed("icloud.json")) { try await failing.createBackup() }
        #expect(sandbox.entries.isEmpty)
    }

    @Test("Notes provider failures abort the backup cleanly")
    func notesFail() async throws {
        struct Boom: Error {}
        struct Failing: NotesProvider {
            func fetchNotes(ids: [String]) async throws -> [String: String] { throw Boom() }
        }
        let sandbox = Sandbox()
        await #expect(throws: Boom.self) { try await writer(sandbox, notes: Failing()).createBackup() }
        #expect(sandbox.entries.isEmpty)
    }

    // MARK: retention

    @Test("Retention keeps the newest N valid backups and leaves unknown folders alone")
    func retention() async throws {
        let sandbox = Sandbox()
        let fm = FileManager.default
        let unknown = sandbox.url.appendingPathComponent("my-own-notes")
        try fm.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: unknown.appendingPathComponent("readme.txt"))
        let broken = sandbox.url.appendingPathComponent("1999-01-01T000000+0000")
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("manifest.json"))
        let stray = sandbox.url.appendingPathComponent("stray-file.txt")
        try Data("x".utf8).write(to: stray)

        let clock = Clock(start)
        let w = writer(sandbox, retention: 3, clock: clock)
        var receipts: [BackupReceipt] = []
        for _ in 0..<5 { receipts.append(try await w.createBackup()) }

        let remaining = sandbox.entries
        let kept = receipts.suffix(3).map(\.folderURL.lastPathComponent)
        #expect(Set(remaining) == Set(kept + ["my-own-notes", "1999-01-01T000000+0000", "stray-file.txt"]))
        #expect(!fm.fileExists(atPath: receipts[0].folderURL.path) && !fm.fileExists(atPath: receipts[1].folderURL.path))
        #expect(fm.fileExists(atPath: unknown.appendingPathComponent("readme.txt").path))
    }

    @Test("The backup just made is never pruned, even with a retention of zero")
    func retentionNeverPrunesNewest() async throws {
        let sandbox = Sandbox()
        let w = writer(sandbox, retention: 0)
        _ = try await w.createBackup()
        let latest = try await w.createBackup()
        #expect(sandbox.entries == [latest.folderURL.lastPathComponent])
    }

    @Test("Retention orders by manifest time, not folder name, and still protects the one just made")
    func retentionOrdering() async throws {
        let sandbox = Sandbox()
        // A clock running backwards: each later backup is older, so the first ones are the newest by manifest time.
        let w = writer(sandbox, retention: 2, clock: Clock(start, step: -3600))
        var receipts: [BackupReceipt] = []
        for _ in 0..<4 { receipts.append(try await w.createBackup()) }
        let remaining = Set(sandbox.entries)
        #expect(remaining == Set([0, 1, 3].map { receipts[$0].folderURL.lastPathComponent }))
    }

    // MARK: notes hook

    private final class StubNotes: NotesProvider {
        let notes: [String: String]
        let seen: Mutex<[String]> = Mutex([])
        init(notes: [String: String]) { self.notes = notes }
        func fetchNotes(ids: [String]) async throws -> [String: String] {
            seen.withLock { $0 = ids }
            return notes
        }
    }

    @Test("A notes provider's notes are written to icloud-notes.json and recorded in the manifest")
    func notesHook() async throws {
        let sandbox = Sandbox()
        let provider = StubNotes(notes: ["a": "Allergic to nuts", "c": "Met at conference"])
        let receipt = try await writer(sandbox, notes: provider).createBackup()

        let data = try Data(contentsOf: receipt.folderURL.appendingPathComponent("icloud-notes.json"))
        #expect(try JSONDecoder().decode([String: String].self, from: data) == ["a": "Allergic to nuts", "c": "Met at conference"])
        #expect(provider.seen.withLock { $0 } == ["a", "b", "c"])
        #expect(receipt.manifest.notesIncluded)
        let entry = try #require(receipt.manifest.files.first { $0.name == "icloud-notes.json" })
        #expect(entry.sha256 == sha256(data) && entry.recordCount == 2)
    }

    @Test("A notes authorization failure (-1743) surfaces as NotesAccessError.notAuthorized and leaves no backup behind")
    func notesNotAuthorized() async throws {
        let sandbox = Sandbox()
        let runner = FakeAppleScriptRunner(responses: [.failure(AppleScriptError(number: -1743, message: "Not authorized to send Apple events to Contacts."))])
        let provider = ContactsAppNotesProvider(runner: runner, retryDelay: .zero)
        await #expect(throws: NotesAccessError.notAuthorized) { try await writer(sandbox, notes: provider).createBackup() }
        #expect(sandbox.entries.isEmpty)
    }

    @Test("A real provider's notes are written to icloud-notes.json keyed by contact identifier")
    func providerEndToEnd() async throws {
        let sandbox = Sandbox()
        let runner = FakeAppleScriptRunner(responses: [.success(ScriptValue.bulk(ids: ["a", "b", "zzz"], notes: ["Note A", nil, "Not ours"]))])
        let provider = ContactsAppNotesProvider(runner: runner, retryDelay: .zero)
        let receipt = try await writer(sandbox, notes: provider).createBackup()
        let data = try Data(contentsOf: receipt.folderURL.appendingPathComponent("icloud-notes.json"))
        #expect(try JSONDecoder().decode([String: String].self, from: data) == ["a": "Note A"])
        #expect(receipt.manifest.notesIncluded)
    }

    @Test("Without a provider there is no notes file")
    func noNotes() async throws {
        let sandbox = Sandbox()
        let receipt = try await writer(sandbox).createBackup()
        #expect(!FileManager.default.fileExists(atPath: receipt.folderURL.appendingPathComponent("icloud-notes.json").path))
        #expect(receipt.manifest.notesIncluded == false)
    }

    // MARK: receipt freshness

    @Test("Receipts are fresh for an hour by default and for the given age otherwise")
    func freshness() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let receipt = BackupReceipt.forTesting(createdAt: created)
        #expect(receipt.isFresh(now: created.addingTimeInterval(3599)))
        #expect(!receipt.isFresh(now: created.addingTimeInterval(3601)))
        #expect(receipt.isFresh(maxAge: 7200, now: created.addingTimeInterval(7199)))
        #expect(!receipt.isFresh(maxAge: 60, now: created.addingTimeInterval(61)))
        #expect(receipt.isFresh(maxAge: 60, now: created))
    }

    // MARK: temp folders

    private func setModified(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func encodeManifest(_ manifest: BackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    @Test("An abandoned .tmp- folder with a newer valid manifest is never counted as a backup")
    func tmpFolderIsNotABackup() async throws {
        let sandbox = Sandbox()
        let w = writer(sandbox, retention: 3)
        var receipts: [BackupReceipt] = []
        for _ in 0..<3 { receipts.append(try await w.createBackup()) }

        var crashedManifest = receipts[2].manifest
        crashedManifest.createdAt = start.addingTimeInterval(86400)
        let crashed = sandbox.url.appendingPathComponent(".tmp-crashed")
        try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
        try encodeManifest(crashedManifest).write(to: crashed.appendingPathComponent("manifest.json"))
        try setModified(crashed, to: Date())

        receipts.append(try await w.createBackup())
        let real = sandbox.entries.filter { !$0.hasPrefix(".tmp-") }
        #expect(Set(real) == Set(receipts.suffix(3).map(\.folderURL.lastPathComponent)))
        #expect(real.count == 3)
        #expect(sandbox.entries.contains(".tmp-crashed"))
    }

    @Test("Temp folders older than a day are removed; younger ones and unknown folders stay")
    func staleTmpFolders() async throws {
        let sandbox = Sandbox()
        let fm = FileManager.default
        func folder(_ name: String, age: TimeInterval) throws {
            let url = sandbox.url.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("partial.vcf"))
            try setModified(url, to: Date().addingTimeInterval(-age))
        }
        try folder(".tmp-old", age: 25 * 3600)
        try folder(".tmp-older", age: 30 * 24 * 3600)
        try folder(".tmp-young", age: 3600)
        try folder(".tmp-edge", age: 23 * 3600)
        try folder("my-own-folder", age: 90 * 24 * 3600)

        _ = try await writer(sandbox).createBackup()
        let names = Set(sandbox.entries)
        #expect(!names.contains(".tmp-old") && !names.contains(".tmp-older"))
        #expect(names.contains(".tmp-young") && names.contains(".tmp-edge") && names.contains("my-own-folder"))
    }

    @Test("Temp-folder age is judged against the real clock, not the injected one")
    func tmpAgeUsesRealClock() async throws {
        let sandbox = Sandbox()
        let live = sandbox.url.appendingPathComponent(".tmp-LIVE")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try Data("in progress".utf8).write(to: live.appendingPathComponent("partial.vcf"))
        try setModified(live, to: Date())

        let threeDaysAhead = Clock(Date().addingTimeInterval(3 * 86400))
        _ = try await writer(sandbox, clock: threeDaysAhead).createBackup()
        #expect(sandbox.entries.contains(".tmp-LIVE"))
    }

    // MARK: concurrency

    private final class Once: Sendable {
        private let fired = Mutex(false)
        func first() -> Bool { fired.withLock { already in defer { already = true }; return !already } }
    }

    @Test("A name taken between choosing it and moving into it falls through to the next suffix")
    func collisionAfterChoosingName() async throws {
        let sandbox = Sandbox()
        let once = Once()
        var colliding = writer(sandbox, clock: Clock(start, step: 0))
        colliding.beforeMove = { destination in
            guard once.first() else { return }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("someone else's backup".utf8).write(to: destination.appendingPathComponent("manifest.json"))
        }
        let receipt = try await colliding.createBackup()
        #expect(receipt.folderURL.lastPathComponent == "2026-10-21T143205-0500-2")
        #expect(sandbox.entries.sorted() == ["2026-10-21T143205-0500", "2026-10-21T143205-0500-2"])
        let intruder = sandbox.url.appendingPathComponent("2026-10-21T143205-0500/manifest.json")
        #expect(try String(contentsOf: intruder, encoding: .utf8) == "someone else's backup")
        #expect(FileManager.default.fileExists(atPath: receipt.folderURL.appendingPathComponent("icloud.json").path))
    }

    @Test("Concurrent backups in the same second all succeed with distinct folders (smoke test)")
    func concurrentBackupsSmoke() async throws {
        let sandbox = Sandbox()
        let w = writer(sandbox, clock: Clock(start, step: 0))
        let receipts = try await withThrowingTaskGroup(of: BackupReceipt.self) { group in
            for _ in 0..<8 { group.addTask { try await w.createBackup() } }
            var all: [BackupReceipt] = []
            for try await receipt in group { all.append(receipt) }
            return all
        }
        #expect(receipts.count == 8)
        #expect(Set(receipts.map(\.folderURL.lastPathComponent)).count == 8)
        #expect(sandbox.entries.count == 8)
        for entry in sandbox.entries { #expect(entry.hasPrefix("2026-10-21T143205-0500"), "\(entry)") }
        for receipt in receipts { #expect(FileManager.default.fileExists(atPath: receipt.folderURL.appendingPathComponent("manifest.json").path)) }
    }

    // MARK: vCard hardening

    private final class SpyStore: ContactStoring {
        let inner: InMemoryContactStore
        let dropLastCard: Bool
        let sizes = Mutex<[Int]>([])
        init(_ inner: InMemoryContactStore, dropLastCard: Bool = false) {
            self.inner = inner
            self.dropLastCard = dropLastCard
        }
        func authorizationStatus() async -> ContactAuthorization { await inner.authorizationStatus() }
        func requestAccess() async throws -> ContactAuthorization { try await inner.requestAccess() }
        func fetchAll() async throws -> [ContactRecord] { try await inner.fetchAll() }
        func create(_ record: ContactRecord, backup: BackupReceipt) async throws -> ContactRecord { try await inner.create(record, backup: backup) }
        func update(_ record: ContactRecord, backup: BackupReceipt) async throws { try await inner.update(record, backup: backup) }
        func merge(survivor: ContactRecord, absorbing ids: [String], backup: BackupReceipt) async throws {
            try await inner.merge(survivor: survivor, absorbing: ids, backup: backup)
        }
        func delete(ids: [String], backup: BackupReceipt) async throws { try await inner.delete(ids: ids, backup: backup) }
        func exportVCard(ids: [String]) async throws -> Data {
            sizes.withLock { $0.append(ids.count) }
            return try await inner.exportVCard(ids: dropLastCard ? Array(ids.dropLast()) : ids)
        }
        func changes() -> AsyncStream<Void> { inner.changes() }
    }

    private func bigStore(_ count: Int) -> InMemoryContactStore {
        InMemoryContactStore(records: (0..<count).map { record(String(format: "id%04d", $0), "N\($0)") })
    }

    @Test("The vCard is exported in chunks of 200 ids and the card count is recorded")
    func chunkedExport() async throws {
        let sandbox = Sandbox()
        let spy = SpyStore(bigStore(450))
        let receipt = try await writer(sandbox, store: spy).createBackup()
        #expect(spy.sizes.withLock { $0 } == [200, 200, 50])
        let vcf = try String(contentsOf: receipt.folderURL.appendingPathComponent("icloud.vcf"), encoding: .utf8)
        #expect(vcf.components(separatedBy: "BEGIN:VCARD").count == 451)
        #expect(receipt.manifest.files.first { $0.name == "icloud.vcf" }?.recordCount == 450)
        #expect(receipt.manifest.counts.icloud == 450)
        for entry in receipt.manifest.files {
            let data = try Data(contentsOf: receipt.folderURL.appendingPathComponent(entry.name))
            #expect(entry.sha256 == sha256(data) && entry.bytes == data.count, "\(entry.name)")
        }
    }

    @Test("A vCard with fewer cards than records fails verification and leaves nothing behind")
    func vcardCountMismatch() async throws {
        let sandbox = Sandbox()
        let spy = SpyStore(bigStore(5), dropLastCard: true)
        await #expect(throws: BackupError.verificationFailed("icloud.vcf")) { try await writer(sandbox, store: spy).createBackup() }
        #expect(sandbox.entries.isEmpty)
    }

    @Test("Tampering with the card count after writing is caught by verification")
    func vcardTamper() async throws {
        let sandbox = Sandbox()
        var tampering = writer(sandbox)
        tampering.beforeVerify = { folder in
            let url = folder.appendingPathComponent("icloud.vcf")
            let text = try String(contentsOf: url, encoding: .utf8)
            try text.replacing("BEGIN:VCARD", with: "BEGIN:VCARX").write(to: url, atomically: false, encoding: .utf8)
        }
        await #expect(throws: BackupError.verificationFailed("icloud.vcf")) { try await tampering.createBackup() }
        #expect(sandbox.entries.isEmpty)
    }

    // MARK: durability

    private final class SyncLog: Sendable {
        let urls = Mutex<[URL]>([])
        func record(_ url: URL) { urls.withLock { $0.append(url) } }
    }

    @Test("Every file and the temp directory are flushed to disk before the rename")
    func syncsBeforeRename() async throws {
        let sandbox = Sandbox()
        let log = SyncLog()
        var syncing = writer(sandbox, google: google())
        syncing.onSync = { log.record($0) }
        let receipt = try await syncing.createBackup()

        let synced = log.urls.withLock { $0 }
        let beforeRename = synced.filter { ($0.hasDirectoryPath ? $0 : $0.deletingLastPathComponent()).lastPathComponent.hasPrefix(".tmp-") }
        let fileNames = beforeRename.filter { !$0.hasDirectoryPath }.map(\.lastPathComponent)
        #expect(Set(fileNames) == Set(receipt.manifest.files.map(\.name) + ["manifest.json"]))
        let directoryIndex = try #require(beforeRename.firstIndex { $0.lastPathComponent.hasPrefix(".tmp-") })
        #expect(directoryIndex == beforeRename.count - 1, "the directory is synced after every file")
    }

    // MARK: paging guard

    private final class PagingStub: GoogleContactsClient {
        let inner = FakeGoogleClient()
        let connectionToken: @Sendable (Int) -> String?
        let otherToken: @Sendable (Int) -> String?
        let connectionCalls = Mutex(0)

        init(connectionToken: @escaping @Sendable (Int) -> String? = { _ in nil }, otherToken: @escaping @Sendable (Int) -> String? = { _ in nil }) {
            self.connectionToken = connectionToken
            self.otherToken = otherToken
        }

        func listConnections(syncToken: String?, pageToken: String?) async throws -> GooglePeoplePage {
            let n = connectionCalls.withLock { $0 += 1; return $0 }
            return GooglePeoplePage(people: [], nextPageToken: connectionToken(n))
        }
        func listOtherContacts(pageToken: String?) async throws -> GooglePeoplePage {
            let n = pageToken.flatMap { Int($0.dropFirst()) } ?? 0
            return GooglePeoplePage(people: [], nextPageToken: otherToken(n + 1))
        }
        func getPerson(resourceName: String) async throws -> GooglePerson { try await inner.getPerson(resourceName: resourceName) }
        func createContact(_ person: GooglePerson) async throws -> GooglePerson { try await inner.createContact(person) }
        func updateContact(resourceName: String, etag: String, person: GooglePerson, updatePersonFields: String) async throws -> GooglePerson {
            try await inner.updateContact(resourceName: resourceName, etag: etag, person: person, updatePersonFields: updatePersonFields)
        }
        func deleteContact(resourceName: String) async throws { try await inner.deleteContact(resourceName: resourceName) }
        func batchCreate(_ people: [GooglePerson]) async throws -> [GoogleBatchResult] { try await inner.batchCreate(people) }
        func batchUpdate(_ updates: [GoogleContactUpdate]) async throws -> [GoogleBatchResult] { try await inner.batchUpdate(updates) }
        func batchDelete(_ resourceNames: [String]) async throws -> [GoogleBatchResult] { try await inner.batchDelete(resourceNames) }
        func ensureGroup(named name: String) async throws -> String { try await inner.ensureGroup(named: name) }
        func addMembers(groupResourceName: String, memberResourceNames: [String]) async throws {
            try await inner.addMembers(groupResourceName: groupResourceName, memberResourceNames: memberResourceNames)
        }
    }

    @Test("A repeated page token throws instead of looping, and leaves nothing behind")
    func pagingCycle() async throws {
        let sandbox = Sandbox()
        let stub = PagingStub(connectionToken: { _ in "same" })
        await #expect(throws: BackupError.pagingDidNotTerminate("google-connections")) { try await writer(sandbox, google: stub).createBackup() }
        #expect(sandbox.entries.isEmpty)
        let others = PagingStub(otherToken: { _ in "same" })
        await #expect(throws: BackupError.pagingDidNotTerminate("google-other")) { try await writer(sandbox, google: others).createBackup() }
        #expect(sandbox.entries.isEmpty)
    }

    @Test("More than 1,000 pages throws; exactly 1,000 is fine")
    func pagingLimit() async throws {
        let sandbox = Sandbox()
        let endless = PagingStub(connectionToken: { "t\($0)" })
        await #expect(throws: BackupError.pagingDidNotTerminate("google-connections")) { try await writer(sandbox, google: endless).createBackup() }
        #expect(endless.connectionCalls.withLock { $0 } == 1000)
        #expect(sandbox.entries.isEmpty)

        let exact = PagingStub(connectionToken: { $0 < 1000 ? "t\($0)" : nil })
        _ = try await writer(sandbox, google: exact).createBackup()
        #expect(exact.connectionCalls.withLock { $0 } == 1000)
    }

    // MARK: photos

    @Test("iCloud photos are in icloud.vcf and counted in the manifest")
    func icloudPhotos() async throws {
        let sandbox = Sandbox()
        let picture = PhotoPictures.picture(1)
        let store = InMemoryContactStore(records: [record("c", "Cy"), record("a", "Ann"), record("b", "Bob")], photos: ["a": picture])
        let receipt = try await writer(sandbox, store: store).createBackup()
        let vcf = String(decoding: try Data(contentsOf: receipt.folderURL.appendingPathComponent("icloud.vcf")), as: UTF8.self)
        #expect(vcf.contains("PHOTO;ENCODING=b;TYPE=JPEG:\(picture.base64EncodedString())"))
        #expect(receipt.manifest.counts.icloudPhotos == 1)
    }

    @Test("A photo added to Apple's vCard export reads back through Apple's import, card by card")
    func appleExportCarriesPhoto() throws {
        let ann = CNMutableContact(), bob = CNMutableContact()
        ann.givenName = "Ann"
        bob.givenName = "Bob"
        let picture = PhotoPictures.picture(2)
        let exported = VCardWriter.addingPhotos([nil, picture], to: try CNContactVCardSerialization.data(with: [ann, bob]))
        let back = try CNContactVCardSerialization.contacts(with: exported)
        #expect(back.map(\.givenName) == ["Ann", "Bob"])
        #expect(back[0].imageData == nil && back[1].imageData != nil)
        #expect(String(decoding: exported, as: UTF8.self).components(separatedBy: "\n").allSatisfy { $0.utf8.count <= 76 }, "folded")
        #expect(VCardWriter.addingPhotos([picture, nil], to: exported) != exported, "a card without one gets it")
        #expect(VCardWriter.addingPhotos([nil, picture], to: exported) == exported, "a card that has one keeps it")
    }

    @Test("Google contacts' own photos are saved full size with an index; a failed download is listed, not fatal")
    func googlePhotos() async throws {
        let sandbox = Sandbox()
        let google = google()
        let one = PhotoPictures.picture(3), two = try #require(PhotoTestImages.encode(PhotoTestImages.scene(seed: 4), as: .png))
        try await google.setContactPhoto(one, for: "people/c1")
        try await google.setContactPhoto(two, for: "people/c2")
        let unreachable = try await google.setContactPhoto(PhotoPictures.picture(5), for: "people/c3")
        try await google.setProfilePhoto(PhotoPictures.picture(6), for: "people/c4")
        let fetcher = FakeGooglePhotoFetcher(client: google)
        let failing = FailingFetcher(inner: fetcher, key: try #require(GooglePersonMapper.photos(of: unreachable).contact?.key))
        let receipt = try await writer(sandbox, google: google, photoFetcher: failing).createBackup()
        let folder = receipt.folderURL

        let index = try JSONDecoder().decode([BackupWriter.GooglePhotoEntry].self, from: Data(contentsOf: folder.appendingPathComponent("google-photos.json")))
        #expect(index.map(\.resourceName) == ["people/c1", "people/c2", "people/c3"], "the profile photo is not the contact's own")
        #expect(index.map(\.file) == ["google-photos/c1.jpg", "google-photos/c2.png", nil])
        #expect(index[2].error != nil && index[0].error == nil)
        #expect(try Data(contentsOf: folder.appendingPathComponent("google-photos/c1.jpg")) == one)
        #expect(try Data(contentsOf: folder.appendingPathComponent("google-photos/c2.png")) == two)
        #expect(await fetcher.requested.allSatisfy { $0.absoluteString.hasSuffix("=s0") }, "full size")
        #expect(receipt.manifest.counts.googlePhotos == 2)
        #expect(receipt.manifest.files.filter { $0.name.hasPrefix("google-photos/") }.count == 2)
        #expect(receipt.manifest.files.contains { $0.name == "google-photos.json" && $0.recordCount == 3 })
    }

    private struct FailingFetcher: GooglePhotoFetching {
        let inner: FakeGooglePhotoFetcher
        let key: String
        func fetch(_ url: URL) async throws -> Data {
            if GooglePersonMapper.photoKey(ofURL: url.absoluteString) == key { throw GooglePhotoError.http(503) }
            return try await inner.fetch(url)
        }
    }
}
