import Testing
@testable import ContactBridgeCore

struct InMemoryNotesStoreTests {
    @Test("Reads give every requested id its note, or empty text when it has none; writes replace or clear")
    func readWrite() async throws {
        let store = InMemoryNotesStore(notes: ["a": "one", "b": "two"])
        #expect(try await store.fetchNotes(ids: ["a", "zzz"]) == ["a": "one", "zzz": ""])
        try await store.setNote("changed", forID: "a")
        try await store.setNote(nil, forID: "b")
        #expect(try await store.fetchNotes(ids: ["a", "b"]) == ["a": "changed", "b": ""])
        #expect(store.writes.map(\.id) == ["a", "b"])
    }

    @Test("Unmatched ids are left out of the result, like ids the Contacts app did not return")
    func unmatched() async throws {
        let store = InMemoryNotesStore(notes: ["a": "one"], unmatchedIDs: ["b"])
        #expect(try await store.fetchNotes(ids: ["a", "b", "c"]) == ["a": "one", "c": ""])
        store.setUnmatched([])
        #expect(try await store.fetchNotes(ids: ["b"]) == ["b": ""])
    }

    @Test("Injected errors are thrown")
    func errors() async {
        let store = InMemoryNotesStore(readError: NotesAccessError.notAuthorized, writeError: NotesAccessError.contactsAppUnavailable)
        await #expect(throws: NotesAccessError.notAuthorized) { _ = try await store.fetchNotes(ids: ["a"]) }
        await #expect(throws: NotesAccessError.contactsAppUnavailable) { try await store.setNote("x", forID: "a") }
    }
}
