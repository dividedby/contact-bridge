import Foundation
import Testing
@testable import ContactBridgeCore

struct DismissalStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dismissal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cluster(_ ids: [String]) -> DuplicateCluster {
        DuplicateCluster(
            id: ids[0], members: ids.map { ContactRecord(id: $0, source: .icloud, sourceIdentifier: $0, givenName: $0) },
            confidence: 0.9, reasons: [], flags: [], edges: [], relatedEdges: []
        )
    }

    @Test("A dismissed set hides the same cluster and any subset of it, but not a cluster that gained a member")
    func subsetRule() {
        var table = DismissalTable()
        table.dismiss(["b", "a", "c"], at: t0)
        #expect(table.isDismissed(["a", "b", "c"]))
        #expect(table.isDismissed(["a", "c"]))
        #expect(!table.isDismissed(["a", "b", "c", "d"]))
        #expect(!table.isDismissed(["a", "z"]))
        #expect(!table.isDismissed([]))
    }

    @Test("Dismissals are normalized: sorted, subsumed entries dropped, covered ones not re-added")
    func normalization() {
        var table = DismissalTable()
        table.dismiss(["b", "a"], at: t0)
        table.dismiss(["a", "b", "c"], at: t0)
        #expect(table.dismissed.map(\.memberIDs) == [["a", "b", "c"]])
        table.dismiss(["a", "c"], at: t0)
        #expect(table.dismissed.count == 1)
        table.dismiss(["x", "y"], at: t0)
        #expect(table.dismissed.map(\.memberIDs) == [["a", "b", "c"], ["x", "y"]])
        table.dismiss(["solo"], at: t0)
        #expect(table.dismissed.count == 2)
    }

    @Test("filter keeps the matcher's order and drops dismissed clusters")
    func filter() {
        var table = DismissalTable()
        table.dismiss(["a", "b"], at: t0)
        let kept = table.visible(from: [cluster(["a", "b"]), cluster(["c", "d"]), cluster(["a", "b", "e"])])
        #expect(kept.map(\.id) == ["c", "a"])
    }

    @Test("Dismissals persist as versioned JSON and can be cleared")
    func persistence() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dismissed-clusters.json")
        let store = DismissalStore(url: url)
        #expect(try store.load() == DismissalTable())
        try store.dismiss(memberIDs: ["b", "a"], at: t0)
        let reloaded = try DismissalStore(url: url).load()
        #expect(reloaded.version == 1)
        #expect(reloaded.dismissed == [DismissalTable.Entry(memberIDs: ["a", "b"], dismissedAt: t0)])
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["version"] as? Int == 1 && (object["dismissed"] as? [Any])?.count == 1)
        try store.clear()
        #expect(try store.load().dismissed.isEmpty)
    }

    @Test("A newer or corrupt file is refused and left alone")
    func refusesUnknownFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dismissed-clusters.json")
        let future = Data(#"{"version": 9, "dismissed": []}"#.utf8)
        try future.write(to: url)
        let store = DismissalStore(url: url)
        #expect(throws: DismissalStoreError.unsupportedVersion(9)) { try store.load() }
        #expect(throws: DismissalStoreError.unsupportedVersion(9)) { try store.dismiss(memberIDs: ["a", "b"], at: t0) }
        #expect(try Data(contentsOf: url) == future)
        try Data("nope".utf8).write(to: url)
        #expect(throws: DismissalStoreError.self) { try store.dismiss(memberIDs: ["a", "b"], at: t0) }
        #expect(try Data(contentsOf: url) == Data("nope".utf8))
    }

    @Test("The in-memory store behaves the same")
    func inMemory() throws {
        let store = InMemoryDismissalStore()
        try store.dismiss(memberIDs: ["a", "b"], at: t0)
        #expect(try store.load().isDismissed(["a", "b"]))
        try store.clear()
        #expect(try store.load().dismissed.isEmpty)
    }
}
