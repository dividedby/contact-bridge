import Testing
@testable import ContactBridgeCore

struct InMemoryNotesStoreTests {
    @Test("Reads return only requested ids that have notes; writes replace or clear")
    func readWrite() async throws {
        let store = InMemoryNotesStore(notes: ["a": "one", "b": "two"])
        #expect(try await store.fetchNotes(ids: ["a", "zzz"]) == ["a": "one"])
        try await store.setNote("changed", forID: "a")
        try await store.setNote(nil, forID: "b")
        #expect(try await store.fetchNotes(ids: ["a", "b"]) == ["a": "changed"])
        #expect(store.writes.map(\.id) == ["a", "b"])
    }

    @Test("Injected errors are thrown")
    func errors() async {
        let store = InMemoryNotesStore(readError: NotesAccessError.notAuthorized, writeError: NotesAccessError.contactsAppUnavailable)
        await #expect(throws: NotesAccessError.notAuthorized) { _ = try await store.fetchNotes(ids: ["a"]) }
        await #expect(throws: NotesAccessError.contactsAppUnavailable) { try await store.setNote("x", forID: "a") }
    }
}
