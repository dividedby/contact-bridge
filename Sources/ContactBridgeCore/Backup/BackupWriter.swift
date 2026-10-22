import CryptoKit
import Foundation

public enum BackupError: Error, Equatable, Sendable {
    /// A written file did not read back with the hash (or record count) the manifest recorded.
    case verificationFailed(String)
    /// A paged Google listing repeated a page token or ran past the page limit.
    case pagingDidNotTerminate(String)
    /// Every candidate folder name was taken.
    case noFreeFolderName
}

/// Snapshots contacts to disk before anything is changed.
///
/// Everything is read from the stores first, then written into a temporary sibling folder, re-read and hashed, and only
/// then renamed into place. Any failure removes the temp folder and throws, so a backup folder that exists is a complete,
/// verified one. Only a successful run mints a `BackupReceipt`.
public struct BackupWriter: Sendable {
    /// `~/Library/Application Support/Contact Bridge/Backups` (inside the app's container when sandboxed).
    public static var defaultDirectory: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Contact Bridge", isDirectory: true).appendingPathComponent("Backups", isDirectory: true)
    }

    private let store: any ContactStoring
    private let google: (any GoogleContactsClient)?
    private let notes: (any NotesProvider)?
    private let baseDirectory: URL
    private let appVersion: String
    private let retention: Int
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone

    /// Test seam: runs after the files are written and before they are verified.
    var beforeVerify: (@Sendable (URL) throws -> Void)?
    /// Test seam: called after each file or directory is flushed to disk.
    var onSync: (@Sendable (URL) -> Void)?
    /// Test seam: called with the chosen destination after its name is picked and before the folder is moved there.
    var beforeMove: (@Sendable (URL) throws -> Void)?

    /// - Parameters:
    ///   - retention: how many backups to keep (at least 1; the one just made is always kept).
    ///   - timeZone: used only for the folder name.
    public init(
        store: any ContactStoring,
        google: (any GoogleContactsClient)? = nil,
        notes: (any NotesProvider)? = nil,
        baseDirectory: URL = BackupWriter.defaultDirectory,
        appVersion: String = BackupWriter.bundleVersion,
        retention: Int = 20,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.store = store
        self.google = google
        self.notes = notes
        self.baseDirectory = baseDirectory
        self.appVersion = appVersion
        self.retention = max(retention, 1)
        self.now = now
        self.timeZone = timeZone
    }

    public static var bundleVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0-dev"
    }

    // MARK: backup

    public func createBackup() async throws -> BackupReceipt {
        // Read the small sources first: a failing Google or notes call leaves no trace on disk.
        let records = try await store.fetchAll().sorted { ($0.id, $0.sourceIdentifier) < ($1.id, $1.sourceIdentifier) }
        let identifiers = records.map(\.sourceIdentifier)
        var connections: [GooglePerson]?
        var others: [GooglePerson]?
        if let google {
            connections = try await Self.allPages("google-connections") { try await google.listConnections(syncToken: nil, pageToken: $0) }
            others = try await Self.allPages("google-other") { try await google.listOtherContacts(pageToken: $0) }
        }
        let noteMap = try await notes?.fetchNotes(ids: identifiers)
        let createdAt = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))

        let fm = FileManager.default
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let temp = baseDirectory.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString)", isDirectory: true)
        let manifest: BackupManifest
        let final: URL
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: false)
            var files = [try await writeVCard(identifiers, into: temp)]
            files.append(try writeFile("icloud.json", Self.encode(records), recordCount: records.count, into: temp))
            if let connections {
                files.append(try writeFile("google-connections.json", Self.encode(connections), recordCount: connections.count, into: temp))
            }
            if let others {
                files.append(try writeFile("google-other.json", Self.encode(others), recordCount: others.count, into: temp))
            }
            if let noteMap {
                files.append(try writeFile("icloud-notes.json", Self.encode(noteMap), recordCount: noteMap.count, into: temp))
            }
            manifest = BackupManifest(
                appVersion: appVersion,
                createdAt: createdAt,
                sources: ["icloud"] + (google == nil ? [] : ["google", "googleOther"]),
                counts: BackupManifest.Counts(icloud: records.count, googleConnections: connections?.count, googleOther: others?.count),
                files: files,
                notesIncluded: noteMap != nil
            )
            _ = try writeFile("manifest.json", Self.encodeManifest(manifest), recordCount: nil, into: temp)
            try beforeVerify?(temp)
            try Self.verify(temp, manifest: manifest, expectedCards: records.count)
            try syncDirectory(temp)
            final = try moveIntoPlace(temp, createdAt: createdAt)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }

        // The backup is complete; neither durability of the parent nor pruning may turn it into a failure.
        try? syncDirectory(baseDirectory)
        prune(keeping: final)
        return BackupReceipt(id: UUID(), createdAt: createdAt, folderURL: final, manifest: manifest)
    }

    // MARK: sources

    private static let maxPages = 1000

    /// Follows page tokens to the end. A repeated token, or more than `maxPages` pages, throws instead of looping.
    private static func allPages(
        _ source: String, _ fetch: (String?) async throws -> GooglePeoplePage
    ) async throws -> [GooglePerson] {
        var people: [GooglePerson] = []
        var seen = Set<String>()
        var token: String?
        var pages = 0
        while true {
            let page = try await fetch(token)
            people += page.people
            pages += 1
            guard let next = page.nextPageToken else { return people }
            guard pages < maxPages, seen.insert(next).inserted else { throw BackupError.pagingDidNotTerminate(source) }
            token = next
        }
    }

    // MARK: files

    private static let tempPrefix = ".tmp-"
    private static let vcardMarker = Data("BEGIN:VCARD".utf8)
    private static let exportChunkSize = 200

    /// Appends to a file while hashing what was written, so nothing is held (or read back) whole just to hash it.
    private final class FileSink {
        private let handle: FileHandle
        private var hasher = SHA256()
        private(set) var bytes = 0

        init(url: URL) throws {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            handle = try FileHandle(forWritingTo: url)
        }

        func append(_ data: Data) throws {
            try handle.write(contentsOf: data)
            hasher.update(data: data)
            bytes += data.count
        }

        /// Flushes to disk and closes.
        func finish() throws -> String {
            try handle.synchronize()
            try handle.close()
            return hasher.finalize().hexString
        }

        func abort() { try? handle.close() }
    }

    private func writeFile(_ name: String, _ data: Data, recordCount: Int?, into folder: URL) throws -> BackupManifest.File {
        let url = folder.appendingPathComponent(name)
        let sink = try FileSink(url: url)
        do {
            try sink.append(data)
            let sha = try sink.finish()
            onSync?(url)
            return BackupManifest.File(name: name, sha256: sha, bytes: sink.bytes, recordCount: recordCount)
        } catch {
            sink.abort()
            throw error
        }
    }

    /// Exports the vCard `exportChunkSize` ids at a time, appending each chunk, and counts the cards written.
    private func writeVCard(_ identifiers: [String], into folder: URL) async throws -> BackupManifest.File {
        let url = folder.appendingPathComponent("icloud.vcf")
        let sink = try FileSink(url: url)
        do {
            var cards = 0
            for chunk in identifiers.chunked(into: Self.exportChunkSize) {
                let data = try await store.exportVCard(ids: chunk)
                try sink.append(data)
                cards += Self.occurrences(of: Self.vcardMarker, in: data)
            }
            let sha = try sink.finish()
            onSync?(url)
            return BackupManifest.File(name: "icloud.vcf", sha256: sha, bytes: sink.bytes, recordCount: cards)
        } catch {
            sink.abort()
            throw error
        }
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        onSync?(url)
    }

    private static func occurrences(of marker: Data, in data: Data) -> Int {
        var count = 0
        var lower = data.startIndex
        while let range = data.range(of: marker, options: [], in: lower..<data.endIndex) {
            count += 1
            lower = range.upperBound
        }
        return count
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private static func encodeManifest(_ manifest: BackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    private static func decodeManifest(_ data: Data) throws -> BackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupManifest.self, from: data)
    }

    /// Streams every file back from disk and checks hash, size, card or record count, and the manifest itself.
    private static func verify(_ folder: URL, manifest: BackupManifest, expectedCards: Int) throws {
        for file in manifest.files {
            let url = folder.appendingPathComponent(file.name)
            let isVCard = file.name == "icloud.vcf"
            guard let digest = try? digest(of: url, countingCards: isVCard), digest.bytes == file.bytes, digest.sha256 == file.sha256 else {
                throw BackupError.verificationFailed(file.name)
            }
            if isVCard {
                guard digest.cards == file.recordCount, digest.cards == expectedCards else { throw BackupError.verificationFailed(file.name) }
            } else if let expected = file.recordCount {
                let count = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                    .map { ($0 as? [Any])?.count ?? ($0 as? [String: Any])?.count }
                guard count == expected else { throw BackupError.verificationFailed(file.name) }
            }
        }
        guard let written = try? decodeManifest(Data(contentsOf: folder.appendingPathComponent("manifest.json"))), written == manifest else {
            throw BackupError.verificationFailed("manifest.json")
        }
    }

    private static func digest(of url: URL, countingCards: Bool) throws -> (sha256: String, bytes: Int, cards: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes = 0
        var cards = 0
        var tail = Data()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            bytes += chunk.count
            if countingCards {
                // The tail is shorter than the marker, so a marker is never counted twice across the seam.
                let window = tail + chunk
                cards += occurrences(of: vcardMarker, in: window)
                tail = Data(window.suffix(vcardMarker.count - 1))
            }
        }
        return (hasher.finalize().hexString, bytes, cards)
    }

    // MARK: naming and retention

    /// `2026-10-21T143205-0500`: local time, no colons.
    private func folderBaseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmssZ"
        return formatter.string(from: date)
    }

    /// Renames the finished temp folder to its final name, trying `-2`, `-3`, ... when another backup (possibly a
    /// concurrent one) already took the name. The rename itself is the arbiter, so there is no check-then-move race.
    private func moveIntoPlace(_ temp: URL, createdAt: Date) throws -> URL {
        let fm = FileManager.default
        let base = folderBaseName(for: createdAt)
        for attempt in 1...100 {
            let destination = baseDirectory.appendingPathComponent(attempt == 1 ? base : "\(base)-\(attempt)", isDirectory: true)
            if fm.fileExists(atPath: destination.path) { continue }
            do {
                try beforeMove?(destination)
                try fm.moveItem(at: temp, to: destination)
                return destination
            } catch {
                if fm.fileExists(atPath: destination.path) { continue }
                throw error
            }
        }
        throw BackupError.noFreeFolderName
    }

    /// Deletes the oldest folders that carry a valid manifest beyond the newest `retention`, and abandoned `.tmp-`
    /// folders more than a day old by file-system modification date against the real clock (the injected clock only
    /// names folders and stamps manifests). Temp folders never count as backups. Folders without a
    /// decodable manifest (anything the app did not make) and the backup just made are never touched.
    private func prune(keeping justMade: URL) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let children = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: keys) else { return }

        var backups: [(url: URL, createdAt: Date)] = []
        for url in children {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else { continue }
            if url.lastPathComponent.hasPrefix(Self.tempPrefix) {
                if let modified = values.contentModificationDate, Date().timeIntervalSince(modified) > 24 * 3600 {
                    try? fm.removeItem(at: url)
                }
                continue
            }
            guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
                  let manifest = try? Self.decodeManifest(data)
            else { continue }
            backups.append((url, manifest.createdAt))
        }
        let newestFirst = backups.sorted { ($0.createdAt, $0.url.lastPathComponent) > ($1.createdAt, $1.url.lastPathComponent) }
        for backup in newestFirst.dropFirst(retention) where backup.url.standardizedFileURL != justMade.standardizedFileURL {
            try? fm.removeItem(at: backup.url)
        }
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
