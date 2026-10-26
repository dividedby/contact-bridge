import Foundation
import Testing
@testable import ContactBridgeCore

struct LinkStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_800_003_600)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func link(_ icloud: String, _ google: String) -> ImportedLink {
        ImportedLink(icloudID: icloud, googleResourceName: google)
    }

    @Test("A missing file loads as an empty, current-version table")
    func missingFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let table = try LinkStore(url: directory.appendingPathComponent("links.json")).load()
        #expect(table == LinkTable())
        #expect(table.version == 1 && table.links.isEmpty)
    }

    @Test("Links survive a reload and keep their timestamps")
    func roundTrip() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("links.json")
        try LinkStore(url: url).add([link("i1", "people/c1"), link("i2", "people/c2")], at: t0)
        let table = try LinkStore(url: url).load()
        #expect(table.links["i1"] == LinkEntry(googleResourceName: "people/c1", linkedAt: t0))
        #expect(table.links["i2"] == LinkEntry(googleResourceName: "people/c2", linkedAt: t0))
        #expect(table.icloudID(forGoogleResourceName: "people/c2") == "i2")
        #expect(table.icloudID(forGoogleResourceName: "people/nope") == nil)
    }

    @Test("The file is versioned, readable JSON: iCloud id to resource name plus an ISO-8601 timestamp")
    func fileFormat() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("links.json")
        try LinkStore(url: url).add([link("i1", "people/c1")], at: t0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let links = try #require(object["links"] as? [String: [String: Any]])
        #expect(links["i1"]?["googleResourceName"] as? String == "people/c1")
        #expect(links["i1"]?["linkedAt"] as? String == "2027-01-15T08:00:00Z")
    }

    @Test("Adding merges with what is stored; relinking an iCloud id replaces its entry")
    func addMerges() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LinkStore(url: directory.appendingPathComponent("links.json"))
        try store.add([link("i1", "people/c1"), link("i2", "people/c2")], at: t0)
        try store.add([link("i2", "people/c9"), link("i3", "people/c3")], at: t1)
        let table = try store.load()
        #expect(table.links.keys.sorted() == ["i1", "i2", "i3"])
        #expect(table.links["i1"]?.linkedAt == t0)
        #expect(table.links["i2"] == LinkEntry(googleResourceName: "people/c9", linkedAt: t1))
    }

    @Test("A Google contact linked to a new iCloud id moves off the old one")
    func googleResourceHasOneOwner() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LinkStore(url: directory.appendingPathComponent("links.json"))
        try store.add([link("i1", "people/c1")], at: t0)
        try store.add([link("i2", "people/c1")], at: t1)
        let table = try store.load()
        #expect(table.links.keys.sorted() == ["i2"])
    }

    @Test("Removing drops entries and ignores unknown ids")
    func remove() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LinkStore(url: directory.appendingPathComponent("links.json"))
        try store.add([link("i1", "people/c1"), link("i2", "people/c2")], at: t0)
        try store.remove(icloudIDs: ["i1", "zzz"])
        #expect(try store.load().links.keys.sorted() == ["i2"])
    }

    @Test("Adding nothing does not create the file")
    func addNothing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("links.json")
        try LinkStore(url: url).add([], at: t0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("The parent folder is created, and no temporary files are left beside the file")
    func atomicWrite() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("Contact Bridge", isDirectory: true)
        let url = nested.appendingPathComponent("links.json")
        let store = LinkStore(url: url)
        try store.add([link("i1", "people/c1")], at: t0)
        try store.add([link("i2", "people/c2")], at: t0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: nested.path) == ["links.json"])
    }

    @Test("A file from a newer version is refused and left untouched")
    func newerVersion() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("links.json")
        let future = Data(#"{"version": 2, "links": {}, "extra": true}"#.utf8)
        try future.write(to: url)
        let store = LinkStore(url: url)
        #expect(throws: LinkStoreError.unsupportedVersion(2)) { try store.load() }
        #expect(throws: LinkStoreError.unsupportedVersion(2)) { try store.add([link("i1", "people/c1")], at: t0) }
        #expect(try Data(contentsOf: url) == future)
    }

    @Test("A corrupt file is reported and never overwritten")
    func corruptFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("links.json")
        let garbage = Data("not json".utf8)
        try garbage.write(to: url)
        let store = LinkStore(url: url)
        #expect(throws: LinkStoreError.self) { try store.load() }
        #expect(throws: LinkStoreError.self) { try store.add([link("i1", "people/c1")], at: t0) }
        #expect(try Data(contentsOf: url) == garbage)
    }

    @Test("The default location is links.json inside Application Support/Contact Bridge")
    func defaultLocation() {
        let url = LinkStore.defaultURL
        #expect(url.lastPathComponent == "links.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Contact Bridge")
        #expect(url.path.contains("Application Support"))
    }

    @Test("The in-memory store behaves the same way")
    func inMemory() throws {
        let store = InMemoryLinkStore()
        try store.add([link("i1", "people/c1")], at: t0)
        try store.add([link("i2", "people/c1")], at: t1)
        #expect(try store.load().links.keys.sorted() == ["i2"])
        try store.remove(icloudIDs: ["i2"])
        #expect(try store.load().links.isEmpty)
    }
}
