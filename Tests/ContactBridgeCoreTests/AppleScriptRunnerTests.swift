import Foundation
import Testing
@testable import ContactBridgeCore

/// Runs real NSAppleScript, but only scripts that target no application, so no Apple Event leaves the test process.
struct AppleScriptRunnerTests {
    private let runner = NSAppleScriptRunner()

    @Test("A plain script returns its result descriptor")
    func plainRun() async throws {
        let result = try await runner.run(source: "return {\"a\", 2 + 3}")
        #expect(result.numberOfItems == 2)
        #expect(result.atIndex(1)?.stringValue == "a")
        #expect(result.atIndex(2)?.int32Value == 5)
    }

    @Test("A script error carries its AppleScript error number and message")
    func errorNumber() async {
        await #expect(throws: AppleScriptError(number: -1743, message: "denied")) {
            try await runner.run(source: "error \"denied\" number -1743")
        }
    }

    @Test("A script that does not compile throws an AppleScriptError")
    func compileError() async {
        do {
            _ = try await runner.run(source: "this is ((( not applescript")
            Issue.record("expected a compile error")
        } catch let error as AppleScriptError {
            #expect(error.number != 0)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    private let echo = """
        on echo(a, b, c)
            return {a, b, c}
        end echo
        on fail(n)
            error "nope" number n
        end fail
        """

    @Test("Handler arguments arrive byte-for-byte: quotes, backslashes, newlines, unicode, empty")
    func handlerRoundTrip() async throws {
        let nasty = "say \"hi\" \\ \\\" \\n\nline\r\nTab\t ☕️ 日本語 'x' ¶"
        let values = [nasty, "", "plain"]
        let result = try await runner.call(handler: "echo", in: echo, arguments: values.map(ScriptValue.string))
        #expect(ScriptValue.strings(result) == values)
    }

    @Test("Handler names are matched case-insensitively, like AppleScript does")
    func handlerCase() async throws {
        let result = try await runner.call(handler: "setNote", in: "on setNote(a, b, c)\nreturn b\nend setNote", arguments: ["1", "2", "3"].map(ScriptValue.string))
        #expect(result.stringValue == "2")
    }

    @Test("Errors raised inside a handler keep their number")
    func handlerError() async {
        await #expect(throws: AppleScriptError(number: -600, message: "nope")) {
            try await runner.call(handler: "fail", in: echo, arguments: [NSAppleEventDescriptor(int32: -600)])
        }
    }

    @Test("Calling a handler that does not exist is an error, not a crash")
    func missingHandler() async {
        do {
            _ = try await runner.call(handler: "nonexistent", in: echo, arguments: [])
            Issue.record("expected an error")
        } catch is AppleScriptError {
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}
