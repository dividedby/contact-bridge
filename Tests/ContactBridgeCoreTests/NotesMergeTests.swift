import Testing
@testable import ContactBridgeCore

struct NotesMergeTests {
    private func combine(_ survivor: String?, _ others: [String?]) -> String? {
        NotesMerge.combine(survivor: survivor, others: others.enumerated().map { (id: "d\($0.offset)", note: $0.element) })
    }

    @Test("Survivor's note comes first, then each other note after a blank line, in order")
    func order() {
        #expect(combine("Mine", ["First", "Second"]) == "Mine\n\nFirst\n\nSecond")
    }

    @Test("The survivor's note is returned untouched when nothing is appended")
    func untouched() {
        #expect(combine("  Mine\n", [nil, "", "   \n"]) == "  Mine\n")
        #expect(combine("Mine", []) == "Mine")
        #expect(combine("Mine", ["mine "]) == "Mine")
    }

    @Test("Without a survivor note the first other note leads")
    func noSurvivorNote() {
        #expect(combine(nil, [nil, "A", "B"]) == "A\n\nB")
        #expect(combine("  \n", ["A"]) == "A")
    }

    @Test("Duplicates are dropped by trimmed, case-folded comparison, including against the survivor")
    func dedupe() {
        #expect(combine("Call Mom", ["  call mom\n", "Other", "OTHER", "call MOM"]) == "Call Mom\n\nOther")
        #expect(combine(nil, ["Same", " same ", "SAME"]) == "Same")
    }

    @Test("Different text is not collapsed, and interior whitespace still matters")
    func distinct() {
        #expect(combine("a b", ["a  b"]) == "a b\n\na  b")
    }

    @Test("Appended notes are trimmed and the survivor's trailing whitespace does not stack blank lines")
    func trimming() {
        #expect(combine("Mine\n\n", ["\n  Other  \n"]) == "Mine\n\nOther")
    }

    @Test("Everything empty gives nil")
    func allEmpty() {
        #expect(combine(nil, []) == nil)
        #expect(combine("", [nil, " ", "\n"]) == nil)
        #expect(combine(nil, [nil, nil]) == nil)
    }

    @Test("Unicode and multi-line notes survive")
    func unicode() {
        #expect(combine("Café ☕️\nline 2", ["日本語 \"quoted\" \\ back"]) == "Café ☕️\nline 2\n\n日本語 \"quoted\" \\ back")
    }
}
