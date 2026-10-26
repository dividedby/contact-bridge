import Foundation
import Testing
@testable import ContactBridgeCore

struct ContactsAppNotesProviderTests {
    private func provider(_ runner: FakeAppleScriptRunner) -> ContactsAppNotesProvider {
        ContactsAppNotesProvider(runner: runner, retryDelay: .zero)
    }

    private func bulk(_ ids: [String], _ notes: [String?]) -> Result<NSAppleEventDescriptor, AppleScriptError> {
        .success(ScriptValue.bulk(ids: ids, notes: notes))
    }

    // MARK: fetch

    @Test("Fetching runs exactly one bulk script that asks for id and note of every person")
    func oneBulkScript() async throws {
        let runner = FakeAppleScriptRunner(responses: [bulk(["A:ABPerson", "B:ABPerson"], ["x", "y"])])
        _ = try await provider(runner).fetchNotes(ids: ["A:ABPerson", "B:ABPerson"])
        #expect(runner.calls.count == 1)
        guard case .run(let source) = runner.calls[0] else { Issue.record("expected a plain script run"); return }
        #expect(source.contains("{id, note} of every person"))
        #expect(source.contains("com.apple.AddressBook"))
    }

    @Test("Notes are filtered to the requested ids; a found person without a note is empty text, an unmatched id is absent")
    func filtersAndSkipsMissing() async throws {
        let runner = FakeAppleScriptRunner(responses: [
            bulk(["A:ABPerson", "B:ABPerson", "C:ABPerson", "D:ABPerson"], ["Note A", nil, "Note C", ""]),
        ])
        let notes = try await provider(runner).fetchNotes(ids: ["A:ABPerson", "B:ABPerson", "D:ABPerson", "Z:ABPerson"])
        #expect(notes == ["A:ABPerson": "Note A", "B:ABPerson": "", "D:ABPerson": ""])
        #expect(notes["Z:ABPerson"] == nil, "not found must stay distinguishable from found without a note")
    }

    @Test("The parser accepts real AppleScript output: `missing value` as NSAppleScript returns it")
    func realMissingValueShape() async throws {
        let real = try await NSAppleScriptRunner().run(source: #"return {{"id1:ABPerson", "id2:ABPerson", "id3:ABPerson"}, {"note", missing value, ""}}"#)
        #expect(real.atIndex(2)?.atIndex(2)?.descriptorType != typeNull, "fixture check: real missing value is not typeNull")
        #expect(real.atIndex(2)?.atIndex(2)?.stringValue == nil)
        let notes = try await provider(FakeAppleScriptRunner(responses: [.success(real)])).fetchNotes(ids: ["id1:ABPerson", "id2:ABPerson", "id3:ABPerson"])
        #expect(notes == ["id1:ABPerson": "note", "id2:ABPerson": "", "id3:ABPerson": ""])
    }

    @Test("A typeNull entry also counts as a found contact with no note")
    func nullIsNoNote() async throws {
        let shape = ScriptValue.list([ScriptValue.list([ScriptValue.string("A")]), ScriptValue.list([NSAppleEventDescriptor.null()])])
        #expect(try await provider(FakeAppleScriptRunner(responses: [.success(shape)])).fetchNotes(ids: ["A"]) == ["A": ""])
    }

    @Test("Multi-line and unicode notes come back verbatim")
    func verbatim() async throws {
        let text = "line 1\r\nline \"2\" \\ ☕️ 日本語\n"
        let runner = FakeAppleScriptRunner(responses: [bulk(["A:ABPerson"], [text])])
        let notes = try await provider(runner).fetchNotes(ids: ["A:ABPerson"])
        #expect(notes["A:ABPerson"] == text)
    }

    @Test("Ids match exactly first, then on the UUID before the colon, and results are keyed by the requested id")
    func idNormalization() async throws {
        let runner = FakeAppleScriptRunner(responses: [
            bulk(["EXACT:ABPerson", "BARE-UUID", "FULL-UUID:ABPerson"], ["exact", "bare", "full"]),
        ])
        let notes = try await provider(runner).fetchNotes(ids: ["EXACT:ABPerson", "BARE-UUID:ABPerson", "FULL-UUID"])
        #expect(notes == ["EXACT:ABPerson": "exact", "BARE-UUID:ABPerson": "bare", "FULL-UUID": "full"])
    }

    @Test("An exact match wins over a same-UUID sibling")
    func exactWins() async throws {
        let runner = FakeAppleScriptRunner(responses: [bulk(["U", "U:ABPerson"], ["bare", "exact"])])
        let notes = try await provider(runner).fetchNotes(ids: ["U:ABPerson"])
        #expect(notes == ["U:ABPerson": "exact"])
    }

    @Test("Asking for no ids does not run a script")
    func noIds() async throws {
        let runner = FakeAppleScriptRunner()
        #expect(try await provider(runner).fetchNotes(ids: []).isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test("An empty address book is an empty result")
    func emptyBook() async throws {
        let runner = FakeAppleScriptRunner(responses: [bulk([], [])])
        #expect(try await provider(runner).fetchNotes(ids: ["A"]).isEmpty)
    }

    // MARK: errors

    @Test("-1743 becomes NotesAccessError.notAuthorized")
    func notAuthorized() async {
        let runner = FakeAppleScriptRunner(responses: [.failure(AppleScriptError(number: -1743, message: "not allowed"))])
        await #expect(throws: NotesAccessError.notAuthorized) { try await provider(runner).fetchNotes(ids: ["A"]) }
        #expect(runner.calls.count == 1, "authorization failures are not retried")
    }

    @Test("-600 is retried once and the retry's result is used")
    func retryOnNotRunning() async throws {
        let runner = FakeAppleScriptRunner(responses: [
            .failure(AppleScriptError(number: -600, message: "not running")), bulk(["A"], ["hi"]),
        ])
        #expect(try await provider(runner).fetchNotes(ids: ["A"]) == ["A": "hi"])
        #expect(runner.calls.count == 2)
    }

    @Test("-600 twice gives contactsAppUnavailable after exactly two attempts")
    func retryOnlyOnce() async {
        let notRunning = AppleScriptError(number: -600, message: "not running")
        let runner = FakeAppleScriptRunner(responses: [.failure(notRunning), .failure(notRunning), bulk(["A"], ["late"])])
        await #expect(throws: NotesAccessError.contactsAppUnavailable) { try await provider(runner).fetchNotes(ids: ["A"]) }
        #expect(runner.calls.count == 2)
    }

    @Test("A -600 followed by -1743 reports the authorization problem")
    func retryThenDenied() async {
        let runner = FakeAppleScriptRunner(responses: [
            .failure(AppleScriptError(number: -600, message: "")), .failure(AppleScriptError(number: -1743, message: "")),
        ])
        await #expect(throws: NotesAccessError.notAuthorized) { try await provider(runner).fetchNotes(ids: ["A"]) }
    }

    @Test("Other script errors keep their number and message")
    func otherErrors() async {
        let runner = FakeAppleScriptRunner(responses: [.failure(AppleScriptError(number: -10004, message: "privilege violation"))])
        await #expect(throws: NotesAccessError.scriptFailed(number: -10004, message: "privilege violation")) {
            try await provider(runner).fetchNotes(ids: ["A"])
        }
    }

    @Test("A result that is not two parallel lists is reported, not guessed at")
    func malformed() async {
        let shapes: [NSAppleEventDescriptor] = [
            ScriptValue.string("nope"),
            ScriptValue.list([ScriptValue.list([ScriptValue.string("A")])]),
            ScriptValue.bulk(ids: ["A", "B"], notes: ["only one"]),
            ScriptValue.list([ScriptValue.list([ScriptValue.string("A")]), ScriptValue.list([ScriptValue.list([])])]),
        ]
        for shape in shapes {
            let runner = FakeAppleScriptRunner(responses: [.success(shape)])
            do {
                _ = try await provider(runner).fetchNotes(ids: ["A"])
                Issue.record("expected unexpectedResult")
            } catch NotesAccessError.unexpectedResult {
            } catch {
                Issue.record("wrong error \(error)")
            }
        }
    }

    // MARK: write

    @Test("Writing passes the note as a handler argument and never puts it in the script source")
    func setNoteUsesHandlerCall() async throws {
        let nasty = "He said \"hi\"\\n\\\n line two\r\n\tTab ☕️ 日本語 'single' ¶"
        let runner = FakeAppleScriptRunner(responses: [.success(NSAppleEventDescriptor.null())])
        try await provider(runner).setNote(nasty, forID: "ABC-123:ABPerson")

        #expect(runner.calls.count == 1)
        guard case .call(let handler, let source, let arguments) = runner.calls[0] else { Issue.record("expected a handler call"); return }
        #expect(handler == "setNote")
        #expect(source.contains("on setNote("))
        #expect(!source.contains("ABC-123") && !source.contains("日本語") && !source.contains("line two"))
        #expect(ScriptValue.strings(ScriptValue.list(arguments)) == ["ABC-123:ABPerson", "ABC-123", nasty])
    }

    @Test("An id with no UUID part is rejected before any script runs")
    func setNoteRejectsEmptyUUID() async {
        for id in ["", ":ABPerson", ":"] {
            let runner = FakeAppleScriptRunner(responses: [.success(NSAppleEventDescriptor.null())])
            await #expect(throws: NotesAccessError.contactNotFound(id)) { try await provider(runner).setNote("x", forID: id) }
            #expect(runner.calls.isEmpty, "id \(id.debugDescription)")
        }
    }

    @Test("The handler script itself refuses an empty id or UUID part")
    func handlerGuards() throws {
        let script = ContactsAppNotesProvider.setNoteScript
        let guardRange = try #require(script.range(of: #"if pid is "" or pidUUID is "" then error"#))
        let tellRange = try #require(script.range(of: "tell application"))
        #expect(guardRange.lowerBound < tellRange.lowerBound, "the guard runs before anything is looked up")
    }

    @Test("Fetching ignores requested ids with an empty UUID part instead of matching them to anyone")
    func fetchEmptyUUID() async throws {
        let runner = FakeAppleScriptRunner(responses: [bulk(["A:ABPerson", ":ABPerson", ""], ["a", "stray", "blank"])])
        let notes = try await provider(runner).fetchNotes(ids: ["", ":ABPerson", "A:ABPerson"])
        #expect(notes == ["A:ABPerson": "a"])
    }

    @Test("A nil note clears the note with an empty string")
    func setNil() async throws {
        let runner = FakeAppleScriptRunner(responses: [.success(NSAppleEventDescriptor.null())])
        try await provider(runner).setNote(nil, forID: "X:ABPerson")
        guard case .call(_, _, let arguments) = runner.calls[0] else { Issue.record("expected a handler call"); return }
        #expect(ScriptValue.strings(ScriptValue.list(arguments)).last == .some(""))
    }

    @Test("Write errors map: -1743 not authorized, -1728 contact not found, -600 retried once")
    func setNoteErrors() async throws {
        let denied = FakeAppleScriptRunner(responses: [.failure(AppleScriptError(number: -1743, message: ""))])
        await #expect(throws: NotesAccessError.notAuthorized) { try await provider(denied).setNote("x", forID: "A") }

        let missing = FakeAppleScriptRunner(responses: [.failure(AppleScriptError(number: -1728, message: "no such person"))])
        await #expect(throws: NotesAccessError.contactNotFound("A")) { try await provider(missing).setNote("x", forID: "A") }

        let flaky = FakeAppleScriptRunner(responses: [.failure(AppleScriptError(number: -600, message: "")), .success(NSAppleEventDescriptor.null())])
        try await provider(flaky).setNote("x", forID: "A")
        #expect(flaky.calls.count == 2)
    }
}
