import Testing
@testable import ContactBridgeCore

struct NotesAccessProbeTests {
    @Test("A successful read means access is granted, and only a single probe id is requested")
    func authorized() async {
        let notes = InMemoryNotesStore(notes: ["1": "private"])
        #expect(await NotesAccessProbe.check(notes) == .authorized)
        #expect(notes.fetchedIDs == [[NotesAccessProbe.probeID]])
    }

    @Test("notAuthorized is reported as such, other failures as unavailable with their text")
    func failures() async {
        #expect(await NotesAccessProbe.check(InMemoryNotesStore(readError: NotesAccessError.notAuthorized)) == .notAuthorized)
        let unavailable = await NotesAccessProbe.check(InMemoryNotesStore(readError: NotesAccessError.contactsAppUnavailable))
        guard case .unavailable(let message) = unavailable else {
            Issue.record("expected unavailable")
            return
        }
        #expect(message.contains("Contacts app"))
    }
}
